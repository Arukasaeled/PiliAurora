import 'package:canvas_danmaku/base_danmaku_painter.dart';
import 'package:canvas_danmaku/models/danmaku_item.dart';
import 'package:material_ui/material_ui.dart';

final class StaticDanmakuPainter extends CustomPainter {
  final int count;
  final double trackHeight;
  final List<DanmakuItem?> danmakuItems;
  final double fontSize;
  final int fontWeight;
  final double strokeWidth;

  StaticDanmakuPainter({
    super.repaint,
    required this.count,
    required this.trackHeight,
    required this.danmakuItems,
    required this.fontSize,
    required this.fontWeight,
    required this.strokeWidth,
  });

  @override
  void paint(Canvas canvas, Size size) {
    for (int i = 0; i < danmakuItems.length; i++) {
      final item = danmakuItems[i];
      if (item != null) {
        BaseDanmakuPainter.paintImg(
          canvas,
          item,
          item.xPosition,
          trackHeight * i,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant StaticDanmakuPainter oldDelegate) =>
      oldDelegate.count != count ||
      oldDelegate.fontSize != fontSize ||
      oldDelegate.fontWeight != fontWeight ||
      oldDelegate.strokeWidth != strokeWidth;
}
