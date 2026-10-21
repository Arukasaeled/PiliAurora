# Android EGL 输出时序实验

`egl_output_pacing_probe.cpp` 对 Android 33+、arm64、Skia/OpenGL 的最终 Flutter Raster 输出进行隔离对照。探针读取 NDK FrameTimeline，在 `eglSwapBuffers` 前设置呈现时间，并用 `EGL_ANDROID_get_frame_timestamps` 查询同一 EGL 帧 ID 的实际呈现、GPU 完成和 latch 时间。NDK 来自项目本机工具链，应用未引入新依赖。

实验以设备 120Hz、隔离 `.profile` 包为输入。所有模式都将旧 NDK callback 转接到新 FrameTimeline callback，传给现有引擎的 frame start 保持旧时钟语义；这使对照包含同样的转接开销。探针从隔离包 `cache/output-mode.txt` 读取模式：

| 模式 | 目标 |
| --- | --- |
| 0 | 记录输出，不设置呈现时间。 |
| 2 | 使用系统 preferred timeline 的 expected presentation time。 |
| 4 | 使用 preferred timeline，时间戳比 expected 提前 1ms。 |
| 7 | 选择 preferred 后一条可用 timeline，时间戳比 expected 提前 1ms。 |

1ms 和额外 timeline 都是待测参数。模式 7 增加呈现延迟；该实验没有实现在途帧预算、向 Dart 传递所选 timeline、按渲染耗时动态选 deadline、跨线程 Scene 身份或 Surface 重建协议。通过短片段的连续性检查后，还需在真实业务页面覆盖音画同步、视频保持时长、交互与长期负载。

## 构建与采集

使用本机 NDK 的 `aarch64-linux-android33-clang++.cmd` 编译动态库：

```powershell
& '<NDK>/toolchains/llvm/prebuilt/windows-x86_64/bin/aarch64-linux-android33-clang++.cmd' `
  -shared -fPIC -O2 -std=c++17 -static-libstdc++ `
  tool/experiments/android/egl_output_pacing_probe.cpp -o build/libpacing.so `
  -ldl -lEGL -landroid -llog
```

把动态库与下列 `wrap.sh` 放入隔离诊断 APK 的 `lib/arm64-v8a/`，重新 zipalign、使用开发签名并安装到对应 `.profile` 包。包装脚本依赖可调试诊断包的 Android 启动包装支持：

```sh
#!/system/bin/sh
HERE="${0%/*}"
export LD_PRELOAD="$HERE/libpacing.so"
exec "$@"
```

逐进程记录 `PILI_PACING` 与 `PILI_MOTION` 日志，沿用帧时间采集器收集 SurfaceFlinger latency 和 Perfetto 的 PipelineProduce/PipelineItem/eglSwapBuffers。合成夹具持续包含滚动、顶部固定和底部固定弹幕。采集后停止隔离包。

日志中的 `frame` 字段按顺序为：`frameId / swapStartNs / swapEndNs / oldEngineTargetNs / expectedNs / requestedNs / timestampSet / presentNs / renderingCompleteNs / latchNs`。单位均为 CLOCK_MONOTONIC 纳秒。`vsync` 记录 frameStart、expected、deadline、vsyncId、回调实际收到时刻。

## 关联与验收

`egl_frame_association.py` 按 native 记录的 swap 区间，把 Perfetto 中同一次调用关联到 EGL 帧 ID。边界容差为 1µs，候选必须唯一；无法关联、呈现时间未返回和无效时间均保留为缺失。设置未来 requested 时间后，SurfaceFlinger latency 首列不能再按“位于 swap 内”关联；Pipeline cookie 与 EGL frameId 是独立计数器，也不作为相等键使用。

实际呈现时间再与 SurfaceFlinger 的 present/ready 交叉核对；Flutter FrameTiming 独立核对 Raster 区间。连续性复用 `../danmaku/presentation_continuity_analysis.py`。验收同时约束同帧关联完整、实际更新档位、Surface 提交成本、呈现间隔 CV≤5%、±1/±2/±3 速度 RMS P95≤10%，并保留 P99 和峰值。

自编引擎日志使用同一模块的 `parse_engine_frames`，输入为去掉 logcat 前缀后的 `submit` 与 `present` 数值行。解析保留未返回的呈现记录；Surface 重建后须先按代次切分，避免重复 EGL frame ID 跨代关联。`associate_swap` 将同一次 Perfetto swap 区间关联到已完成的 EGL 帧，输出可继续用于连续性分析。

```powershell
python -m unittest discover -s tool/experiments/android -p '*_test.py' -v
```

## 贯通帧计划与异步媒体时钟

`frame_plan_pacing_probe.cpp`、`frame_plan_probe.dart.in` 和 `frame_plan_surface.java.in` 构成单播放器、单视图、120Hz 的隔离夹具。原生探针以 trace 的 PipelineProduce／DrawToSurfaces 边界传递帧计划，核对 PipelineItem 身份；Dart 通过 FFI 读取同一 expected 时间推进弹幕。模式8选择 preferred 后一条 timeline；模式9选择接近 frame-start 后四个屏幕周期的 timeline，二者均在 expected 前留1ms。固定预算用于机制对照。

```powershell
python tool/experiments/android/prepare_frame_plan_probe.py
```

生成目录为 `build/android-frame-plan-probe/`，包含入口、点播显示组件和 ticker 的实验副本。ticker 持续接收 vsync 时保留视频锁相；夹具在8秒测量窗口按运动或视频内容变化决定是否提交 Scene。视频 Java 模板将新帧序号和消费后的 SurfaceTexture PTS 传给原生探针。该提交规则依赖固定夹具的重绘来源，完整应用仍须处理其他控件、布局、语义和输出重建。

构建时临时使用生成的 `VideoSurfaceTexture.probe.java` 替换插件中的同名 Java 源文件，以 `try/finally` 保留并恢复原始字节，再按上述方式编译、包装原生库。入口使用 `--target build/android-frame-plan-probe/probe.dart` 和 `--dart-define=JANK_MEDIA_URI=<隔离包缓存原片URI>`。原生库在模板的 Java 类加载前须已通过 wrap.sh 载入；生产 APK 不包含该包装。

隔离包 cache 另提供 `clock-mode.txt`（`sync/async`）、`gate-mode.txt`（`true/false`）、`pacing-mode.txt`（持续请求 `true/false`）和 `phase-mode.txt`（`independent` 可禁用视频锁相）。异步路径调用生产的 `sampleNativeMediaClockOnWorker`；同步路径供同包对照。全部原片使用独立进程、相同 seek、预热和测量窗口。

新增原生记录为 `plan frameId/cookie/start/expected/deadline/swapStart/swapEnd`、`video_request sequence/time` 和 `video_consume sequence/time/PTS`。只在同一测量窗口内统计视频帧保持时长和序号缺口，并核对每个消费记录所对应的 swap／EGL 帧；启动、seek 和预热阶段分开。连续性和提交成本分别验收，CPU 时间单列；单段通过后继续重复采样。
