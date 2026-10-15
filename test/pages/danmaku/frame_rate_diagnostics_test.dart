import 'package:canvas_danmaku/frame_rate_ticker.dart';
import 'package:flutter_test/flutter_test.dart';

import 'frame_sync_fixture.dart';

void main() {
  for (final rate in [120.00000762939453, 120.12]) {
    testWidgets('120 FPS 在 $rate Hz 屏幕上直接跟随 vsync', (tester) async {
      tester.view.display.refreshRate = rate;
      addTearDown(tester.view.display.resetRefreshRate);
      final ticker = FrameRateTicker((_) {}, frameRate: 120)..start();
      await tester.pump();
      expect(ticker.diagnostics['mode'], 'vsync');
      expect(ticker.diagnostics['timerWakeups'], 0);
      ticker.dispose();
      await tester.pump();
    });
  }

  testWidgets('诊断累计实际更新和请求，停止后无定时器活动', (tester) async {
    tester.view.display.refreshRate = 120;
    addTearDown(tester.view.display.resetRefreshRate);
    final fixture = FrameSyncFixture(tester, 120);
    var ticks = 0;
    final ticker = _ClockTicker((_) => ticks++, fixture);
    expect(ticker.diagnostics['mode'], 'stopped');
    expect(ticker.diagnostics['lastUpdateMonotonicUs'], isNull);
    ticker.start();
    await tester.pump();
    for (var slot = 1; slot <= 120; slot++) {
      await fixture.elapseToSlot(slot);
      await fixture.pump(hasVideo: false);
    }
    final stats = ticker.diagnostics;
    expect(stats['mode'], 'independent');
    expect(stats['updates'], ticks);
    expect(ticks, closeTo(61, 1));
    expect(stats['frameRequests'], ticks);
    expect(stats['timerWakeups'], ticks - 1);
    expect(stats['lastUpdateMonotonicUs'], fixture.now);
    expect(
      stats['lastFrameRequestMonotonicUs'],
      lessThanOrEqualTo(fixture.now),
    );
    ticker.muted = true;
    expect(ticker.diagnostics['mode'], 'muted');
    ticker.stop();
    final stopped = ticker.diagnostics;
    expect(stopped['mode'], 'stopped');
    await tester.binding.delayed(const Duration(seconds: 2));
    expect(ticker.diagnostics, stopped);
    expect(tester.binding.hasScheduledFrame, isFalse);
    ticker.dispose();
  });

  testWidgets('目标达到屏幕上限时报告 vsync 且不创建唤醒定时器', (tester) async {
    tester.view.display.refreshRate = 60;
    addTearDown(tester.view.display.resetRefreshRate);
    final ticker = FrameRateTicker((_) {}, frameRate: 60)..start();
    await tester.pump();
    expect(ticker.diagnostics['mode'], 'vsync');
    expect(ticker.diagnostics['updates'], 1);
    expect(ticker.diagnostics['timerWakeups'], 0);
    ticker.dispose();
    await tester.pump();
  });
}

class _ClockTicker extends FrameRateTicker {
  _ClockTicker(super.onTick, this.fixture) : super(frameRate: 60);

  final FrameSyncFixture fixture;

  @override
  int get clockMicroseconds => fixture.now;
}
