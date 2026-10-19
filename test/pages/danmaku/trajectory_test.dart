import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:canvas_danmaku/geometry.dart';

DanmakuTrajectory _motion({
  double start = 0,
  double end = 1000,
  double x = 100,
  double y = 0,
  double width = 20,
  double velocity = 0.1,
}) => DanmakuTrajectory(
  startMs: start,
  endMs: end,
  startX: x,
  y: y,
  width: width,
  height: 20,
  velocity: velocity,
);

void main() {
  test('共享准入按未来有效期检查放大项，普通静态与滚动可共行', () {
    bool blocks(
      DanmakuTrajectory candidate,
      DanmakuTrajectory existing, {
      bool scrolling = true,
      bool previousScrolling = true,
      bool sameTrack = true,
      bool massive = false,
    }) => DanmakuGeometry.blocks(
      candidate,
      existing,
      trackHeight: 20,
      viewWidth: 100,
      candidateScrolling: scrolling,
      existingScrolling: previousScrolling,
      sameTrack: sameTrack,
      allowNormalOverlap: massive,
    );
    final fixed = _motion(x: 40, velocity: 0);
    final scrolling = _motion(x: 100, velocity: .1);
    expect(blocks(scrolling, fixed, previousScrolling: false), isFalse);
    expect(
      blocks(fixed, fixed, scrolling: false, previousScrolling: false),
      isTrue,
    );
    const large = DanmakuTrajectory(
      startMs: 0,
      endMs: 1000,
      startX: 40,
      y: 0,
      width: 20,
      height: 40,
      velocity: 0,
    );
    expect(
      blocks(_motion(y: 20), large, sameTrack: false, previousScrolling: false),
      isTrue,
    );
    expect(
      blocks(
        _motion(start: 1000, end: 2000, y: 20),
        large,
        sameTrack: false,
        previousScrolling: false,
      ),
      isFalse,
    );
    expect(blocks(scrolling, scrolling, massive: true), isFalse);
    expect(
      blocks(
        _motion(y: 20),
        large,
        sameTrack: false,
        previousScrolling: false,
        massive: true,
      ),
      isTrue,
    );
  });

  test('冻结滚动项持续占位直到解除，命中使用当前矩形边界', () {
    final frozen = _motion(x: 40, velocity: 0, end: double.infinity);
    expect(
      DanmakuGeometry.blocks(
        _motion(),
        frozen,
        trackHeight: 20,
        viewWidth: 100,
        candidateScrolling: true,
        existingScrolling: true,
        sameTrack: true,
      ),
      isTrue,
    );
    expect(
      DanmakuGeometry.contains(
        x: 40,
        y: 20,
        width: 30,
        height: 40,
        pointX: 50,
        pointY: 55,
      ),
      isTrue,
    );
    expect(
      DanmakuGeometry.contains(
        x: 40,
        y: 20,
        width: 30,
        height: 40,
        pointX: 50,
        pointY: 61,
      ),
      isFalse,
    );
  });

  test('position is independent of frame count', () {
    final motion = _motion();
    expect(motion.xAt(0), 100);
    expect(motion.xAt(250), 75);
    expect(motion.xAt(1000), 0);
  });

  test('future catch-up is detected before current rectangles overlap', () {
    final previous = _motion(x: 30, velocity: 0.05);
    final next = _motion(x: 100, velocity: 0.2);
    expect(previous.overlapsDuring(next), isTrue);
    expect(previous.canBeFollowedBy(20, 0.2, 100, 0), isFalse);
    expect(previous.canBeFollowedBy(20, 0.05, 100, 0), isTrue);
  });

  test('disjoint lifetimes and tracks need no group composition', () {
    expect(_motion().overlapsDuring(_motion(start: 1000, end: 2000)), isFalse);
    expect(_motion().overlapsDuring(_motion(y: 24), padding: 1), isFalse);
    expect(_motion().overlapsDuring(_motion(y: 21), padding: 1), isTrue);
  });

  test('overlap certification has no sampled false negatives', () {
    final random = math.Random(42);
    for (var example = 0; example < 1000; example++) {
      DanmakuTrajectory generate() => _motion(
        start: random.nextDouble() * 500,
        end: 500 + random.nextDouble() * 500,
        x: random.nextDouble() * 400,
        y: random.nextDouble() * 80,
        width: 10 + random.nextDouble() * 80,
        velocity: random.nextDouble() * 0.5,
      );
      final first = generate();
      final second = generate();
      if (first.overlapsDuring(second, padding: 1)) continue;
      final start = math.max(first.startMs, second.startMs);
      final end = math.min(first.endMs, second.endMs);
      for (var sample = 0; sample < 100; sample++) {
        final time = start + (end - start) * sample / 100;
        final overlap =
            time < end &&
            first.y + first.height + 1 > second.y - 1 &&
            second.y + second.height + 1 > first.y - 1 &&
            first.xAt(time) + first.width + 1 > second.xAt(time) - 1 &&
            second.xAt(time) + second.width + 1 > first.xAt(time) - 1;
        expect(overlap, isFalse, reason: 'case $example sample $sample');
      }
    }
  });
}
