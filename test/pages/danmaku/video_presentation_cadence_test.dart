import 'dart:ui' show FrameTiming;

import 'package:canvas_danmaku/frame_rate_ticker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'frame_sync_fixture.dart';

void main() {
  for (final videoRate in [24, 30, 60]) {
    testWidgets('$videoRate FPS 视频下持续请求 vsync，弹幕保持 60 FPS', (tester) async {
      tester.view.display.refreshRate = 120;
      addTearDown(tester.view.display.resetRefreshRate);
      final fixture = FrameSyncFixture(
        tester,
        120,
        model: FrameSyncModel.android,
      );
      final frames = ValueNotifier<List<int>>([fixture.now]);
      addTearDown(frames.dispose);
      final updates = <int>[];
      final ticker = _VideoTicker(
        (_) => updates.add(fixture.now),
        fixture,
        frames,
      )..start();
      await tester.pump();
      final delivered = <int>[];
      for (var slot = 1; slot <= 240; slot++) {
        await fixture.elapseToSlot(slot);
        final hasVideo = slot % (120 ~/ videoRate) == 0;
        if (hasVideo) frames.value = [fixture.now];
        if (await fixture.pump(hasVideo: hasVideo)) delivered.add(slot);
      }
      ticker.dispose();
      await tester.pump();
      await tester.binding.delayed(const Duration(seconds: 2));
      expect(tester.binding.hasScheduledFrame, isFalse);
      expect(delivered, List.generate(240, (i) => i + 1));
      expect(updates.length, inInclusiveRange(120, 121));
      expect([
        for (var i = 1; i < updates.length; i++) updates[i] - updates[i - 1],
      ], everyElement(inInclusiveRange(16666, 16667)));
    });
  }

  testWidgets('视频采样清空或过期后恢复限频，静音和停止释放请求', (tester) async {
    tester.view.display.refreshRate = 120;
    addTearDown(tester.view.display.resetRefreshRate);
    final fixture = FrameSyncFixture(tester, 120);
    final frames = ValueNotifier<List<int>>([fixture.now]);
    addTearDown(frames.dispose);
    final ticker = _VideoTicker((_) {}, fixture, frames)..start();
    await tester.pump();
    expect(ticker.diagnostics['requestEveryVsync'], isTrue);
    frames.value = [];
    await fixture.elapseToSlot(1);
    await fixture.pump(hasVideo: false);
    expect(ticker.diagnostics['requestEveryVsync'], isFalse);
    frames.value = [fixture.now];
    expect(ticker.diagnostics['requestEveryVsync'], isTrue);
    await tester.binding.delayed(const Duration(milliseconds: 1501));
    expect(ticker.diagnostics['requestEveryVsync'], isFalse);
    frames.value = [fixture.now];
    ticker.muted = true;
    expect(ticker.diagnostics['requestEveryVsync'], isFalse);
    ticker.muted = false;
    await tester.pump();
    expect(ticker.diagnostics['requestEveryVsync'], isTrue);
    ticker.stop();
    expect(ticker.diagnostics['requestEveryVsync'], isFalse);
    ticker.dispose();
    await tester.pump();
    await tester.binding.delayed(const Duration(seconds: 2));
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('按内容合成在持续回调中保留视频相位', (tester) async {
    tester.view.display.refreshRate = 120;
    addTearDown(tester.view.display.resetRefreshRate);
    final fixture = FrameSyncFixture(tester, 120);
    final frames = ValueNotifier<List<int>>([]);
    addTearDown(frames.dispose);
    final ticker = _VideoTicker(
      (_) {},
      fixture,
      frames,
      preserveVideoPhase: true,
    )..start();
    await tester.pump();
    for (var slot = 1; slot <= 160; slot++) {
      await fixture.elapseToSlot(slot);
      if (slot % 4 == 1) {
        frames.value = [fixture.requestForSlot(slot)];
      }
      await fixture.pump(hasVideo: slot % 4 == 1);
    }
    expect(ticker.diagnostics['requestEveryVsync'], isTrue);
    expect(ticker.diagnostics['mode'], 'locked');
    expect(ticker.diagnostics['syncPeriodUs'], closeTo(16667, 1));
    ticker.dispose();
    await tester.pump();
    await tester.binding.delayed(const Duration(seconds: 2));
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('帧计划按同帧 timing 还原提前量，停止后清除旧计划', (tester) async {
    tester.view.display.refreshRate = 120;
    addTearDown(tester.view.display.resetRefreshRate);
    final fixture = FrameSyncFixture(tester, 120);
    final frames = ValueNotifier<List<int>>([fixture.now]);
    addTearDown(frames.dispose);
    final ticker = _VideoTicker(
      (_) {},
      fixture,
      frames,
      preserveVideoPhase: true,
    )..start();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    final target = tester.binding.currentSystemFrameTimeStamp.inMicroseconds;
    final number = tester.platformDispatcher.frameData.frameNumber;
    FrameTiming timing(int frame, int lead) => FrameTiming(
      vsyncStart: target - lead,
      buildStart: target - lead + 100,
      buildFinish: target - lead + 200,
      rasterStart: target - lead + 300,
      rasterFinish: target - lead + 400,
      rasterFinishWallTime: target,
      frameNumber: frame,
    );
    tester.platformDispatcher.onReportTimings!([timing(number, 33332)]);
    expect(ticker.diagnostics['presentationLeadUs'], 33332);
    tester.platformDispatcher.onReportTimings!([timing(number + 999, 8333)]);
    expect(ticker.diagnostics['presentationLeadUs'], 33332);
    ticker.stop();
    tester.platformDispatcher.onReportTimings!([timing(number, 8333)]);
    expect(ticker.diagnostics['presentationLeadUs'], isNull);
    ticker.dispose();
    await tester.pump();
  });
}

class _VideoTicker extends FrameRateTicker {
  _VideoTicker(
    super.onTick,
    this.fixture,
    ValueListenable<List<int>> frames, {
    super.preserveVideoPhase,
  }) : super(
         frameRate: 60,
         videoFrameTimings: frames,
         continuousVideoVsync: true,
       );

  final FrameSyncFixture fixture;
  @override
  int get clockMicroseconds => fixture.now;
}
