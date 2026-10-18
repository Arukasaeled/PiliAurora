# 按需实验

在仓库根目录通过 FVM 运行，使用与正式测试相同的项目依赖：

```powershell
fvm flutter test tool/experiments/
```

此目录不进入默认 `fvm flutter test` 的 `test/` 扫描。可将单个文件路径传给命令，独立运行对应实验。

| 文件 | 内容 |
| --- | --- |
| `danmaku/raster_cache_capacity_test.dart` | 对照 16/24/32 MiB 缓存容量在唯一内容、重复内容和预热扫描中的命中、光栅化与淘汰；检查预算和预期命中关系。 |
| `danmaku/legacy_danmaku_rebuild_test.dart` | 测量旧弹幕渲染器在 120 个动画帧中的 widget 重建数和 pump 时间；重建数作为测量结果输出。 |
| `danmaku/frame_rate_matrix_test.dart` | 遍历屏幕刷新率、视频帧率和弹幕档位，输出合帧与更新统计；适合按需扩大时序诊断范围。 |
| `danmaku/frame_cadence_device_matrix_test.dart` | 将实测120Hz时序中的槽位抖动与回调迟到纳入Android模型，覆盖三种刷新率读数、五个弹幕档位、两种小数视频帧率及250ms/1秒批次，共60种组合；1秒批次和偶发5.7ms迟到为积压压力场景，20–31ms迟到由独立回归覆盖。 |
| `danmaku/frame_cadence_analysis.py` | 用 Python 标准库批量比较两份 `cadence.jsonl`，按连续播放段统计更新间隔、skip 截止推进、Timer 迟到和 FrameTiming；默认输出到 `build/frame-cadence-analysis/`。 |
| `danmaku/frame_rate_workload_test.dart` | 模拟同步更新耗时和额外 UI 帧，检查更新间隔及停止后的调度释放。 |
| `danmaku/native_video_frame_phase_test.dart` | 对照 Android 与隔离时序模型、mpv 同步和纹理相位，输出锁定状态检查。 |
| `windows/process_metrics_test.dart` | 在 Windows 上检查进程内存与 CPU 采样；其他平台会明确标记跳过。 |

测量使用 Flutter 测试宿主，pump 时间反映本机 CPU 侧重建和缓存状态；GPU 帧耗时在目标设备测量。主测试集保留 `test/pages/danmaku/frame_rate_ticker_test.dart` 和 `native_video_frame_sync_test.dart` 的核心调度与相位回归，扩大矩阵只在实验目录按需运行。
