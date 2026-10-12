import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/common/widgets/svg/play_icon.dart';

void main() {
  for (final size in [50.0, 60.0]) {
    testWidgets('播放图标保留 $size 布局尺寸、阴影外扩与语义', (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Center(child: PlayIcon(size: size)),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.getSize(find.byType(PlayIcon)), Size.square(size));
        expect(tester.getSize(find.byType(Image)), Size.square(size * 84 / 60));
        expect(find.bySemanticsLabel('播放'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    });
  }

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
}
