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
| `danmaku/frame_rate_workload_test.dart` | 模拟同步更新耗时和额外 UI 帧，检查更新间隔及停止后的调度释放。 |
| `danmaku/native_video_frame_phase_test.dart` | 对照 Android 与隔离时序模型、mpv 同步和纹理相位，输出锁定状态检查。 |
| `windows/process_metrics_test.dart` | 在 Windows 上检查进程内存与 CPU 采样；其他平台会明确标记跳过。 |

测量使用 Flutter 测试宿主，pump 时间反映本机 CPU 侧重建和缓存状态；GPU 帧耗时在目标设备测量。主测试集保留 `test/pages/danmaku/frame_rate_ticker_test.dart` 和 `native_video_frame_sync_test.dart` 的核心调度与相位回归，扩大矩阵只在实验目录按需运行。

文件排序复用实验默认生成 9000 条弹幕，对照三个固定 20 秒范围。可单独运行，并通过 `DANMAKU_FILE_ORDER_ELEMENTS` 扩大输入条数（至少 1500）：

```powershell
fvm flutter test --no-pub tool/experiments/danmaku/file_order_reuse_test.dart --reporter expanded
fvm flutter test --no-pub tool/experiments/danmaku/file_order_reuse_test.dart --reporter expanded --dart-define=DANMAKU_FILE_ORDER_ELEMENTS=12000
```

输出的 `DANMAKU_FILE_ORDER` JSON 行包含输入字节/条数、返回范围数量、解码扫描条数/批次数、耗时和排序产物复用/清理结果。计时包含排序构建或复用后的范围扫描及该次流读取退出，来源 store 最终 dispose 清理另行断言，排除测试文件生成和预期结果计算；耗时不作为测试阈值。这是 Flutter 测试宿主上的 CPU/磁盘成本对照，设备 RSS、GPU 和实际播放表现需要目标设备测量。
