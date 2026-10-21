# 按需实验

在仓库根目录通过 FVM 运行，使用与正式测试相同的项目依赖：

```powershell
fvm flutter test tool/experiments/
```

此目录不进入默认 `fvm flutter test` 的 `test/` 扫描。可将单个文件路径传给命令，独立运行对应实验。

| 文件 | 内容 |
| --- | --- |
| `danmaku/raster_cache_capacity_test.dart` | 对照 16/24/32 MiB 缓存容量在唯一内容、重复内容和预热扫描中的命中、光栅化与淘汰；检查预算和预期命中关系。 |
| `danmaku/file_order_reuse_test.dart` | 用真实 protobuf 临时文件对照每次范围重建外部排序、来源排序产物冷构建和复用读取；核对相同范围内容、稳定次序、解码扫描量、产物复用及清理，输出宿主 CPU/磁盘耗时。 |
| `danmaku/legacy_danmaku_rebuild_test.dart` | 测量旧弹幕渲染器在 120 个动画帧中的 widget 重建数和 pump 时间；重建数作为测量结果输出。 |
| `danmaku/baseline/` | 迁移前 Windows renderer/screen 及其专属回归；供像素、排轨、资源和预热对照，生产源码已统一使用窗口内核。 |
| `danmaku/frame_rate_matrix_test.dart` | 遍历屏幕刷新率、视频帧率和弹幕档位，输出合帧与更新统计；适合按需扩大时序诊断范围。 |
| `danmaku/frame_cadence_device_matrix_test.dart` | 将实测120Hz时序中的槽位抖动与回调迟到纳入Android模型，覆盖三种刷新率读数、五个弹幕档位、两种小数视频帧率及250ms/1秒批次，共60种组合；1秒批次和偶发5.7ms迟到为积压压力场景，20–31ms迟到由独立回归覆盖。 |
| `danmaku/frame_wake_lead_test.dart` | 在120Hz/60FPS下对比半屏到1.5屏的唤醒提前量与5/10/20/31.6ms迟到组合，输出最大间隔、长间隔和帧请求数；默认策略仍为半屏。 |
| `danmaku/frame_cadence_analysis.py` | 用 Python 标准库批量比较两份 `cadence.jsonl`，按连续播放段统计更新间隔、skip 截止推进、Timer 迟到和 FrameTiming；默认输出到 `build/frame-cadence-analysis/`。 |
| `danmaku/presentation_continuity_analysis.py` | 用 Python 标准库读取同帧对应的媒体位置和实际呈现时间，保留逐帧数值，汇总跨 1/2/3 帧的差分与 ±1/±2/±3（3/5/7 帧）局部波动，输出 JSON/CSV。 |
| [`android/`](android/README.md) | 隔离诊断包的 EGL 呈现时间与 FrameTimeline 对照，按 EGL 帧 ID 获取实际呈现并关联 Perfetto swap，核对连续性和按需输出成本。 |
| `danmaku/frame_rate_workload_test.dart` | 模拟同步更新耗时和额外 UI 帧，检查更新间隔及停止后的调度释放。 |
| `danmaku/native_video_frame_phase_test.dart` | 对照 Android 与隔离时序模型、mpv 同步和纹理相位，输出锁定状态检查。 |
| `windows/process_metrics_test.dart` | 在 Windows 上检查进程内存与 CPU 采样；其他平台会明确标记跳过。 |

测量使用 Flutter 测试宿主，pump 时间反映本机 CPU 侧重建和缓存状态；GPU 帧耗时在目标设备测量。主测试集保留 `test/pages/danmaku/frame_rate_ticker_test.dart` 和 `native_video_frame_sync_test.dart` 的核心调度与相位回归，扩大矩阵只在实验目录按需运行。

实际呈现分析的输入为已分段的 `presentation-stage-*.json`，包含 `summary`（`run/stage/target`）与 `matched` 数组；每帧字段为 `index/targetUs/positionUs/presentNs`，其中 `presentNs` 必须来自该弹幕更新帧的实际屏幕呈现。暂停、切档和媒体代次分别输入；缺帧、时间倒退和位置回退会中断窗口，首尾采用完整窗口，不补点。一般场景使用滚动＋顶部固定＋底部固定，覆盖固定弹幕进入、驻留和到期。

```powershell
python tool/experiments/danmaku/presentation_continuity_analysis.py <阶段1.json> <阶段2.json> --output build/presentation-continuity
python -m unittest discover -s tool/experiments/danmaku -p presentation_continuity_analysis_test.py
```

`--rate` 指定该测量段的媒体倍速，默认 1。省略 `--output` 时输出每阶段一行完整 JSON，可通过 PowerShell 管道保存。每个阶段独立保留逐帧值、跨 1/2/3 帧的跨度，以及间隔序列滞后 1/2/3 项的差分；±r 窗口包含 `2r+1` 帧和 `2r` 个间隔。窗口记录相对目标间隔误差、相对媒体速率误差的 RMS、呈现延迟极差及总位移速度，汇总数量、均值、分位数、峰值和速度偏差超过 10% 的诊断分桶。长短帧可能抵消窗口总误差，需结合窗口内 RMS 判断；重叠窗口的计数表示覆盖范围。`summary.json/summary.csv` 提供汇总，各阶段 JSON 保留明细。

文件排序复用实验默认生成 9000 条弹幕，对照三个固定 20 秒范围。可单独运行，并通过 `DANMAKU_FILE_ORDER_ELEMENTS` 扩大输入条数（至少 1500）：

```powershell
fvm flutter test --no-pub tool/experiments/danmaku/file_order_reuse_test.dart --reporter expanded
fvm flutter test --no-pub tool/experiments/danmaku/file_order_reuse_test.dart --reporter expanded --dart-define=DANMAKU_FILE_ORDER_ELEMENTS=12000
```

输出的 `DANMAKU_FILE_ORDER` JSON 行包含输入字节/条数、返回范围数量、解码扫描条数/批次数、耗时和排序产物复用/清理结果。计时包含排序构建或复用后的范围扫描及该次流读取退出，来源 store 最终 dispose 清理另行断言，排除测试文件生成和预期结果计算；耗时不作为测试阈值。这是 Flutter 测试宿主上的 CPU/磁盘成本对照，设备 RSS、GPU 和实际播放表现需要目标设备测量。
