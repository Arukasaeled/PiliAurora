# 测试目录

从仓库根目录运行 `fvm flutter test`。传入文件或目录可选择对应范围，环境与平台验证要求见[构建与测试说明](../doc/build-and-test.md)。

| 目录 | 范围 |
| --- | --- |
| `architecture/` | 依赖政策、模块边界和发布工作流约束。 |
| `common/widgets/` | 通用控件、图片、手势和进度条。 |
| `grpc/`、`http/` | 协议解码、请求转换和 API 选择规则。 |
| `pages/` | 页面与控制器；二级评论位于 `video/reply_reply/`，诊断页面位于 `about/`。 |
| `plugin/pl_player/` | 原生媒体源、跳转、硬解配置、解码分类和预览缓存。 |
| `plugin/pl_player/android/` | Android 解码恢复、Surface 输出与帧交接。 |
| `plugin/pl_player/video_output/` | 跨平台尺寸策略、输出调度、截图桥和绘制确认。 |
| `plugin/pl_player/playback/` | 页面归属、请求代次、播放加载队列、网络恢复、shader 更新与时序契约。 |
| `services/` | 下载、直播、设置同步及平台服务。 |
| `services/messaging/` | 消息账号隔离、订阅释放、共享会话、分页竞争、发送结果与已读水位。 |
| `services/diagnostics/` | 诊断编排、脱敏、HTTP 接线、历史读取、记录存储、日志和进程采样。 |
| `utils/` | 工具函数与账号状态。 |

测试文件使用 `_test.dart` 后缀，领域内共用的 fixture 与调用者放在同一目录，例如 `services/download/download_fixtures.dart` 和 `services/messaging/messaging_fixtures.dart`。

同一组件的场景集中在对应文件，播放图标测试位于 `common/widgets/svg/play_icon_test.dart`，诊断记录存储及突发写入位于 `services/diagnostics/record_store_test.dart`。页面测试与服务测试分开组织；`pages/danmaku/windows_screen_test.dart` 覆盖 screen 的时钟、预热和 widget 重建行为。

消息测试按业务状态、分享和协议分为 `messaging_test.dart`、`sharing_test.dart`、`protocol_test.dart`。运行入口与实际服务验证范围见[消息模块](../lib/services/messaging/README.md#验证)。

`pages/danmaku/video_frame_sync_test.dart` 在模拟 120 Hz 时间槽上覆盖视频与弹幕的相位同步，以及原生纹理帧时间的逐帧、100 ms 和 release 一秒批量报告；调用真实弹幕 ticker，验证稳定后的额外帧请求。该测试不测量 GPU 合成次数或实机屏幕 Hz。

`pages/danmaku/native_video_frame_sync_test.dart` 使用独立的纹理消费时间批次，覆盖引擎不提供零 Build timing 时的 60 FPS 相位学习、批次限界、消费耗时抖动、59.94 FPS 漂移与来源释放。消费时间对实际屏幕槽位的估计仍需实机检查。

`plugin/pl_player/playback/super_resolution_policy_test.dart` 检查源视频与当前屏幕物理分辨率的长短边比较，以及尺寸未知时延后加载超分的判定。super_resolution_selection_test.dart 检查不可用的显式选择保留档位和设置，并在访问原生播放器前返回。super_resolution_menu_tile_test.dart 覆盖侧边超分入口的禁用状态、原因展示、点击提示和可用档位选择。

```powershell
fvm flutter test test/plugin/pl_player/android/
fvm flutter test test/services/diagnostics/ test/pages/about/diagnostics_page_test.dart
```

按需实验位于 [`tool/experiments/`](../tool/experiments/README.md)，原生或设备探针位于 [`tool/probes/`](../tool/probes/README.md)，各入口和执行条件由对应目录文档说明。
