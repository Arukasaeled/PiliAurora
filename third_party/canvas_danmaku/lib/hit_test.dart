import 'package:material_ui/material_ui.dart';

import 'package:canvas_danmaku/geometry.dart';
import 'package:canvas_danmaku/models/danmaku_item.dart';

/// 查询与绘制使用相同的活动项坐标，放大项保留完整高度。
Iterable<(double, DanmakuItem<T>)> hitTestDanmaku<T>({
  required Offset position,
  required double trackHeight,
  required List<DanmakuItem<T>?> fixed,
  required List<List<DanmakuItem<T>>> scrolling,
}) sync* {
  bool contains(DanmakuItem<T> item, double y) =>
      !item.expired &&
      DanmakuGeometry.contains(
        x: item.xPosition,
        y: y,
        width: item.width,
        height: item.height,
        pointX: position.dx,
        pointY: position.dy,
      );
  for (var track = 0; track < scrolling.length; track++) {
    final y = track * trackHeight;
    final item = fixed[track];
    if (item != null && contains(item, y)) yield (y, item);
    for (final item in scrolling[track].reversed) {
      if (contains(item, y)) yield (y, item);
    }
  }
}
