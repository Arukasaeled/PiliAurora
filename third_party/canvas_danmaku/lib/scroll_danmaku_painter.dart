import 'dart:ui' as ui;

import 'package:canvas_danmaku/base_danmaku_painter.dart';
import 'package:canvas_danmaku/models/danmaku_item.dart';
import 'package:material_ui/material_ui.dart';

final class ScrollDanmakuPainter extends BaseDanmakuPainter {
  final double trackHeight;
  final List<List<DanmakuItem>> danmakuItems;

  const ScrollDanmakuPainter({
    required super.length,
    required this.trackHeight,
    required this.danmakuItems,
    required super.fontSize,
    required super.fontWeight,
    required super.strokeWidth,
    required super.running,
    required super.tick,
    super.tickSource,
    super.batchThreshold,
  });

  @override
  void paint(ui.Canvas canvas, ui.Size size) {
    final ui.PictureRecorder? pictureRecorder;
    final Canvas pictureCanvas;
    final length =
        danmakuItems.fold<int>(0, (sum, track) => sum + track.length);

    if (length > batchThreshold) {
      pictureRecorder = ui.PictureRecorder();
      pictureCanvas = Canvas(pictureRecorder);
    } else {
      pictureRecorder = null;
      pictureCanvas = canvas;
    }

    DanmakuItem? suspend;
    int suspendIndex = 0;
    for (int index = 0; index < danmakuItems.length; index++) {
      for (var i in danmakuItems[index]) {
        if (i.expired) continue;

        if (i.suspend) {
          suspend = i;
          suspendIndex = index;
          continue;
        }

        paintDanmaku(pictureCanvas, i, index * trackHeight);
      }
    }

    if (suspend case final suspend?) {
      paintDanmaku(pictureCanvas, suspend, suspendIndex * trackHeight);
    }

    if (pictureRecorder != null) {
      final ui.Picture picture = pictureRecorder.endRecording();
      canvas.drawPicture(picture);
      picture.dispose();
    }
  }

  void paintDanmaku(
    ui.Canvas canvas,
    DanmakuItem item,
    double yPos,
  ) {
    BaseDanmakuPainter.paintImg(
      canvas,
      item,
      item.xPosition,
      yPos,
    );
  }
}
