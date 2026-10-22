import 'dart:ui' as ui;

import 'package:canvas_danmaku/frame_rate_ticker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

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
