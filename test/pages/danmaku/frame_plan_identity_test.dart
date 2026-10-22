import 'dart:ui' as ui;

import 'package:canvas_danmaku/frame_rate_ticker.dart';
import 'package:flutter/foundation.dart';
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
    // 固定 SDK 在 onBeginFrame 返回后、drawFrame 之前更新 FrameData。
    binding.addPersistentFrameCallback((_) {
      binding.frameDispatcher.number++;
    });
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
  _IdentityTicker(this.fixture, ValueNotifier<List<int>> frames)
    : super(
        (_) {},
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
