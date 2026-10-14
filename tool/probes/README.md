# 调试工具

此目录存放供维护者运行的隔离诊断工具和平台探针。这些工具不属于应用运行时或正式构建流程。

| 目录 | 内容 |
| --- | --- |
| `android/` | 暂停旋转测试入口、画面检查脚本和 Java 帧栅栏检查。 |
| `windows/` | 窗口回调、尺寸通道、纹理首帧和输出确认探针。 |
| `playback/` | 媒体加载烟测、跳转命令、断流恢复与 Windows 超分切换。 |
| `event_loop/` | 事件循环生命周期、ABI 检查与配套 C++ mock。 |

运行前查看脚本参数和源码，确认目标平台、输入文件及输出目录。工具结果只覆盖它实际检查的内容；应用行为还要按[构建与测试说明](../../doc/build-and-test.md)在目标平台验证。

Python 探针使用 uv 环境，首次运行前请按[工具入口中的 Python 环境说明](../README.md#python-工具环境)初始化；以下命令均从仓库根目录运行。

## 事件循环生命周期探针

`event_loop/native_event_loop_probe.dart` 使用纯 Dart 桩检查生命周期、关闭顺序和 ABI 选择：

```powershell
fvm dart tool/probes/event_loop/native_event_loop_probe.dart
```

`native_event_loop_abi_probe.dart` 与同目录的 `native_event_loop_abi_mock.cc` 配套，检查 mock DLL 的真实 FFI 调用和 isolate 事件借用生命周期。

Windows 上使用 `g++` 编译两种 ABI 的 mock，再交给 Dart 入口。下面的头文件路径由 Windows 构建准备：

```powershell
New-Item -ItemType Directory -Path build/probe-validation/event_loop -Force | Out-Null
g++ -shared -std=c++17 -O0 -static-libgcc -static-libstdc++ -I build/windows/x64/libmpv/include tool/probes/event_loop/native_event_loop_abi_mock.cc -o build/probe-validation/event_loop/registered_mock.dll
g++ -shared -std=c++17 -O0 -static-libgcc -static-libstdc++ -DMOCK_LEGACY_ABI -I build/windows/x64/libmpv/include tool/probes/event_loop/native_event_loop_abi_mock.cc -o build/probe-validation/event_loop/legacy_mock.dll
fvm dart tool/probes/event_loop/native_event_loop_abi_probe.dart build/probe-validation/event_loop/registered_mock.dll build/probe-validation/event_loop/legacy_mock.dll
```

## 原生媒体加载烟测

Windows 构建完成后，可用 Python 和 libmpv 检查独立音轨、特殊字符路径和媒体重载。
传入数秒以上的本地视频即可运行；工具不访问网络，并将测试用静音 WAV 写入 `build/native-playback-smoke/`。

```powershell
uv run --locked python tool/probes/playback/native_media_smoke.py --library build/windows/x64/runner/Debug/libmpv-2.dll --video <本地视频文件>
```

同一命令追加 `--audio-reload`，可验证后台音轨重连时音频时钟恢复、视频继续输出新帧，且媒体位置和暂停状态保持。输入需为超过 3 秒的连续视频；真实画面与声音仍需实机检查。

传入 `--seek-target <秒数>` 可检查 Android 独立音轨的前进、后退和重复跳转命令。`tool/probes/playback/native_seek_command.dart` 会调用应用使用的命令构造器；烟测检查视频恢复后音轨等待是否小于 100 ms。视频长度应超过目标时间，目标时间应落在关键帧之间。`--keyframes-control` 使用旧策略作对照，预期会触发静音断言。

```powershell
uv run --locked python tool/probes/playback/native_media_smoke.py --library build/windows/x64/runner/Debug/libmpv-2.dll --video <本地视频文件> --seek-target 2.4
```

该检查通过 Windows libmpv、`vo=null`、`ao=null` 和软件解码运行，视频帧依据 mpv 的 trace 日志计数。它不覆盖 Android GPU/MediaCodec、真实扬声器或完整应用性能。画面和硬件解码仍需在目标设备上验证。

## 暂停旋转探针

`paused_rotation.dart` 使用本地视频检查暂停后横屏、竖屏和再次横屏时的整帧显示。配套的 `paused_rotation_probe.py` 会检查四象限、视频白边和暂停状态。输入文件应使用对应的测试图视频。

入口使用当前 Android 固定 Surface 策略，旋转由 Flutter 的 `FittedBox` 缩放画面。硬件解码关闭，默认不限制源纹理尺寸；构建时传入 `--dart-define=ANDROID_TEXTURE_SCALING=true` 可启用设备物理显示尺寸限幅，与应用的纹理缩放开关对应。

```powershell
fvm flutter build apk --debug --target tool/probes/android/paused_rotation.dart --no-pub
uv run --locked python tool/probes/android/paused_rotation_probe.py --adb <adb路径> --serial <emulator序列号> --apk build/app/outputs/flutter-apk/app-debug.apk --fixture <四象限测试视频>
```

探针会安装调试 APK、推送测试视频并清空目标模拟器日志，因此应使用独占的测试模拟器。输出默认保存在 `build/rotation-smoke/`。退出码 0 表示三个阶段通过，1 表示旋转检查失败，2 表示初始画面无效或检查未完成。该工具不检查旋转过程中的逐帧黑闪。

使用 `--dart-define=CREATE_ROTATION_FIXTURE=true` 构建入口可显示测试图，再通过模拟器 `screenrecord` 录制 H.264 视频。确认四象限和白边完整，并排除系统弹窗干扰。交付应用前需用默认入口重新构建。

## Android 帧栅栏条件探针

`android/SurfaceFrameFenceProbe.java` 在主机 JVM 上验证生产 Java 类的时间戳、尺寸与 Surface 代次条件：

```powershell
New-Item -ItemType Directory -Path build/probe-validation/frame-fence -Force | Out-Null
javac -d build/probe-validation/frame-fence third_party/media_kit_video/android/src/main/java/com/alexmercerind/media_kit_video/SurfaceFrameFence.java tool/probes/android/SurfaceFrameFenceProbe.java
java -cp build/probe-validation/frame-fence com.alexmercerind.media_kit_video.SurfaceFrameFenceProbe
```

该入口检查帧接收条件，画面像素由模拟器旋转探针检查。

`android/VideoFrameSamplesProbe.java` 检查实际纹理消费时间缓冲的 32 个样本上限、微秒转换、批次提取和 Surface 重置清理：

```powershell
New-Item -ItemType Directory -Path build/probe-validation/video-frame-samples -Force | Out-Null
javac -d build/probe-validation/video-frame-samples third_party/media_kit_video/android/src/main/java/com/alexmercerind/media_kit_video/VideoFrameSamples.java tool/probes/android/VideoFrameSamplesProbe.java
java -cp build/probe-validation/video-frame-samples com.alexmercerind.media_kit_video.VideoFrameSamplesProbe
```

该入口运行于主机 JVM，消费时间与屏幕槽位的关系需目标设备验收。

## Windows 尺寸通道回归探针

`windows_source_size_channel_probe.py` 使用 Flutter 的标准编码器和生产通道处理代码，验证 int32、int64 尺寸均能传入播放器。先完成 Windows 构建以生成 Flutter C++ 头文件，再运行：

```powershell
uv run --locked python tool/probes/windows/windows_source_size_channel_probe.py
```

需要 Python 和支持 C++17 的 `g++`，可用 `--compiler` 指定编译器。输出保存在 `build/windows-playback-diagnosis/`。探针使用模拟播放器，不覆盖 GPU 和实际视频播放。

## Windows 开播纹理回归探针

`windows_playback_startup_probe.py` 提取生产视口的尺寸提交方法，使用真实的截图交接和帧确认类，验证已配置的同尺寸输出在帧统计延迟时保持活画面、真实尺寸变化仍等待对应的渲染帧。

```powershell
uv run --locked python tool/probes/windows/windows_playback_startup_probe.py
uv run --locked python tool/probes/windows/windows_texture_frame_probe.py --compiler <g++路径>
```

前者通过 FVM 运行 Flutter 测试；后者编译生产纹理方法，检查初始纹理、有效首帧和同尺寸提交。生成文件位于 `build/windows-playback-diagnosis/`，GPU 和播放器通道由模拟对象替代。

## Windows 硬解画面采样探针

`windows_video_sampling_probe.py` 使用本机 ANGLE、libmpv 和真实 GPU 解码帧，读取 media_kit 的生产渲染参数及应用初始化中的 Windows 参数，检查画面底部连续的绿色条带。先构建 Windows Release，再传入曾出现条带的本地 AV1／HEVC 片段：

```powershell
uv run --locked python tool/probes/windows/windows_video_sampling_probe.py --video <本地视频文件>
```

默认使用 `build/windows/x64/runner/Release/` 下的 DLL，以 `d3d11va` 解码并输出 `1920×1080`。可用 `--library-dir`、`--width`、`--height` 指定构建目录和输出尺寸；`--output-dir` 默认是 `build/windows-video-sampling/`，保存最后一帧 PNG、实际解码器日志与逐帧绿色行数 JSON。

追加 `--control-dumb-mode=auto` 可对照修复前的自动简化渲染模式。退出码 0 表示 16 个采样帧均无绿色边带且实际使用指定硬解器；检测到条带、帧不足或硬解回退会退出 1。输入需有至少 20 帧，画面底部应有正常内容，避免原片自身纯绿色边带造成误判。探针只打开本地视频，不访问网络或账号；它覆盖 mpv／ANGLE 的像素输出，Flutter 合成、控件、全屏切换和长期性能仍需应用实测。

## 播放器断流恢复回归探针

`playback_network_recovery_probe.py` 回放脱敏的 Windows curl 终止错误、Android HTTPS 提前结束和 MP4 截断错误，提取生产日志分发、播放器监听和重连方法，检查断流恢复、缓冲检查升级、错误合并、冷却窗口和媒体切换。暂停状态与 CDN 切换由 `test/plugin/pl_player/native_media_source_test.dart` 覆盖。

```powershell
uv run --locked python tool/probes/playback/playback_network_recovery_probe.py
```

通过 FVM 运行 Flutter 测试，生成文件写入 `build/playback-network-diagnosis/` 下的临时目录，运行结束后自动清理。原生播放器由状态桩替代，真实网络传输、GPU、MediaCodec 和长时间播放需要实机验证。

## Windows 超分切换探针

`playback/windows_shader_switch.dart` 使用实际 Flutter、ANGLE 与 libmpv 检查 shader 切换、纹理更新、硬解、暂停状态、音频时间线和私有内存。先确认[mpv 预编译包](../../third_party/mpv/README.md)完整，并准备含音轨的本地视频，再构建专用入口：

```powershell
fvm flutter build windows --debug --no-pub --target tool/probes/playback/windows_shader_switch.dart --dart-define=SHADER_PROBE_ROOT=<仓库绝对路径> --dart-define=SHADER_PROBE_VIDEO=<本地视频绝对路径> --dart-define=SHADER_PROBE_OUTPUT=<输出目录绝对路径>
& build/windows/x64/runner/Debug/PiliAurora.exe
```

路径含空格时，将整个 `--dart-define=...` 参数放在引号内。探针创建输出目录，写入 `results.json` 和 `PASS` 或 `FAIL`，执行完毕自动退出。构建时增加 `--dart-define=SHADER_PROBE_RESET=false` 可对照直接更新 shader 的行为；默认启用重建。

入口要求实际后端为 `d3d11va`，输入画面需有可识别的明暗变化，片段长度应覆盖完整切换流程。探针开启与应用一致的 16 秒、前后各 4 MiB 缓存，默认从 4.3 秒开始播放，并检查切换期间的解码错误。可用 `--dart-define=SHADER_PROBE_START_MS=<毫秒>` 指定起点。

AV1 重建回归需使用关键帧间隔较长的片段，例如 90 秒、30 fps、300 帧 GOP 的合成视频。准备好 FFmpeg 后可生成：

```powershell
ffmpeg -f lavfi -i "testsrc2=size=640x360:rate=30" -f lavfi -i "sine=frequency=440:sample_rate=48000" -t 90 -c:v libsvtav1 -preset 10 -crf 38 -g 300 -svtav1-params "lp=4" -c:a aac -b:a 64k build/av1-shader-fixture.mp4
```

探针使用 `ao=null`，音频时间线断言不验证扬声器声音。历史本机结果与暂停回退现象见[本地 libmpv 记录](../../third_party/media_kit_libs_windows_video/LOCAL_LIBMPV.md#应用超分切换记录)。完成后按[构建与测试](../../doc/build-and-test.md#构建)重新构建应用默认入口。
