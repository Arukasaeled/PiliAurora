import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dart:ui';

void main() {
  testWidgets('原生来源按播放器替换，停止和销毁时释放订阅', (tester) async {
    final first = _NativeFrames();
    final second = _NativeFrames();
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    final ticker = _ClockTicker(
      (_) {},
      () => tester.binding.clock.now().microsecondsSinceEpoch,
      first,
    )..start();
    await tester.pump();
    expect(first.observed, isTrue);
    ticker.videoFrameTimings = second;
    expect(first.observed, isFalse);
    expect(second.observed, isTrue);
    ticker.stop();
    expect(second.observed, isFalse);
    ticker.start();
    expect(second.observed, isTrue);
    ticker.dispose();
    expect(second.observed, isFalse);
    await tester.pump();
    await tester.binding.delayed(const Duration(seconds: 2));
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  for (final resetWhileStopped in [false, true]) {
    testWidgets('切源清空采样后放弃旧相位，stopped=$resetWhileStopped', (tester) async {
      tester.view.display.refreshRate = 120;
      addTearDown(tester.view.display.resetRefreshRate);
      final frames = ValueNotifier<List<int>>(const []);
      addTearDown(frames.dispose);
      final ticker = _ClockTicker(
        (_) {},
        () => tester.binding.clock.now().microsecondsSinceEpoch,
        frames,
      )..start();
      await tester.pump();
      final now = tester.binding.clock.now().microsecondsSinceEpoch;
      frames.value = [now - 33336 + 700, now - 16668 + 700];
      if (resetWhileStopped) {
        ticker.stop();
        frames.value = const [];
      } else {
        frames.value = const [];
        ticker.stop();
      }
      ticker.start();
      expect(tester.binding.hasScheduledFrame, isTrue);
      ticker.dispose();
      await tester.pump();
      await tester.binding.delayed(const Duration(seconds: 2));
      expect(tester.binding.hasScheduledFrame, isFalse);
    });
  }
  for (final offset in [-2000000, 100000]) {
    testWidgets('过期或时钟不匹配的原生批次不锁定相位，offset=$offset', (tester) async {
      final frames = ValueNotifier<List<int>>(const []);
      addTearDown(frames.dispose);
      final ticker = _ClockTicker(
        (_) {},
        () => tester.binding.clock.now().microsecondsSinceEpoch,
        frames,
      )..start();
      await tester.pump();
      final now = tester.binding.clock.now().microsecondsSinceEpoch;
      frames.value = [now + offset - 16668, now + offset];
      ticker
        ..stop()
        ..start();
      expect(tester.binding.hasScheduledFrame, isTrue);
      ticker.dispose();
      await tester.pump();
      await tester.binding.delayed(const Duration(seconds: 2));
      expect(tester.binding.hasScheduledFrame, isFalse);
    });
  }
  // 使用真实 FrameRateTicker 和 Flutter 测试时钟。纹理帧用时间槽记录，
  // 模拟独立的原生刷新源；这里不创建 GPU 纹理，也不测量屏幕实际 Hz。
  for (final batchSlots in [30, 120]) {
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
            final nativeFrames = ValueNotifier<List<int>>(const []);
            addTearDown(nativeFrames.dispose);
            final ticker = _ClockTicker(
              (_) => danmakuUpdates++,
              () => tester.binding.clock.now().microsecondsSinceEpoch,
              nativeFrames,
            )..start();
            await tester.pump();
            final initialUpdates = danmakuUpdates;
            var videoFrames = 0;
            var dartFrames = 0;
            var combinedSlots = 0;
            var extraSlots = 0;
            var steadyExtra = 0;
            final timings = <FrameTiming>[];
            final consumed = <int>[];

            // 120 Hz 的 360 个槽位约为三秒，覆盖 release 的一秒报告批次。
            // 只有应用实际请求帧才 pump，避免测试自身逐槽驱动弹幕。
            for (var slot = 1; slot <= 360; slot++) {
              await tester.binding.delayed(const Duration(microseconds: 8334));
              final hasVideoFrame = slot % 2 == videoPhase;
              if (hasVideoFrame) {
                videoFrames++;
                consumed.add(
                  origin.microsecondsSinceEpoch +
                      slot * 8334 -
                      8333 +
                      700 +
                      (slot % 3) * 1200,
                );
                if (videoRunsDart) tester.binding.scheduleFrame();
              }
              final hasDartFrame = tester.binding.hasScheduledFrame;
              if (hasDartFrame) {
                dartFrames++;
                await tester.pump();
              }
              if (hasDartFrame) {
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
                nativeFrames.value = consumed.sublist(
                  consumed.length > 32 ? consumed.length - 32 : 0,
                );
                consumed.clear();
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
            debugPrint(
              'native-frame-timings video=$videoFrames danmaku=${danmakuUpdates - initialUpdates} combined=$combinedSlots extra=$extraSlots steadyExtra=$steadyExtra',
            );
            expect(steadyExtra, 0);
            final startupAllowance = batchSlots ~/ 2 + 2;
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

  testWidgets('59.94 FPS 在 120 Hz 上漂移时持续跟随原生相位', (tester) async {
    tester.view.display.refreshRate = 120;
    addTearDown(tester.view.display.resetRefreshRate);
    final frames = ValueNotifier<List<int>>(const []);
    addTearDown(frames.dispose);
    final origin = tester.binding.clock.now().microsecondsSinceEpoch;
    var ticks = 0;
    final ticker = _ClockTicker(
      (_) => ticks++,
      () => tester.binding.clock.now().microsecondsSinceEpoch,
      frames,
    )..start();
    await tester.pump();
    final initialTicks = ticks;
    var videoFrames = 0;
    var extraSlots = 0;
    var nextVideo = 8334.0;
    final consumed = <int>[];
    for (var slot = 1; slot <= 1800; slot++) {
      await tester.binding.delayed(const Duration(microseconds: 8334));
      final hasVideo = slot * 8334 >= nextVideo;
      if (hasVideo) {
        nextVideo += 1000000 / 59.94;
        videoFrames++;
        consumed.add(origin + slot * 8334 - 8333 + 1000);
      }
      final hasDart = tester.binding.hasScheduledFrame;
      if (hasDart) await tester.pump();
      if (hasDart && !hasVideo) extraSlots++;
      if (slot % 30 == 0) {
        frames.value = consumed.toList();
        consumed.clear();
      }
    }
    ticker.dispose();
    await tester.binding.delayed(const Duration(seconds: 2));
    expect(tester.binding.hasScheduledFrame, isFalse);
    // 起步及视频跨到相邻槽位时，需要等待下一份 250 ms 原生批次。
    expect(extraSlots, lessThanOrEqualTo(34));
    expect(ticks - initialTicks, closeTo(videoFrames, 3));
    debugPrint(
      '59.94fps video=$videoFrames danmaku=${ticks - initialTicks} extra=$extraSlots',
    );
  });
}

class _ClockTicker extends FrameRateTicker {
  _ClockTicker(super.onTick, this.now, [ValueListenable<List<int>>? frames])
    : super(frameRate: 60, videoFrameTimings: frames);
  final int Function() now;
  @override
  int get clockMicroseconds => now();
}

class _NativeFrames extends ValueNotifier<List<int>> {
  _NativeFrames() : super(const []);
  bool get observed => hasListeners;
}
