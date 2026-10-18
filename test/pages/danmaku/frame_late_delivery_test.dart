import 'package:canvas_danmaku/frame_rate_ticker.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const screenPeriodUs = 8333;
  const targetIntervalUs = 16667;

  for (final lateUs in [0, 10000, 20000, 31600]) {
    testWidgets('定时唤醒迟到 ${lateUs}us 后只合并错过的槽位', (tester) async {
      tester.view.display.refreshRate = 120;
      addTearDown(tester.view.display.resetRefreshRate);
      final binding = tester.binding as AutomatedTestWidgetsFlutterBinding;
      final origin = binding.clock.now().microsecondsSinceEpoch;
      int now() => binding.clock.now().microsecondsSinceEpoch - screenPeriodUs;
      final updates = <int>[];
      final ticker = _LateTicker(
        (_) => updates.add(
          binding.currentSystemFrameTimeStamp.inMicroseconds - origin,
        ),
        now,
      )..start();
      await tester.pump();

      var slot = 0;
      while (slot < 120 * 2) {
        slot++;
        var target = origin + slot * screenPeriodUs;
        if (lateUs > 0 && slot == 120) {
          // 时钟推进但不交付已经到期的 Timer，模拟主线程暂停后的迟到唤醒。
          binding.elapseBlocking(Duration(microseconds: lateUs));
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
        'late=$lateUs updates=${updates.length} '
        'maxGapUs=${gaps.reduce((a, b) => a > b ? a : b)} '
        'longGaps=${longGaps.length} skips=${diagnostics['deadlineSkips']}',
      );
      expect(longGaps, hasLength(lateUs == 0 ? 0 : 1));
      if (lateUs > 0) {
        expect(longGaps.single, greaterThanOrEqualTo(lateUs));
        expect(longGaps.single, lessThanOrEqualTo(lateUs + targetIntervalUs));
        final index = gaps.indexOf(longGaps.single);
        expect(
          gaps.skip(index + 1),
          everyElement(lessThanOrEqualTo(targetIntervalUs + 1000)),
        );
      }
      expect(updates.length, inInclusiveRange(115, 122));
      expect(binding.hasScheduledFrame, isFalse);
    });
  }
}

class _LateTicker extends FrameRateTicker {
  _LateTicker(super.onTick, this.now) : super(frameRate: 60);

  final int Function() now;

  @override
  int get clockMicroseconds => now();
}
