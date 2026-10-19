import 'dart:math' as math;

class DanmakuTrajectory {
  const DanmakuTrajectory({
    required this.startMs,
    required this.endMs,
    required this.startX,
    required this.y,
    required this.width,
    required this.height,
    required this.velocity,
  });

  final double startMs;
  final double endMs;
  final double startX;
  final double y;
  final double width;
  final double height;
  final double velocity;

  double xAt(double milliseconds) =>
      startX - (milliseconds - startMs) * velocity;

  bool overlapsDuring(DanmakuTrajectory other, {double padding = 0}) {
    if (y + height + padding <= other.y - padding ||
        other.y + other.height + padding <= y - padding) {
      return false;
    }
    final start = math.max(startMs, other.startMs);
    final end = math.min(endMs, other.endMs);
    if (end <= start) return false;
    final relativeStart = xAt(start) - other.xAt(start);
    final relativeEnd = xAt(end) - other.xAt(end);
    return math.max(relativeStart, relativeEnd) > -width - padding * 2 &&
        math.min(relativeStart, relativeEnd) < other.width + padding * 2;
  }

  bool canBeFollowedBy(
    double nextWidth,
    double nextVelocity,
    double viewWidth,
    double milliseconds,
  ) {
    return DanmakuGeometry.canFollow(
      x: xAt(milliseconds),
      width: width,
      velocity: velocity,
      nextVelocity: nextVelocity,
      viewWidth: viewWidth,
    );
  }
}

/// 普通弹幕共用的速度与入场追尾规则，时间单位为毫秒。
abstract final class DanmakuGeometry {
  static int trackSpan(double height, double trackHeight) =>
      math.max(1, (height / trackHeight).ceil());

  static bool contains(
          {required double x,
          required double y,
          required double width,
          required double height,
          required double pointX,
          required double pointY}) =>
      x <= pointX && pointX <= x + width && y <= pointY && pointY <= y + height;

  /// 放大项按完整有效轨迹占位，普通静态项与普通滚动项允许共用基础行。
  static bool blocks(
    DanmakuTrajectory candidate,
    DanmakuTrajectory existing, {
    required double trackHeight,
    required double viewWidth,
    required bool candidateScrolling,
    required bool existingScrolling,
    required bool sameTrack,
    bool allowNormalOverlap = false,
    double padding = 0,
  }) {
    if (math.min(candidate.endMs, existing.endMs) <=
        math.max(candidate.startMs, existing.startMs)) {
      return false;
    }
    if (candidate.height > trackHeight || existing.height > trackHeight) {
      return candidate.overlapsDuring(existing, padding: padding);
    }
    if (!sameTrack || allowNormalOverlap) return false;
    if (!candidateScrolling && !existingScrolling) return true;
    if (candidateScrolling && existingScrolling) {
      return !existing.canBeFollowedBy(
          candidate.width, candidate.velocity, viewWidth, candidate.startMs);
    }
    return false;
  }

  static double scrollVelocity(
          double viewWidth, double width, double durationMs,
          {required bool fixed}) =>
      (viewWidth + (fixed ? 0 : width)) / durationMs;

  static bool canFollow(
      {required double x,
      required double width,
      required double velocity,
      required double nextVelocity,
      required double viewWidth}) {
    final right = x + width;
    return right <= viewWidth &&
        (nextVelocity <= velocity ||
            right * nextVelocity <= viewWidth * velocity);
  }
}
