import 'package:canvas_danmaku/frame_rate_ticker.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const screenPeriodUs = 8333;
  const targetIntervalUs = 16667;
  final leads = [
    screenPeriodUs ~/ 2,
    screenPeriodUs * 3 ~/ 5,
    screenPeriodUs * 3 ~/ 4,
    screenPeriodUs * 7 ~/ 8,
    screenPeriodUs,
    screenPeriodUs * 6 ~/ 5,
    screenPeriodUs * 3 ~/ 2,
  ];
  final lateness = [0, 5000, 10000, 20000, 31600];

  for (final leadUs in leads) {
    for (final lateUs in lateness) {
      testWidgets('唤醒提前 $leadUs us / 迟到 $lateUs us', (tester) async {
        tester.view.display.refreshRate = 120;
        addTearDown(tester.view.display.resetRefreshRate);
        final binding = tester.binding as AutomatedTestWidgetsFlutterBinding;
        final origin = binding.clock.now().microsecondsSinceEpoch;
        int now() =>
            binding.clock.now().microsecondsSinceEpoch - screenPeriodUs;
        final updates = <int>[];
        final ticker = _LeadTicker(
          (_) => updates.add(
            binding.currentSystemFrameTimeStamp.inMicroseconds - origin,
          ),
          now,
          leadUs,
        )..start();
        await tester.pump();

        const lateSlot = 120;
        final lateTarget = origin + lateSlot * screenPeriodUs;
        final wakeTime = lateTarget - leadUs;
        var injected = false;
        var slot = 0;
        while (slot < 120 * 2) {
          slot++;
          var target = origin + slot * screenPeriodUs;
          final nowUs = binding.clock.now().microsecondsSinceEpoch;
          if (lateUs > 0 &&
              !injected &&
              slot <= lateSlot &&
              wakeTime > nowUs &&
              wakeTime <= target) {
            final untilWake = wakeTime - nowUs - 500;
            if (untilWake > 0) {
              await binding.delayed(Duration(microseconds: untilWake));
            }
            // 在 Timer 到期前开始阻塞，醒来时本次唤醒已经迟到。
            binding.elapseBlocking(Duration(microseconds: lateUs));
            injected = true;
            while (target <= binding.clock.now().microsecondsSinceEpoch) {
              slot++;
              target += screenPeriodUs;
            }
          }
          final delay = target - binding.clock.now().microsecondsSinceEpoch;
          if (delay > 0) {
            await binding.delayed(Duration(microseconds: delay));
          }
          if (binding.hasScheduledFrame) {
            binding.handleBeginFrame(Duration(microseconds: target));
            binding.handleDrawFrame();
          }
        }

        final diagnostics = ticker.diagnostics;
        ticker.dispose();
        await tester.pump();
        await binding.delayed(const Duration(seconds: 2));

        final gaps = [
          for (var i = 1; i < updates.length; i++) updates[i] - updates[i - 1],
        ];
        final longGaps = gaps
            .where((gap) => gap > targetIntervalUs + 1000)
            .toList();
        debugPrint(
          'lead=$leadUs late=$lateUs updates=${updates.length} '
          'maxGapUs=${gaps.reduce((a, b) => a > b ? a : b)} '
          'longGaps=${longGaps.length} '
          'requests=${diagnostics['frameRequests']} '
          'wakes=${diagnostics['timerWakeups']} '
          'skips=${diagnostics['deadlineSkips']}',
        );
        expect(longGaps.length, lessThanOrEqualTo(1));
        if (lateUs > 0) {
          if (longGaps.isNotEmpty) {
            final index = gaps.indexOf(longGaps.single);
            expect(
              gaps.skip(index + 1),
              everyElement(lessThanOrEqualTo(targetIntervalUs + 1000)),
            );
          }
        }
        expect(updates.length, inInclusiveRange(115, 122));
        expect(binding.hasScheduledFrame, isFalse);
      });
    }
  }
}

class _LeadTicker extends FrameRateTicker {
  _LeadTicker(super.onTick, this.now, int wakeLeadMicros)
    : super(frameRate: 60, wakeLeadMicros: wakeLeadMicros);

  final int Function() now;

  @override
  int get clockMicroseconds => now();
}
