import 'dart:math' as math;

import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:pili_aurora/pages/danmaku/timeline_window.dart';

class DanmakuMeasuredCandidate<T> {
  const DanmakuMeasuredCandidate({
    required this.identity,
    required this.sourceUs,
    required this.width,
    required this.height,
    required this.type,
    required this.payload,
    this.estimatedBytes = 0,
    this.selfSend = false,
    this.renderable = true,
  });

  final Object identity;
  final int sourceUs;
  final double width;
  final double height;
  final DanmakuItemType type;
  final T payload;
  final int estimatedBytes;
  final bool selfSend;
  final bool renderable;
}

class DanmakuArrangement<T> {
  const DanmakuArrangement(
    this.candidate,
    this.trajectory,
    this.track,
    this.scrolling,
  );
  final DanmakuMeasuredCandidate<T> candidate;
  final DanmakuTrajectory? trajectory;
  final int track;
  final bool scrolling;
  bool get accepted => trajectory != null;
  double? xAt(int mediaUs) => trajectory?.xAt(mediaUs / 1000);
}

/// 普通点播的局部贪心编排，测量与绘制资源由两端显示适配持有。
class DanmakuWindowPlanner<T> {
  DanmakuWindowPlanner({
    required this.option,
    required this.width,
    required this.trackHeight,
    required this.trackCount,
    this.padding = 0,
    this.maxActive = DanmakuDisplayLimits.maxActive,
    DanmakuTimelineWindow<DanmakuArrangement<T>>? window,
  }) : window = window ?? DanmakuTimelineWindow(),
       _random = math.Random(0);

  final DanmakuOption option;
  final double width;
  final double trackHeight;
  final int trackCount;
  final double padding;
  final int maxActive;
  final DanmakuTimelineWindow<DanmakuArrangement<T>> window;
  final math.Random _random;

  bool prepare(
    List<DanmakuMeasuredCandidate<T>> candidates, {
    required int generation,
    required int preparedUntilUs,
  }) {
    if (generation != window.generation) return false;
    if (preparedUntilUs < window.validUntilUs) {
      throw ArgumentError.value(preparedUntilUs);
    }
    final known = {
      for (final item in window.preparedItems) item.identity: item,
    };
    final pending = <DanmakuMeasuredCandidate<T>>[];
    final identities = <Object>{};
    var bytes = window.estimatedBytes;
    int? previous;
    for (final candidate in candidates) {
      if (candidate.sourceUs < 0 ||
          candidate.sourceUs >= preparedUntilUs ||
          (previous != null && candidate.sourceUs < previous) ||
          !candidate.width.isFinite ||
          candidate.width < 0 ||
          !candidate.height.isFinite ||
          candidate.height <= 0 ||
          candidate.estimatedBytes < 0) {
        throw ArgumentError('候选必须按媒体时间有序，且测量与预算有效');
      }
      previous = candidate.sourceUs;
      if (known.containsKey(candidate.identity) ||
          !identities.add(candidate.identity)) {
        continue;
      }
      pending.add(candidate);
      bytes += candidate.estimatedBytes + 256;
    }
    if (known.length + pending.length > window.maxItems ||
        bytes > window.maxBytes) {
      return false;
    }
    final additions = <DanmakuWindowItem<DanmakuArrangement<T>>>[];
    for (final candidate in pending) {
      final arranged = _arrange(candidate, known.values);
      final item = DanmakuWindowItem(
        identity: candidate.identity,
        sourceUs: candidate.sourceUs,
        startUs: candidate.sourceUs,
        endUs: arranged.trajectory == null
            ? candidate.sourceUs + 1
            : (arranged.trajectory!.endMs * 1000).ceil(),
        estimatedBytes: candidate.estimatedBytes + 256,
        payload: arranged,
      );
      additions.add(item);
      known[item.identity] = item;
    }
    return window.extend(
      additions,
      generation: generation,
      preparedUntilUs: preparedUntilUs,
    );
  }

  DanmakuArrangement<T> _arrange(
    DanmakuMeasuredCandidate<T> candidate,
    Iterable<DanmakuWindowItem<DanmakuArrangement<T>>> existing,
  ) {
    DanmakuArrangement<T> rejected() =>
        DanmakuArrangement(candidate, null, -1, false);
    if (!candidate.renderable ||
        width <= 0 ||
        trackHeight <= 0 ||
        trackCount <= 0 ||
        option.duration <= 0 ||
        option.staticDuration <= 0 ||
        candidate.type == DanmakuItemType.special ||
        option.hideWhat(candidate.type)) {
      return rejected();
    }
    var scrolling = candidate.type == DanmakuItemType.scroll;
    DanmakuTrajectory trajectory(int track, bool scroll) {
      final speed = scroll
          ? DanmakuGeometry.scrollVelocity(
              width,
              candidate.width,
              option.durationInMilliseconds,
              fixed: option.scrollFixedVelocity,
            )
          : 0.0;
      final start = candidate.sourceUs / 1000;
      return DanmakuTrajectory(
        startMs: start,
        endMs:
            start +
            (scroll
                ? (width + candidate.width) / speed
                : option.staticDurationInMilliseconds),
        startX: scroll ? width : (width - candidate.width) / 2,
        y: track * trackHeight,
        width: candidate.width,
        height: candidate.height,
        velocity: speed,
      );
    }

    bool fits(int track) =>
        track >= 0 &&
        track + DanmakuGeometry.trackSpan(candidate.height, trackHeight) <=
            trackCount;
    bool blocks(
      DanmakuTrajectory motion,
      int track,
      bool scroll, {
      bool overlap = false,
    }) {
      for (final item in existing) {
        final old = item.payload;
        final oldMotion = old.trajectory;
        if (oldMotion == null) continue;
        final late = motion.startMs < oldMotion.startMs;
        if (DanmakuGeometry.blocks(
          late ? oldMotion : motion,
          late ? motion : oldMotion,
          trackHeight: trackHeight,
          viewWidth: width,
          candidateScrolling: late ? old.scrolling : scroll,
          existingScrolling: late ? scroll : old.scrolling,
          sameTrack: track == old.track,
          allowNormalOverlap: overlap,
          padding: padding,
        )) {
          return true;
        }
      }
      return false;
    }

    var track = -1;
    if (!scrolling) {
      for (var index = 0; index < trackCount; index++) {
        final choice = candidate.type == DanmakuItemType.bottom
            ? trackCount - index - 1
            : index;
        if (fits(choice) && !blocks(trajectory(choice, false), choice, false)) {
          track = choice;
          break;
        }
      }
      if (option.static2Scroll && (track < 0 || candidate.width > width)) {
        track = -1;
        scrolling = !option.hideScroll;
      }
    }
    if (scrolling) {
      for (var choice = 0; choice < trackCount; choice++) {
        if (fits(choice) && !blocks(trajectory(choice, true), choice, true)) {
          track = choice;
          break;
        }
      }
      if (track < 0 && (candidate.selfSend || option.massiveMode)) {
        final choice = candidate.selfSend ? 0 : _random.nextInt(trackCount);
        if (fits(choice) &&
            !blocks(trajectory(choice, true), choice, true, overlap: true)) {
          track = choice;
        }
      }
    }
    if (track < 0) return rejected();
    final motion = trajectory(track, scrolling);
    // 前瞻结果尚未入场；额度取共同存活区间的峰值，而非窗口总条数。
    final events = <(double, int)>[];
    for (final item in existing) {
      final other = item.payload.trajectory;
      if (other == null) continue;
      final start = math.max(motion.startMs, other.startMs);
      final end = math.min(motion.endMs, other.endMs);
      if (start < end) {
        events
          ..add((start, 1))
          ..add((end, -1));
      }
    }
    events.sort((a, b) {
      final time = a.$1.compareTo(b.$1);
      return time == 0 ? a.$2.compareTo(b.$2) : time;
    });
    var active = 1;
    if (active > maxActive) return rejected();
    for (final event in events) {
      active += event.$2;
      if (active > maxActive) return rejected();
    }
    return DanmakuArrangement(candidate, motion, track, scrolling);
  }
}
