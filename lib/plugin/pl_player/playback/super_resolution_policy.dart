import 'dart:math' as math;

import 'package:media_kit_video/media_kit_video.dart';

enum SuperResolutionEligibility { allowed, unknownSize, resolutionTooHigh }

SuperResolutionEligibility superResolutionEligibility({
  required VideoOutputSize? source,
  required VideoOutputSize? display,
}) {
  if (source == null ||
      display == null ||
      source.width <= 0 ||
      source.height <= 0 ||
      display.width <= 0 ||
      display.height <= 0) {
    return .unknownSize;
  }
  // 用长短边比较物理像素，横竖屏旋转不改变设备可承载的分辨率。
  return math.max(source.width, source.height) >
              math.max(display.width, display.height) ||
          math.min(source.width, source.height) >
              math.min(display.width, display.height)
      ? .resolutionTooHigh
      : .allowed;
}
