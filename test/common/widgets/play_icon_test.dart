import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/common/widgets/svg/play_icon.dart';

void main() {
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
