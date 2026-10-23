# 弹幕迁移基线

此目录保存窗口内核替换前的 `WindowsDanmakuRenderer`、`WindowsDanmakuScreen` 和原有专属回归。旧 Canvas 屏幕的绘制、轨道、静音与 DPI 回归，以及旧预热策略及其测试也保留在此目录。应用源码不导入该目录；`test/pages/danmaku/` 中的像素、共享几何及文字上下文用例可引用基线进行对照。

从仓库根目录运行基线回归：

```powershell
fvm flutter test --no-pub tool/experiments/danmaku/baseline/
```

当前生产显示与挂载回归位于 `test/pages/danmaku/window_*_test.dart`、`live_layer_test.dart` 和 `live_queue_test.dart`。设备 GPU、呈现时序及 RSS 仍按固定输入和设备单独采集。
