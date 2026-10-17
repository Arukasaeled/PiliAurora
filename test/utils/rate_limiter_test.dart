import 'package:pili_aurora/utils/rate_limiter.dart';
import 'package:flutter_test/flutter_test.dart';

// 在 widget binding 核对计时器之前，先清理本用例注册的全局标签。
void _timedTest(String name, Future<void> Function(WidgetTester) body) {
  testWidgets(name, (tester) async {
    try {
      await body(tester);
    } finally {
      ActionThrottle.cancel('first');
      ActionThrottle.cancel('second');
    }
  });
}

void main() {
  const interval = Duration(milliseconds: 100);

  _timedTest(
    'throttle runs the first action and drops duplicates until expiry',
    (
      tester,
    ) async {
      var calls = 0;
      expect(ActionThrottle.run('first', interval, () => calls++), isFalse);
      expect(calls, 1);
      expect(ActionThrottle.run('first', interval, () => calls++), isTrue);
      await tester.pump(const Duration(milliseconds: 99));
      expect(ActionThrottle.run('first', interval, () => calls++), isTrue);
      await tester.pump(const Duration(milliseconds: 1));
      expect(ActionThrottle.run('first', interval, () => calls++), isFalse);
      expect(calls, 2);
    },
  );

  _timedTest('cancel clears one tag without releasing other tags', (
    tester,
  ) async {
    ActionThrottle.run('first', interval, () {});
    ActionThrottle.run('second', interval, () {});
    ActionThrottle.cancel('first');
    ActionThrottle.cancel('first');
    expect(ActionThrottle.run('first', interval, () {}), isFalse);
    expect(ActionThrottle.run('second', interval, () {}), isTrue);
  });

  _timedTest('debouncer emits only the last action after the quiet period', (
    tester,
  ) async {
    final debouncer = Debouncer(interval);
    final values = <int>[];
    debouncer.run(() => values.add(1));
    await tester.pump(const Duration(milliseconds: 50));
    debouncer.run(() => values.add(2));
    await tester.pump(const Duration(milliseconds: 99));
    expect(values, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    expect(values, [2]);
  });
}
