import 'package:flutter_test/flutter_test.dart';

enum FrameSyncModel { isolated, android }

/// 两种模型共用引擎目标帧时钟；Android 模型另由视频驱动 Dart 帧。
class FrameSyncFixture {
  FrameSyncFixture(
    this.tester,
    this.refreshRate, {
    this.model = FrameSyncModel.isolated,
    this.roundSlotsUp = false,
  }) : origin = tester.binding.clock.now().microsecondsSinceEpoch;

  final WidgetTester tester;
  final double refreshRate;
  final FrameSyncModel model;
  final bool roundSlotsUp;
  final int origin;

  int get screenPeriod => (1000000 / refreshRate).round();

  int get now =>
      tester.binding.clock.now().microsecondsSinceEpoch - screenPeriod;

  int slotTime(int slot) => roundSlotsUp
      ? slot * (1000000 / refreshRate).ceil()
      : (slot * 1000000 / refreshRate).round();

  // 请求下一次 vsync；对应 BeginFrame 再领先一个屏幕周期。
  int requestForSlot(int slot) => origin + slotTime(slot - 2) + 1000;

  Future<void> elapseToSlot(int slot) => tester.binding.delayed(
    Duration(
      microseconds:
          origin +
          slotTime(slot) -
          tester.binding.clock.now().microsecondsSinceEpoch,
    ),
  );

  Future<bool> pump({required bool hasVideo}) async {
    if (model == FrameSyncModel.android && hasVideo) {
      tester.binding.scheduleFrame();
    }
    final requested = tester.binding.hasScheduledFrame;
    if (requested) await tester.pump();
    return requested;
  }
}
