import 'package:canvas_danmaku/frame_rate_ticker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'frame_sync_fixture.dart';

void main() {
  for (final videoRate in [24, 30, 60, 23.976, 29.97, 59.94]) {
    for (final target in [60, 90]) {
      for (final pattern in ['steady', 'phase-step', 'request-jitter']) {
        if (videoRate != videoRate.round() && pattern != 'steady') continue;
        testWidgets('$videoRate FPS 视频 / $target FPS 弹幕，$pattern 时保持更新间隔', (
          tester,
        ) async {
          tester.view.display.refreshRate = 120;
          addTearDown(tester.view.display.resetRefreshRate);
          final fixture = FrameSyncFixture(
            tester,
            120,
            model: FrameSyncModel.android,
          );
          final frames = ValueNotifier<List<int>>(const []);
          final slots = <int>[];
          var currentSlot = 0;
          final ticker = _ClockTicker(
            (_) => slots.add(currentSlot),
            fixture,
            frames,
            target,
          )..start();
          await tester.pump();
          // 模拟原生250ms批次；每秒变更一次相位，覆盖重新锁相边界。
          final available = <int>[];
          for (currentSlot = 1; currentSlot <= 1440; currentSlot++) {
            await fixture.elapseToSlot(currentSlot);
            final shift = pattern == 'phase-step'
                ? (currentSlot ~/ 120) % 2
                : 0;
            final hasVideo =
                ((currentSlot - shift) * videoRate / 120).floor() >
                ((currentSlot - shift - 1) * videoRate / 120).floor();
            if (hasVideo) {
              final jitter =
                  pattern == 'request-jitter' &&
                      (currentSlot ~/ (120 ~/ videoRate)).isOdd
                  ? 9000
                  : 0;
              available.add(fixture.requestForSlot(currentSlot) + jitter);
            }
            await fixture.pump(hasVideo: hasVideo);
            if (currentSlot % 30 == 0) {
              frames.value = available.toList();
              available.clear();
            }
          }
          ticker.dispose();
          frames.dispose();
          await tester.pump();
          await tester.binding.delayed(const Duration(seconds: 2));
          final gaps = <int, int>{};
          for (var i = 1; i < slots.length; i++) {
            if (slots[i - 1] < 240) continue;
            final gap = slots[i] - slots[i - 1];
            gaps[gap] = (gaps[gap] ?? 0) + 1;
          }
          expect(gaps, isNotEmpty);
          expect(
            gaps.keys,
            everyElement(inInclusiveRange(1, 2)),
            reason: '相位校准把更新推迟了一个屏幕槽位：$gaps',
          );
        });
      }
    }
  }
}

class _ClockTicker extends FrameRateTicker {
  _ClockTicker(
    super.onTick,
    this.fixture,
    ValueListenable<List<int>> frames,
    int target,
  ) : super(frameRate: target, videoFrameTimings: frames);
  final FrameSyncFixture fixture;
  @override
  int get clockMicroseconds => fixture.now;
}
