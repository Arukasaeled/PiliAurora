import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/common/widgets/tab_activity.dart';

void main() {
  testWidgets('tab activity follows drag, programmatic jumps and its parent', (
    tester,
  ) async {
    final controller = TabController(length: 4, vsync: tester);
    final enabled = <int, bool>{};
    Widget scene(bool active) => TickerMode(
      enabled: active,
      child: Column(
        children: [
          for (var index = 0; index < 4; index++)
            TabActivity(
              controller: controller,
              index: index,
              child: Builder(
                builder: (context) {
                  enabled[index] = TickerMode.valuesOf(context).enabled;
                  return const SizedBox();
                },
              ),
            ),
        ],
      ),
    );
    await tester.pumpWidget(scene(true));
    expect(enabled, {0: true, 1: false, 2: false, 3: false});
    controller.offset = 0.5;
    await tester.pump();
    expect(enabled, {0: true, 1: true, 2: false, 3: false});
    controller
      ..offset = 0
      ..animateTo(3, duration: const Duration(milliseconds: 100));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(enabled, {0: true, 1: false, 2: false, 3: true});
    await tester.pumpAndSettle();
    expect(enabled, {0: false, 1: false, 2: false, 3: true});
    await tester.pumpWidget(scene(false));
    expect(enabled.values, everyElement(isFalse));
    await tester.pumpWidget(scene(true));
    expect(enabled[3], isTrue);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}
