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

`frame_sync_fixture.dart` 供相位测试和帧率矩阵共用请求时间换算；Android 模型把目标帧时钟领先和视频驱动 Dart 帧绑定在一起，隔离模型用于检查 ticker 自行唤醒。 `frame_rate_diagnostics_test.dart` 检查实际更新、请求和定时器累计计数、单调时间及停止后的释放；相位测试同时检查稳定锁相状态。

同一组件的场景集中在对应文件，播放图标测试位于 `common/widgets/svg/play_icon_test.dart`，诊断记录存储及突发写入位于 `services/diagnostics/record_store_test.dart`。页面测试与服务测试分开组织；`pages/danmaku/windows_screen_test.dart` 覆盖 screen 的时钟、预热和 widget 重建行为。

消息测试按业务状态、分享和协议分为 `messaging_test.dart`、`sharing_test.dart`、`protocol_test.dart`。运行入口与实际服务验证范围见[消息模块](../lib/services/messaging/README.md#验证)。

`pages/danmaku/video_frame_sync_test.dart` 在模拟 120 Hz 时间槽上覆盖视频与弹幕的相位同步，以及原生纹理帧时间的逐帧、100 ms 和 release 一秒批量报告；调用真实弹幕 ticker，验证稳定后的额外帧请求。该测试不测量 GPU 合成次数或实机屏幕 Hz。

`pages/danmaku/native_video_frame_sync_test.dart` 使用独立的纹理刷新请求批次，覆盖引擎不提供零 Build timing 时的 60 FPS 相位学习、30 FPS 视频配 60 FPS 弹幕在 90/120 Hz 上的相位变化、匹配到失配再匹配时的退化与恢复、mpv 显示同步状态切换与订阅释放、批次限界、请求时间抖动、29.97/59.94 FPS 漂移与来源释放。相位变化测试同时断言弹幕更新频率和视频、弹幕合计刷新的次数。`native_video_frame_phase_test.dart` 检查下一次 vsync 与 BeginFrame 目标时间的换算，以及 mpv 同步关闭时仍按稳定的原生请求节奏锁定；119.88／120／120.12Hz 共 24 个场景覆盖隔离调度与 Android 时序。Android 模型同时包含 target=start+screen 时间差和纹理请求驱动 Dart 帧的行为，不将隔离模型单独视为实机结论。实际屏幕槽位与呈现仍需设备检查。

`pages/danmaku/frame_rate_matrix_test.dart` 检查屏幕 60/90/120/144 Hz、视频 24/30/60 FPS 与弹幕 30/60/90/120 FPS 的 48 种组合，每组覆盖 mpv 显示同步实际开启与关闭，共 96 个场景。视频按媒体周期映射到屏幕槽位，覆盖非整数比例，并在三秒后延后一个槽位。全部组合检查视频帧数、受屏幕刷新率上限约束的弹幕更新频率，以及相位变化前后的稳定更新频率；具备原生到达通知且视频周期可稳定映射到屏幕槽位的整数倍或整数分频组合，在两种 mpv 状态下都检查合计刷新次数，失配时检查退化后的目标更新频率。`frame_rate_ticker_test.dart` 另检查所属视图刷新率、屏幕降频与刷新率不可用的调度。该测试使用模拟时钟，不测量设备屏幕或 GPU 合成。

`plugin/pl_player/playback/super_resolution_policy_test.dart` 检查源视频与当前屏幕物理分辨率的长短边比较，以及尺寸未知时延后加载超分的判定。super_resolution_selection_test.dart 检查不可用的显式选择保留档位和设置，并在访问原生播放器前返回。super_resolution_menu_tile_test.dart 覆盖侧边超分入口的禁用状态、原因展示、点击提示和可用档位选择。

```powershell
fvm flutter test test/plugin/pl_player/android/
fvm flutter test test/services/diagnostics/ test/pages/about/diagnostics_page_test.dart
```

按需实验位于 [`tool/experiments/`](../tool/experiments/README.md)，原生或设备探针位于 [`tool/probes/`](../tool/probes/README.md)，各入口和执行条件由对应目录文档说明。

`pages/danmaku/frame_rate_workload_test.dart` 用固定 vsync 时刻检查 60/90/120/144 Hz 与四个弹幕档位，分别模拟 0/2 ms 同步更新耗时以及一段持续的高频 UI 帧。32 个场景同时检查更新总数、最长更新间隔和停止后的调度释放，防止处理耗时累积造成漏帧或外部帧反复校准造成超额更新。

`pages/danmaku/canvas_repaint_test.dart` 检查通用 Canvas 渲染器连续动画的零 widget 重建、图片复用、点击命中与单条悬停、速度变化、暂停恢复、清空和高级弹幕按期清理。固定弹幕新增与运动弹幕合帧，并覆盖固定弹幕单独出现的首帧、暂停恢复与到期清理；新增与到期清理同帧且最终数量不变时，检查新项绘制及正常过期。120 条混合弹幕另检查逐帧通知相位。点击回归使用与 Android 播放器相同的控制器查询与 suspend 状态，真实触屏和菜单操作仍需设备检查。
