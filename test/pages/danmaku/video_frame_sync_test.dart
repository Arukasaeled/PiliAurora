import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dart:ui';

void main() {
  for (final (gap, refreshRate) in [
    (const Duration(milliseconds: 200), 120.0),
    (const Duration(seconds: 2), 120.0),
    (const Duration(milliseconds: 200), 60.0),
  ]) {
    testWidgets('弹幕空档 ${gap.inMilliseconds} ms 后以 $refreshRate Hz 检查相位有效性', (
      tester,
    ) async {
      tester.view.display.refreshRate = 120;
      addTearDown(tester.view.display.resetRefreshRate);
      final ticker = _ClockTicker(
        (_) {},
        () => tester.binding.clock.now().microsecondsSinceEpoch,
      )..start();
      await tester.pump();
      final now = tester.binding.clock.now().microsecondsSinceEpoch;
      tester.binding.platformDispatcher.onReportTimings?.call([
        for (var i = 6; i >= 0; i--)
          FrameTiming(
            vsyncStart: now - i * 16668 - 8333,
            buildStart: now - i * 16668,
            buildFinish: now - i * 16668,
            rasterStart: now - i * 16668 + 1,
            rasterFinish: now - i * 16668 + 2,
            rasterFinishWallTime: now - i * 16668 + 2,
          ),
      ]);
      ticker.stop();
      await tester.binding.delayed(gap);
      if (tester.view.display.refreshRate != refreshRate) {
        tester.view.display.refreshRate = refreshRate;
        // 屏幕参数变化会请求界面帧，先处理该帧再检查 ticker 的恢复请求。
        await tester.pump();
      }
      ticker.start();
      // 有效相位应等待预测的下一视频槽位；过期后立即使用普通调度。
      final invalidPhase = gap.inSeconds >= 2 || refreshRate != 120;
      final requestedImmediately = tester.binding.hasScheduledFrame;
      ticker.dispose();
      await tester.binding.delayed(const Duration(seconds: 1));
      final requestedAfterDispose = tester.binding.hasScheduledFrame;
      await tester.pump();
      expect(requestedImmediately, invalidPhase);
      expect(requestedAfterDispose, invalidPhase);
    });
  }
  // 使用真实 FrameRateTicker 和 Flutter 测试时钟。纹理帧用时间槽记录，
  // 模拟独立的原生刷新源；这里不创建 GPU 纹理，也不测量屏幕实际 Hz。
  for (final batchSlots in [1, 12, 120]) {
    for (final videoRunsDart in [false, true]) {
      for (final videoPhase in [0, 1]) {
        testWidgets(
          '60 FPS 视频${videoRunsDart ? '提供' : '不提供'} Dart 帧，'
          '${videoPhase == 0 ? '同相位' : '错开半周期'}，timing 批次=$batchSlots',
          (tester) async {
            var danmakuUpdates = 0;
            tester.view.display.refreshRate = 120;
            addTearDown(tester.view.display.resetRefreshRate);
            final origin = tester.binding.clock.now();
            final ticker = _ClockTicker(
              (_) => danmakuUpdates++,
              () => tester.binding.clock.now().microsecondsSinceEpoch,
            )..start();
            await tester.pump();
            final initialUpdates = danmakuUpdates;
            var videoFrames = 0;
            var dartFrames = 0;
            var combinedSlots = 0;
            var extraSlots = 0;
            var steadyExtra = 0;
            final timings = <FrameTiming>[];

            // 120 Hz 的 360 个槽位约为三秒，覆盖 release 的一秒报告批次。
            // 只有应用实际请求帧才 pump，避免测试自身逐槽驱动弹幕。
            for (var slot = 1; slot <= 360; slot++) {
              await tester.binding.delayed(const Duration(microseconds: 8334));
              final hasVideoFrame = slot % 2 == videoPhase;
              if (hasVideoFrame) {
                videoFrames++;
                if (videoRunsDart) tester.binding.scheduleFrame();
              }
              final hasDartFrame = tester.binding.hasScheduledFrame;
              if (hasDartFrame) {
                dartFrames++;
                await tester.pump();
              }
              if (hasVideoFrame || hasDartFrame) {
                final stamp =
                    origin.microsecondsSinceEpoch + slot * 8334 - 8333;
                timings.add(
                  FrameTiming(
                    vsyncStart: stamp,
                    buildStart: stamp + 1,
                    buildFinish: stamp + (hasDartFrame ? 2 : 1),
                    rasterStart: stamp + 3,
                    rasterFinish: stamp + 4,
                    rasterFinishWallTime: stamp + 4,
                  ),
                );
              }
              if (slot % batchSlots == 0) {
                tester.binding.platformDispatcher.onReportTimings?.call(
                  timings.toList(),
                );
                timings.clear();
              }
              if (hasVideoFrame || hasDartFrame) combinedSlots++;
              if (!hasVideoFrame && hasDartFrame) extraSlots++;
              if (slot > batchSlots + 24 && !hasVideoFrame && hasDartFrame) {
                steadyExtra++;
              }
            }
            ticker.dispose();
            await tester.binding.delayed(const Duration(seconds: 1));
            expect(tester.binding.hasScheduledFrame, isFalse);

            expect(videoFrames, 180);
            expect(danmakuUpdates - initialUpdates, inInclusiveRange(177, 182));
            // 相位学习允许起始阶段的额外请求，稳定后必须消除夹帧。
            expect(steadyExtra, 0);
            // 七个视频样本提供六个间隔，再等待批次送达和下一次相位应用。
            final startupAllowance = 7 + batchSlots ~/ 2 + 1;
            expect(combinedSlots, lessThanOrEqualTo(180 + startupAllowance));
            expect(extraSlots, lessThanOrEqualTo(startupAllowance));
            debugPrint(
              'videoDart=$videoRunsDart phase=$videoPhase '
              'video=$videoFrames danmaku=${danmakuUpdates - initialUpdates} '
              'dart=$dartFrames combined=$combinedSlots extra=$extraSlots',
            );
          },
        );
      }
    }
  }
}

class _ClockTicker extends FrameRateTicker {
  _ClockTicker(super.onTick, this.now) : super(frameRate: 60);
  final int Function() now;
  @override
  int get clockMicroseconds => now();
}
