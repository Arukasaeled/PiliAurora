import 'dart:ui' as ui;

import 'package:canvas_danmaku/models/danmaku_content_item.dart';
import 'package:canvas_danmaku/text_renderer.dart';

class DanmakuItem<T> {
  /// 弹幕内容
  final DanmakuContentItem<T> content;

  /// 弹幕宽度
  double width;

  /// 弹幕高度
  double height;

  /// 弹幕水平方向位置
  double xPosition;

  /// 普通弹幕的最近更新时间；高级弹幕保留绘制时刻。
  int? drawTick;

  /// 弹幕布局缓存
  ui.Image? image;
  ui.Rect? specialBounds;

  bool expired = false;

  bool suspend = false;

  @pragma("vm:prefer-inline")
  bool needRemove(bool needRemove) {
    if (needRemove) {
      dispose();
    }
    return needRemove;
  }

  void invalidateImage() {
    image?.dispose();
    image = null;
  }

  void dispose() {
    invalidateImage();
    content.dispose();
  }

  DanmakuItem({
    required this.content,
    required this.height,
    required this.width,
    this.xPosition = 0,
    this.image,
    this.specialBounds,
    this.drawTick,
  });

  void drawParagraphIfNeeded(
    double fontSize,
    int fontWeight,
    double strokeWidth,
    DanmakuTextRenderer textRenderer,
  ) {
    if (image == null) {
      final paragraph = textRenderer.generateParagraph(
        content: content,
        fontSize: fontSize,
        fontWeight: fontWeight,
      );
      image = textRenderer.recordDanmakuImage(
        contentParagraph: paragraph,
        content: content,
        fontSize: fontSize,
        fontWeight: fontWeight,
        strokeWidth: strokeWidth,
      );
      width = paragraph.maxIntrinsicWidth +
          strokeWidth +
          (content.selfSend ? 4.0 : 0.0);
      height = paragraph.height + strokeWidth;
      paragraph.dispose();
    }
  }

  @override
  String toString() {
    return 'DanmakuItem(content=$content, xPos=$xPosition, size=${ui.Size(width, height)}, drawTick=$drawTick)';
  }
}
