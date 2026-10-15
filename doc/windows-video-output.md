# Windows 视频输出

Windows 通过 media_kit 的 libmpv 渲染接口和 ANGLE 共享纹理输出视频。应用优先配置 D3D11 硬解，实际解码器需查看 `hwdec-current`；ANGLE 初始化失败时，插件尝试软件渲染，软件输出尺寸上限为 1920×1080。

## 原生资源与首帧

[`VideoOutput`](../third_party/media_kit_video/windows/video_output.cc) 在共用输出线程上创建、渲染和释放 mpv render context 与 ANGLE 资源。释放时先将对应 EGL 上下文设为 current，清除 mpv 更新回调并释放 render context，再解除 current、销毁 EGL 和设备。

初始纹理 ID 用于完成 Dart 控制器创建，视频首帧就绪另行通知。真实纹理替换要等渲染成功后发布；同尺寸请求沿用已发布的画面。源尺寸由 Dart 的 `video-out-params` 观察事件送入原生队列，避免渲染线程同步查询正在等待首帧的 mpv 核心。

ANGLE Surface 的 D3D 纹理作为默认 framebuffer 的绘制目标，随后通过 D3D 复制供 Flutter
读取。创建与扩容时不生成额外 GL 纹理或调用 `eglBindTexImage`，避免改动 mpv 共用的
GL 纹理状态。真实直播的首次播放、刷新与纹理像素验证见
[`windows_live_startup.dart`](../tool/probes/playback/windows_live_startup.dart) 及[运行说明](../tool/probes/README.md#windows-直播首帧探针)。

输出尺寸策略和截图交接位于 [`view.dart`](../lib/plugin/pl_player/view/view.dart) 与 [`video_output_resizer.dart`](../lib/plugin/pl_player/utils/video_output_resizer.dart)。Windows 首次检测 Flutter 窗口所在显示器的物理尺寸并缓存上限，窗口布局变化由 Flutter 缩放。输出限幅降低渲染目标的开销，媒体解码仍使用源分辨率。

## 超分切换

视频尺寸超过当前屏幕、或尺寸尚未确认时，播放器超分入口置灰并禁用菜单；悬停或长按保留原因提示，点击灰色入口显示提示，不发起切换。显式选择请求在修改档位、保存设置和进入 shader 队列前再次检查；重复选择当前档位也直接返回，保留连续播放。媒体加载时的默认档位仍随源尺寸核对，必要时清除上一媒体的滤镜。

[`PlPlayerController.setShader`](../lib/plugin/pl_player/controller.dart) 使用独立的 `PlaybackLoadQueue` 串行处理 shader 更新，尚未开始的旧请求可被新请求取代。当前 Windows 播放器已有视频尺寸和输出控制器时，调用 [`applyShaderList`](../lib/plugin/pl_player/playback/shader_updates.dart)：

1. 将 mpv 的 `vo` 切到 `null`，解除视频输出对 render context 的使用。
2. 调用 `resetRenderer()`，在原生输出线程释放并重建 render context 与 ANGLE 设备。
3. 提交新的 `glsl-shaders` 列表。
4. 在 `finally` 中恢复 `vo=libmpv`；重建后的纹理等待 mpv 通知实际视频帧后发布。

切换 `vo` 会同时重建 mpv 的视频解码链。固定原生库通过 `vo-reinit-seek.patch` 在重建后、返回播放循环前完成补偿 seek，使缓存读取位置和解码状态先恢复到关键帧。否则缓存中的非关键包可能耗尽解码器的 96 包等待额度，产生 AV1 参考帧错误并触发硬解回退。

该过程保留 Player 和媒体。Android、未就绪的 Windows 输出直接更新 shader；软件输出跳过原生重建。控制器退出时，使 shader 队列失效并等待当前操作结束，再销毁播放器。

## 原生库与验证

Windows 的 Debug、Profile、Release 构建均使用 `third_party/mpv/prebuilt/` 的预编译包，GitHub CI 使用相同归档。源码、工具链和许可说明见[mpv 构建入口](../third_party/mpv/README.md)；CMake 检查构建输入和运行文件摘要，缺失或过期时终止。

相关验证入口：

- `test/plugin/pl_player/playback/shader_updates_test.dart`：shader 更新顺序与失败后恢复 `vo`。
- `test/plugin/pl_player/video_output/`：尺寸策略、调度、截图交接与帧确认。
- `tool/probes/windows/windows_texture_frame_probe.py`：模拟纹理首帧和重建后的帧发布条件。
- `tool/probes/playback/windows_shader_switch.dart`：实际 Flutter、ANGLE、libmpv 的超分切换；运行参数见[平台探针](../tool/probes/README.md#windows-超分切换探针)。

历史本机测量中，暂停重建出现过约 0.33 秒时间线回退。上述入口覆盖编译与模拟路径，音频输出、长时间播放和更多 GPU 驱动的实测单独进行。
