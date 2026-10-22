import 'dart:math' as math;

import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter/animation.dart';

/// 高级脚本的只读帧结果，栅格边界仍由各显示实例持有。
class DanmakuSpecialFrame {
  const DanmakuSpecialFrame(this.bounds, this.color);
  final Rect bounds;
  final Color color;

  static DanmakuSpecialFrame? evaluate({
    required SpecialDanmakuContentItem content,
    required Rect rasterBounds,
    required Size size,
    required int sourceUs,
    required int mediaUs,
  }) {
    final elapsed = (mediaUs - sourceUs) / 1000;
    if (elapsed < 0 || elapsed >= content.duration) return null;
    final color = content.alphaTween == null
        ? content.color
        : content.color.withValues(
            alpha: content.alphaTween!.transform(elapsed / content.duration),
          );
    var progress = 0.0;
    if (elapsed > content.translationStartDelay) {
      progress = content.easingType.transform(
        content.translationDuration <= 0
            ? 1
            : math.min(
                1.0,
                (elapsed - content.translationStartDelay) /
                    content.translationDuration,
              ),
      );
    }
    double offset(Tween<double> tween) =>
        tween is ConstantTween ? tween.begin! : tween.transform(progress);
    return DanmakuSpecialFrame(
      Rect.fromLTWH(
        offset(content.translateXTween) * size.width + rasterBounds.left,
        offset(content.translateYTween) * size.height + rasterBounds.top,
        rasterBounds.width,
        rasterBounds.height,
      ),
      color,
    );
  }
}
