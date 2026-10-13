import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/common/widgets/horizontal_wheel_scroll.dart';

void main() {
  testWidgets('vertical mouse wheel moves a horizontal list', (tester) async {
    final controller = ScrollController();
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 300,
            height: 80,
            child: HorizontalWheelScroll(
              child: ListView.builder(
                controller: controller,
                scrollDirection: Axis.horizontal,
                itemExtent: 100,
                itemCount: 20,
                itemBuilder: (_, index) => Text('$index'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final position = tester.getCenter(find.byType(ListView));
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: position,
        scrollDelta: const Offset(0, 120),
      ),
    );
    await tester.pump();
    expect(controller.offset, 120);
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: position,
        scrollDelta: const Offset(0, -200),
      ),
    );
    await tester.pump();
    expect(controller.offset, 0);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}
