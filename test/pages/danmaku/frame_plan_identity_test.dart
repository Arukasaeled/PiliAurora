import 'dart:ui' as ui;

import 'package:canvas_danmaku/frame_rate_ticker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:pili_aurora/pages/danmaku/frame_scheduler.dart';
import 'package:pili_aurora/plugin/pl_player/playback/frame_timing.dart';
import 'package:pili_aurora/plugin/pl_player/playback/presentation_profile.dart';

import 'frame_sync_fixture.dart';

void main() {
  final binding = _FrameDataBinding();

  testWidgets('帧计划核对帧末身份，忽略无关与重复 timing，停止后清除计划', (tester) async {
    tester.view.display.refreshRate = 120;
    addTearDown(tester.view.display.resetRefreshRate);
    final fixture = FrameSyncFixture(tester, 120);
    final frames = ValueNotifier<List<int>>([fixture.now]);
    addTearDown(frames.dispose);
    binding.frameDispatcher.number = 40;
    final ticker = _IdentityTicker(fixture, frames)..start();
    addTearDown(ticker.dispose);
    await tester.pump();
    final target = binding.currentSystemFrameTimeStamp.inMicroseconds;
    ui.FrameTiming timing(int number, {int lead = 33332}) => ui.FrameTiming(
      vsyncStart: target - lead,
      buildStart: target - lead + 100,
      buildFinish: target - lead + 200,
      rasterStart: target - lead + 300,
      rasterFinish: target - lead + 400,
      rasterFinishWallTime: target,
      frameNumber: number,
    );

    tester.platformDispatcher.onReportTimings!([timing(40)]);
    expect(ticker.diagnostics['presentationLeadUs'], isNull);
    tester.platformDispatcher.onReportTimings!([timing(41)]);
    expect(ticker.diagnostics['presentationLeadUs'], 33332);
    tester.platformDispatcher.onReportTimings!([timing(999, lead: 8333)]);
    expect(ticker.diagnostics['presentationLeadUs'], 33332);
    tester.platformDispatcher.onReportTimings!([timing(41, lead: 8333)]);
    expect(ticker.diagnostics['presentationLeadUs'], 33332);
    // 下一帧尚未上报 timing，停止必须丢弃其待匹配计划。
    await tester.pump(const Duration(milliseconds: 50));
    ticker.stop();
    tester.platformDispatcher.onReportTimings!([timing(42)]);
    expect(ticker.diagnostics['presentationLeadUs'], isNull);
    await tester.pump();
  });

  for (final badLead in [8333, 0, -8333, 200000]) {
    testWidgets('帧计划提前量 $badLead 连续异常后回退，恢复通知不反复切换', (tester) async {
      tester.view.display.refreshRate = 120;
      addTearDown(tester.view.display.resetRefreshRate);
      final fixture = FrameSyncFixture(tester, 120);
      final frames = ValueNotifier<List<int>>([]);
      addTearDown(frames.dispose);
      final updates = <int>[];
      final elapsed = <int>[];
      final ticker = _IdentityTicker(
        fixture,
        frames,
        onTick: (duration) {
          updates.add(binding.currentSystemFrameTimeStamp.inMicroseconds);
          elapsed.add(duration.inMicroseconds);
        },
      )..start();
      addTearDown(ticker.dispose);
      await tester.pump();
      Future<void> step(int slot, int lead) async {
        await fixture.elapseToSlot(slot);
        frames.value = [fixture.now];
        await fixture.pump(hasVideo: false);
        final target = binding.currentSystemFrameTimeStamp.inMicroseconds;
        tester.platformDispatcher.onReportTimings!([
          ui.FrameTiming(
            vsyncStart: target - lead,
            buildStart: target - lead + 100,
            buildFinish: target - lead + 200,
            rasterStart: target - lead + 300,
            rasterFinish: target - lead + 400,
            rasterFinishWallTime: target,
            frameNumber: binding.frameDispatcher.number,
          ),
        ]);
      }

      await step(1, 33332);
      await step(2, badLead);
      // 一次异常后有正常证据，重新累计，避免瞬时抖动触发回退。
      await step(3, 33332);
      await step(4, badLead);
      await step(5, badLead);
      expect(ticker.diagnostics['videoPhaseFallback'], isNull);
      await step(6, badLead);
      expect(ticker.diagnostics['videoPhaseFallback'], isNotNull);
      expect(ticker.diagnostics['preserveVideoPhase'], isFalse);
      expect(ticker.diagnostics['presentationLeadUs'], isNull);
      for (var slot = 7; slot <= 246; slot++) {
        await step(slot, 33332);
      }
      expect(ticker.diagnostics['mode'], 'independent');
      expect(updates.length, inInclusiveRange(122, 125));
      expect(elapsed.last - elapsed.first, updates.last - updates.first);
      expect([
        for (var i = 1; i < updates.length; i++) updates[i] - updates[i - 1],
      ], everyElement(inInclusiveRange(8333, 16667)));
      ticker
        ..invalidatePhase()
        ..configureVideoPhase(
          continuousVideoVsync: true,
          preserveVideoPhase: true,
        )
        ..stop()
        ..start();
      expect(ticker.diagnostics['preserveVideoPhase'], isFalse);
      ticker.stop();
      await tester.pump();
      await tester.binding.delayed(const Duration(seconds: 2));
      expect(tester.binding.hasScheduledFrame, isFalse);
    });
  }

  testWidgets('缺少同帧 timing 超时后回退，延迟批次正常时保持增强策略', (tester) async {
    tester.view.display.refreshRate = 120;
    addTearDown(tester.view.display.resetRefreshRate);
    final fixture = FrameSyncFixture(tester, 120);
    final frames = ValueNotifier<List<int>>([]);
    addTearDown(frames.dispose);
    final ticker = _IdentityTicker(fixture, frames)..start();
    addTearDown(ticker.dispose);
    await tester.pump();
    final timings = <ui.FrameTiming>[];
    for (var slot = 1; slot <= 840; slot++) {
      await fixture.elapseToSlot(slot);
      frames.value = [fixture.now];
      await fixture.pump(hasVideo: false);
      final target = binding.currentSystemFrameTimeStamp.inMicroseconds;
      timings.add(
        ui.FrameTiming(
          vsyncStart: target - 33332,
          buildStart: target - 33232,
          buildFinish: target - 33132,
          rasterStart: target - 33032,
          rasterFinish: target - 32932,
          rasterFinishWallTime: target,
          frameNumber: binding.frameDispatcher.number,
        ),
      );
      if (slot <= 360 && slot % 120 == 0) {
        tester.platformDispatcher.onReportTimings!(List.of(timings));
        timings.clear();
        expect(ticker.diagnostics['videoPhaseFallback'], isNull);
      }
      if (slot == 719) {
        expect(ticker.diagnostics['videoPhaseFallback'], isNull);
      }
    }
    expect(ticker.diagnostics['videoPhaseFallback'], 'missingFrameTiming');
    tester.platformDispatcher.onReportTimings!(timings);
    expect(ticker.diagnostics['preserveVideoPhase'], isFalse);
    ticker.stop();
    await tester.pump();
    await tester.binding.delayed(const Duration(seconds: 2));
    expect(tester.binding.hasScheduledFrame, isFalse);
  });
  testWidgets('显示调度合并一次性刷新，连续帧每帧一次，隐藏和释放撤销订阅', (tester) async {
    final source = _Source();
    addTearDown(source.frameState.dispose);
    final view = _View();
    final delivered = <DanmakuFrame>[];
    final scheduler = DanmakuFrameScheduler(onFrame: delivered.add);
    void configure({bool enabled = true, bool continuous = false}) =>
        scheduler.configure(
          view: view,
          source: source,
          targetFrameRate: 60,
          enabled: enabled,
          continuous: continuous,
        );
    configure();
    scheduler
      ..requestFrame()
      ..requestFrame();
    await tester.pump();
    expect(delivered, hasLength(1));
    expect(source.frameState.listening, isTrue);
    configure(continuous: true);
    scheduler.requestFrame();
    await tester.pump(const Duration(milliseconds: 17));
    expect(delivered, hasLength(2));
    configure();
    scheduler.requestFrame();
    configure(enabled: false);
    scheduler.requestFrame();
    await tester.pump(const Duration(milliseconds: 17));
    expect(delivered, hasLength(2));
    expect(source.frameState.listening, isFalse);
    configure();
    scheduler
      ..requestFrame()
      ..dispose();
    await tester.pump();
    expect(delivered, hasLength(2));
    expect(source.frameState.listening, isFalse);
  });

  testWidgets('同一 view 的换屏和变频在 timing 匹配前失效，来源快照按批次喂入一次', (tester) async {
    final source = _Source();
    addTearDown(source.frameState.dispose);
    final view = _View();
    final scheduler = DanmakuFrameScheduler(
      onFrame: (_) {},
      platform: TargetPlatform.android,
      engine: const PresentationEngineConfiguration(
        profile: PresentationProfile.androidFramePlan,
      ),
    );
    addTearDown(scheduler.dispose);
    scheduler.configure(
      view: view,
      source: source,
      targetFrameRate: 60,
      enabled: true,
      continuous: true,
    );
    await tester.pump(const Duration(milliseconds: 17));
    final target = binding.currentSystemFrameTimeStamp.inMicroseconds;
    final number = binding.frameDispatcher.number;
    ui.FrameTiming timing() => ui.FrameTiming(
      vsyncStart: target - 16000,
      buildStart: target - 15000,
      buildFinish: target - 14000,
      rasterStart: target - 13000,
      rasterFinish: target - 12000,
      rasterFinishWallTime: target,
      frameNumber: number,
    );
    tester.platformDispatcher.onReportTimings!([timing()]);
    expect(scheduler.diagnostics['presentationLeadUs'], 16000);
    final epoch = scheduler.diagnostics['viewEpoch'] as int;
    view.display.id++;
    tester.platformDispatcher.onReportTimings!([timing()]);
    expect(scheduler.diagnostics['viewEpoch'], epoch + 1);
    expect(scheduler.diagnostics['presentationLeadUs'], isNull);
    view.display.refreshRate = 90;
    scheduler.didChangeMetrics();
    expect(scheduler.diagnostics['viewEpoch'], epoch + 2);
    tester.platformDispatcher.onReportTimings!([timing()]);
    expect(scheduler.diagnostics['presentationLeadUs'], isNull);
    source
      ..emit(sequence: 10)
      ..emit(sequence: 10, sync: true)
      ..emit(sequence: 9);
    expect(scheduler.diagnostics['videoSampleBatches'], 1);
    source.emit(epoch: 2);
    tester.platformDispatcher.onReportTimings!([timing()]);
    expect(scheduler.diagnostics['presentationLeadUs'], isNull);
    source.emit(epoch: 2, sequence: 11);
    expect(scheduler.diagnostics['videoSampleBatches'], 2);
    final currentViewEpoch = scheduler.diagnostics['viewEpoch'];
    scheduler.configure(
      view: view,
      source: source,
      targetFrameRate: 60,
      enabled: true,
      continuous: true,
    );
    expect(scheduler.diagnostics['viewEpoch'], currentViewEpoch);
    expect(scheduler.diagnostics['videoSampleBatches'], 2);
    scheduler.dispose();
    await tester.pump();
  });
}

class _FrameDataBinding extends AutomatedTestWidgetsFlutterBinding {
  _FrameDataBinding() {
    // 固定 SDK 在 onBeginFrame 返回后、drawFrame 之前更新 FrameData。
    addPersistentFrameCallback((_) => frameDispatcher.number++);
  }

  _FrameDispatcher? _dispatcher;

  _FrameDispatcher get frameDispatcher => _dispatcher ??= _FrameDispatcher();

  @override
  TestPlatformDispatcher get platformDispatcher => frameDispatcher;
}

class _FrameDispatcher extends TestPlatformDispatcher {
  _FrameDispatcher()
    : super(platformDispatcher: ui.PlatformDispatcher.instance);

  int number = 0;

  @override
  ui.FrameData get frameData => _NumberedFrame(number);
}

class _NumberedFrame implements ui.FrameData {
  _NumberedFrame(this.frameNumber);

  @override
  final int frameNumber;
}

class _IdentityTicker extends FrameRateTicker {
  _IdentityTicker(
    this.fixture,
    ValueNotifier<List<int>> frames, {
    TickerCallback? onTick,
  }) : super(
         onTick ?? (_) {},
         frameRate: 60,
         videoFrameTimings: frames,
         continuousVideoVsync: true,
         preserveVideoPhase: true,
       );

  final FrameSyncFixture fixture;

  @override
  int get clockMicroseconds => fixture.now;
}

class _Source implements PlaybackFrameSource {
  static const output = OutputOperationToken(
    runtimeId: 1,
    loadId: 1,
    outputEpoch: 1,
    configRevision: 0,
  );
  _Source() {
    emit();
  }
  @override
  final _State frameState = _State();
  void emit({int epoch = 1, int? sequence, bool sync = false}) {
    frameState.value = PlaybackFrameState(
      output: output,
      samplingGeneration: epoch,
      admission: VideoFrameSamplingAdmission.active,
      epoch: epoch,
      displaySyncActive: sync,
      frameTimelineSupported: true,
      videoSamples: sequence == null
          ? null
          : VideoFrameBatch(
              output: output,
              samplingGeneration: epoch,
              kind: VideoFrameSampleKind.refreshRequested,
              sequence: sequence,
              monotonicUs: [1],
            ),
    );
  }
}

class _View implements ui.FlutterView {
  @override
  final _Display display = _Display();
  @override
  int get viewId => 1;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Display implements ui.Display {
  @override
  int id = 1;
  @override
  double refreshRate = 120;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _State extends ValueNotifier<PlaybackFrameState> {
  _State() : super(const PlaybackFrameState());
  bool get listening => hasListeners;
}
