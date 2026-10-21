import 'dart:ui' as ui;

import 'package:canvas_danmaku/frame_rate_ticker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'frame_sync_fixture.dart';

void main() {
  final binding = _FrameDataBinding();

  testWidgets('BeginFrame 返回后发布的帧号与本帧目标关联', (tester) async {
    tester.view.display.refreshRate = 120;
    addTearDown(tester.view.display.resetRefreshRate);
    final fixture = FrameSyncFixture(tester, 120);
    final frames = ValueNotifier<List<int>>([fixture.now]);
    addTearDown(frames.dispose);
    binding.frameDispatcher.number = 40;
    // 固定 SDK 在 onBeginFrame 返回后、drawFrame 之前更新 FrameData。
    binding.addPersistentFrameCallback((_) {
      binding.frameDispatcher.number = 41;
    });
    final ticker = _IdentityTicker(fixture, frames)..start();
    await tester.pump();
    final target = binding.currentSystemFrameTimeStamp.inMicroseconds;
    ui.FrameTiming timing(int number) => ui.FrameTiming(
      vsyncStart: target - 33332,
      buildStart: target - 33200,
      buildFinish: target - 33000,
      rasterStart: target - 32000,
      rasterFinish: target - 31000,
      rasterFinishWallTime: target,
      frameNumber: number,
    );

    tester.platformDispatcher.onReportTimings!([timing(40)]);
    expect(ticker.diagnostics['presentationLeadUs'], isNull);
    tester.platformDispatcher.onReportTimings!([timing(41)]);
    expect(ticker.diagnostics['presentationLeadUs'], 33332);
    ticker.dispose();
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
