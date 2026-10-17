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
| `danmaku/frame_rate_workload_test.dart` | 模拟同步更新耗时和额外 UI 帧，检查更新间隔及停止后的调度释放。 |
| `danmaku/native_video_frame_phase_test.dart` | 对照 Android 与隔离时序模型、mpv 同步和纹理相位，输出锁定状态检查。 |
| `windows/process_metrics_test.dart` | 在 Windows 上检查进程内存与 CPU 采样；其他平台会明确标记跳过。 |

测量使用 Flutter 测试宿主，pump 时间反映本机 CPU 侧重建和缓存状态；GPU 帧耗时在目标设备测量。主测试集保留 `test/pages/danmaku/frame_rate_ticker_test.dart` 和 `native_video_frame_sync_test.dart` 的核心调度与相位回归，扩大矩阵只在实验目录按需运行。
