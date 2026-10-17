import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/common/widgets/svg/play_icon.dart';

void main() {
  testWidgets('播放图标保留布局尺寸、阴影外扩与语义', (tester) async {
    const size = 50.0;
    final semantics = tester.ensureSemantics();
    try {
      await tester.pumpWidget(
        const MaterialApp(
          home: Center(child: PlayIcon(size: size)),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(PlayIcon)), const Size.square(size));
      expect(
        tester.getSize(find.byType(Image)),
        const Size.square(size * 84 / 60),
      );
      expect(find.bySemanticsLabel('播放'), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('父布局约束较小时按实际尺寸缩放', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(child: SizedBox.square(dimension: 30, child: PlayIcon())),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(PlayIcon)), const Size.square(30));
    expect(tester.getSize(find.byType(Image)), const Size.square(42));
    expect(tester.takeException(), isNull);
  });
  testWidgets('播放图标及边缘的点击透传到封面', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 300,
            height: 200,
            child: Stack(
              children: [
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => taps++,
                  ),
                ),
                const Positioned(
                  right: 12,
                  top: 130,
                  child: PlayIcon(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    final rect = tester.getRect(find.byType(PlayIcon));
    for (final point in [
      rect.center,
      rect.topLeft + const Offset(1, 1),
      rect.bottomRight - const Offset(1, 1),
      rect.centerLeft - const Offset(5, 0),
    ]) {
      await tester.tapAt(point);
      expect(taps, greaterThan(0));
      taps = 0;
    }
  });
}
