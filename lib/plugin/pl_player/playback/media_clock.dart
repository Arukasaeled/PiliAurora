/// 媒体位置与本进程单调时钟的不可变锚点。
///
/// observedAtUs 和求值时刻均使用 Timeline.now 的微秒时钟域。
class PlaybackMediaAnchor {
  const PlaybackMediaAnchor({
    required this.positionUs,
    required this.observedAtUs,
    required this.effectiveRate,
    required this.advancing,
    required this.ready,
    required this.continuity,
    required this.validForUs,
  }) : assert(effectiveRate > 0 && effectiveRate < double.infinity),
       assert(validForUs >= 0);

  final int positionUs;
  final int observedAtUs;
  final double effectiveRate;
  final bool advancing;
  final bool ready;
  final int continuity;
  final int validForUs;

  /// 无可用锚点时返回 null；过期采样停在可信外推区间的终点。
  int? positionAt(int monotonicUs) {
    if (!ready) return null;
    if (!advancing) return positionUs;
    final age = (monotonicUs - observedAtUs).clamp(0, validForUs);
    return positionUs + (age * effectiveRate).round();
  }
}

/// 普通位置采样独立于低频播放快照发布，null 表示旧锚点已失效。
abstract interface class PlaybackMediaClock {
  PlaybackMediaAnchor? get currentMediaAnchor;
  Stream<PlaybackMediaAnchor?> get mediaAnchors;
}
