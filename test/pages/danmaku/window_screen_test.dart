import 'dart:async';

import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/pages/danmaku/window_renderer.dart';
import 'package:pili_aurora/pages/danmaku/window_screen.dart';
import 'package:pili_aurora/plugin/pl_player/playback/media_clock.dart';

class _Clock implements PlaybackMediaClock {
  _Clock(this.currentMediaAnchor);
  @override
  PlaybackMediaAnchor? currentMediaAnchor;
  final events = StreamController<PlaybackMediaAnchor?>.broadcast(sync: true);
  @override
  Stream<PlaybackMediaAnchor?> get mediaAnchors => events.stream;
  void emit(PlaybackMediaAnchor? anchor) {
    currentMediaAnchor = anchor;
    events.add(anchor);
  }
}

PlaybackMediaAnchor _anchor({
  int position = 0,
  int observed = 0,
  int continuity = 0,
  bool advancing = true,
  int validFor = 10000000,
  double rate = 1,
}) => PlaybackMediaAnchor(
  positionUs: position,
  observedAtUs: observed,
  effectiveRate: rate,
  advancing: advancing,
  ready: true,
  continuity: continuity,
  validForUs: validFor,
);

Widget _host(Widget child) => Directionality(
  textDirection: TextDirection.ltr,
  child: MediaQuery(
    data: const MediaQueryData(size: Size(320, 120)),
    child: Center(child: SizedBox(width: 320, height: 120, child: child)),
  ),
);

DanmakuWindowRenderer<void> _renderer() => DanmakuWindowRenderer(
  option: const DanmakuOption(fontSize: 20, duration: 8, safeArea: false),
  size: const Size(320, 120),
);

void _prepare(DanmakuWindowRenderer<void> renderer, int position) {
  if (renderer.validUntilUs != renderer.validFromUs) return;
  renderer.prepare(
    [
      DanmakuWindowContent(
        'a',
        renderer.validFromUs,
        DanmakuContentItem<void>('clock', color: const Color(0xffffffff)),
      ),
    ],
    generation: renderer.generation,
    preparedUntilUs: renderer.validFromUs + 10000000,
  );
}

void _prepareMixed(DanmakuWindowRenderer<void> renderer, int position) {
  if (renderer.validUntilUs != renderer.validFromUs) return;
  renderer.prepare(
    [
      DanmakuWindowContent('a', 0, DanmakuContentItem<void>('scroll')),
      for (final at in [0, 500000]) ...[
        DanmakuWindowContent(
          'top-$at',
          at,
          DanmakuContentItem<void>('top', type: DanmakuItemType.top),
        ),
        DanmakuWindowContent(
          'bottom-$at',
          at,
          DanmakuContentItem<void>('bottom', type: DanmakuItemType.bottom),
        ),
      ],
    ],
    generation: renderer.generation,
    preparedUntilUs: 10000000,
  );
}

void main() {
  for (final videoRate in [24, 30, 60]) {
    testWidgets('$videoRate FPS 混合滚动与固定弹幕的锚点抖动不造成停顿和跳动', (
      tester,
    ) async {
      tester.view.display.refreshRate = 120;
      addTearDown(tester.view.display.resetRefreshRate);
      final origin = tester.binding.clock.now().microsecondsSinceEpoch;
      var now = origin;
      final clock = _Clock(_anchor(observed: origin));
      final renderer = DanmakuWindowRenderer<void>(
        option: const DanmakuOption(
          fontSize: 20,
          duration: 8,
          staticDuration: .25,
          safeArea: false,
        ),
        size: const Size(320, 120),
      );
      addTearDown(renderer.dispose);
      addTearDown(clock.events.close);
      await tester.pumpWidget(
        _host(
          DanmakuWindowScreen<void>(
            renderer: renderer,
            clock: clock,
            size: const Size(320, 120),
            monotonicUs: () => now,
            prepareFrame: (r, p, {required effectiveRate}) =>
                _prepareMixed(r, p),
          ),
        ),
      );
      final positions = <int>[];
      final lefts = <double>[];
      var fixedPeak = 0;
      var fixedExpiries = 0;
      var previousFixed = 0;
      final fixedBounds = <Object, Rect>{};
      final stride = 120 ~/ videoRate;
      for (var slot = 1; slot <= 120; slot++) {
        final sampled = slot % stride == 0;
        final delay = sampled && (slot ~/ stride).isEven ? 6000 : 1000;
        final delivered = origin + slot * 8333 + delay;
        await tester.binding.delayed(Duration(microseconds: delivered - now));
        now = delivered;
        if (sampled) {
          // time-pos 按视频帧推进；属性读取时刻包含本次通知的交付延迟。
          clock.emit(_anchor(position: slot * 8333, observed: now));
        }
        tester.binding.handleBeginFrame(
          Duration(microseconds: origin + (slot + 1) * 8333),
        );
        tester.binding.handleDrawFrame();
        positions.add(renderer.presentationTimeUs);
        final displayed = renderer.interaction.snapshot;
        lefts.add(displayed.singleWhere((s) => s.identity == 'a').bounds.left);
        final fixed = displayed.where((s) => s.identity != 'a').length;
        for (final item in displayed.where((s) => s.identity != 'a')) {
          final bounds = fixedBounds.putIfAbsent(
            item.identity,
            () => item.bounds,
          );
          expect(item.bounds, bounds);
        }
        if (fixed > fixedPeak) fixedPeak = fixed;
        if (previousFixed > 0 && fixed == 0) fixedExpiries++;
        previousFixed = fixed;
      }
      await tester.pumpWidget(const SizedBox.shrink());
      final steps = [
        for (var i = 1; i < positions.length; i++)
          positions[i] - positions[i - 1],
      ];
      expect(steps, everyElement(inInclusiveRange(7883, 8783)));
      expect(positions.last, closeTo(121 * 8333, 10000));
      expect(fixedPeak, 2);
      expect(fixedExpiries, 2);
      expect(fixedBounds.keys.toSet(), {
        'top-0',
        'bottom-0',
        'top-500000',
        'bottom-500000',
      });
      final nominalStep = (lefts.first - lefts.last) / (lefts.length - 1);
      for (var i = 1; i < lefts.length; i++) {
        expect(
          lefts[i - 1] - lefts[i],
          closeTo(nominalStep, nominalStep * .1),
        );
      }
    });
  }

  testWidgets('回调交付抖动不改变跟随屏幕时的逐帧位移', (tester) async {
    tester.view.display.refreshRate = 120;
    addTearDown(tester.view.display.resetRefreshRate);
    final origin = tester.binding.clock.now().microsecondsSinceEpoch;
    var now = origin;
    final clock = _Clock(_anchor(observed: origin));
    final renderer = _renderer();
    addTearDown(renderer.dispose);
    addTearDown(clock.events.close);
    await tester.pumpWidget(
      _host(
        DanmakuWindowScreen<void>(
          renderer: renderer,
          clock: clock,
          size: const Size(320, 120),
          monotonicUs: () => now,
          prepareFrame: (r, p, {required effectiveRate}) => _prepare(r, p),
        ),
      ),
    );
    final positions = <int>[];
    final lefts = <double>[];
    for (var slot = 1; slot <= 30; slot++) {
      final delivered = origin + slot * 8333 + (slot.isEven ? 6000 : 1000);
      await tester.binding.delayed(Duration(microseconds: delivered - now));
      now = delivered;
      clock.emit(_anchor(position: now - origin, observed: now));
      tester.binding.handleBeginFrame(
        Duration(microseconds: origin + (slot + 1) * 8333),
      );
      tester.binding.handleDrawFrame();
      positions.add(renderer.presentationTimeUs);
      lefts.add(renderer.interaction.snapshot.single.bounds.left);
    }
    await tester.pumpWidget(const SizedBox.shrink());
    final gaps = [
      for (var i = 1; i < positions.length; i++)
        positions[i] - positions[i - 1],
    ];
    expect(gaps, everyElement(8333));
    final step = lefts[0] - lefts[1];
    expect(step, greaterThan(0));
    for (var i = 2; i < lefts.length; i++) {
      expect(lefts[i - 1] - lefts[i], closeTo(step, .0001));
    }
  });

  testWidgets('parent rebuilds preserve scrolling time and frame cadence', (
    tester,
  ) async {
    tester.view.display.refreshRate = 120;
    addTearDown(tester.view.display.resetRefreshRate);
    var now = 0;
    final clock = _Clock(_anchor());
    final renderer = _renderer();
    addTearDown(renderer.dispose);
    addTearDown(clock.events.close);
    Widget screen() => _host(
      DanmakuWindowScreen<void>(
        renderer: renderer,
        clock: clock,
        size: const Size(320, 120),
        frameRate: 30,
        monotonicUs: () => now,
        frameTimeUs: () => now,
        prepareFrame: (r, p, {required effectiveRate}) => _prepare(r, p),
      ),
    );
    await tester.pumpWidget(screen());
    final positions = <int>{};
    for (var slot = 1; slot <= 120; slot++) {
      final next = (slot * 1000000 / 120).round();
      await tester.binding.delayed(Duration(microseconds: next - now));
      now = next;
      await tester.pumpWidget(screen());
      positions.add(renderer.presentationTimeUs);
    }
    expect(positions.length, inInclusiveRange(29, 31));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final refreshRate in [120, 165]) {
    for (final sampleStride in [1, 5]) {
      for (final target in [30, 60, 90]) {
        testWidgets(
          '$sampleStride-slot clock samples respect $target FPS presentation and gaps on $refreshRate Hz',
          (
            tester,
          ) async {
            tester.view.display.refreshRate = refreshRate.toDouble();
            addTearDown(tester.view.display.resetRefreshRate);
            var now = 0;
            final clock = _Clock(_anchor());
            final renderer = _renderer();
            final inputs = StreamController<Object?>.broadcast(sync: true);
            addTearDown(renderer.dispose);
            addTearDown(clock.events.close);
            addTearDown(inputs.close);
            await tester.pumpWidget(
              _host(
                DanmakuWindowScreen<void>(
                  renderer: renderer,
                  clock: clock,
                  size: const Size(320, 120),
                  frameRate: target,
                  inputChanges: inputs.stream,
                  monotonicUs: () => now,
                  frameTimeUs: () => now,
                  prepareFrame: (r, p, {required effectiveRate}) =>
                      _prepare(r, p),
                ),
              ),
            );
            final positions = <int>{};
            final moves = <int>[];
            var previous = renderer.presentationTimeUs;
            final initial = renderer.interaction.snapshot.single.bounds;
            for (var slot = 1; slot <= refreshRate; slot++) {
              final next = (slot * 1000000 / refreshRate).round();
              await tester.binding.delayed(Duration(microseconds: next - now));
              now = next;
              if (slot % sampleStride == 0) {
                clock.emit(_anchor(position: now, observed: now));
              }
              if (slot % 7 == 0) {
                for (var i = 0; i < 3; i++) {
                  inputs.add(null);
                }
              }
              tester.binding.scheduleFrame();
              await tester.pump();
              positions.add(renderer.presentationTimeUs);
              expect(
                renderer.interaction.snapshot.single.bounds.left,
                closeTo(
                  initial.left -
                      (320 + initial.width) *
                          renderer.presentationTimeUs /
                          8000000,
                  0.0001,
                ),
              );
              if (renderer.presentationTimeUs != previous) moves.add(now);
              previous = renderer.presentationTimeUs;
            }
            expect(positions.length, inInclusiveRange(target - 1, target + 1));
            for (var i = 1; i < moves.length; i++) {
              expect(
                moves[i] - moves[i - 1],
                inInclusiveRange(
                  (refreshRate / target).floor() * 1000000 ~/ refreshRate - 1,
                  ((refreshRate / target).ceil() * 1000000 / refreshRate)
                          .ceil() +
                      1,
                ),
              );
            }
            await tester.pumpWidget(const SizedBox.shrink());
          },
        );
      }
    }
  }

  for (final rate in [.5, 2.0]) {
    testWidgets(
      'rate change to $rate keeps scrolling monotonic across clock corrections',
      (tester) async {
        var now = 0;
        final clock = _Clock(_anchor(validFor: 500000));
        final renderer = _renderer();
        final mediaPositions = <int>[];
        addTearDown(renderer.dispose);
        addTearDown(clock.events.close);
        await tester.pumpWidget(
          _host(
            DanmakuWindowScreen<void>(
              renderer: renderer,
              clock: clock,
              size: const Size(320, 120),
              monotonicUs: () => now,
              frameTimeUs: () => now,
              prepareFrame: (r, p, {required effectiveRate}) {
                mediaPositions.add(p);
                _prepare(r, p);
              },
            ),
          ),
        );
        now = 200000;
        await tester.pump(const Duration(milliseconds: 200));
        final before = renderer.interaction.snapshot.single.bounds.left;
        final generation = renderer.generation;
        final positions = [before];
        clock.emit(
          _anchor(
            position: 180000,
            observed: now,
            rate: rate,
            validFor: 500000,
          ),
        );
        positions.add(renderer.interaction.snapshot.single.bounds.left);
        now += 100000;
        await tester.pump(const Duration(milliseconds: 100));
        positions.add(renderer.interaction.snapshot.single.bounds.left);
        clock.emit(
          _anchor(
            position: 160000 + (100000 * rate).round(),
            observed: now,
            rate: rate,
            validFor: 500000,
          ),
        );
        positions.add(renderer.interaction.snapshot.single.bounds.left);
        now += 100000;
        await tester.pump(const Duration(milliseconds: 100));
        positions.add(renderer.interaction.snapshot.single.bounds.left);
        expect(renderer.generation, generation);
        for (var index = 1; index < positions.length; index++) {
          expect(
            positions[index],
            lessThanOrEqualTo(positions[index - 1]),
            reason:
                'same-domain clock calibration must not move scrolling text right: $positions',
          );
        }
        expect(positions.last, lessThan(before));
        expect(mediaPositions.last, 160000 + (200000 * rate).round());
        clock
          ..emit(null)
          ..emit(
            _anchor(
              position: 100000,
              observed: now,
              continuity: 1,
              rate: rate,
              advancing: false,
            ),
          );
        expect(
          renderer.interaction.snapshot.single.bounds.left,
          greaterThan(positions.last),
          reason: 'a confirmed backward seek must still restore the earlier position',
        );
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('same-domain clock correction keeps the latest geometry cut', (
    tester,
  ) async {
    final clock = _Clock(_anchor(position: 1000000, advancing: false));
    final renderer = _renderer();
    addTearDown(renderer.dispose);
    addTearDown(clock.events.close);
    final positions = <int>[];
    await tester.pumpWidget(
      _host(
        DanmakuWindowScreen<void>(
          renderer: renderer,
          clock: clock,
          size: const Size(320, 120),
          monotonicUs: () => 0,
          frameTimeUs: () => 0,
          prepareFrame: (r, p, {required effectiveRate}) {
            positions.add(p);
            _prepare(r, p);
          },
        ),
      ),
    );
    renderer.updateTiming(
      mediaUs: 1000000,
      duration: 10,
      staticDuration: 5,
      scrollFixedVelocity: false,
    );
    final generation = renderer.generation;
    clock.emit(_anchor(position: 999000, advancing: false));
    expect(positions.last, 1000000);
    expect(renderer.generation, generation);
    clock.emit(_anchor(position: 500000, continuity: 1, advancing: false));
    expect(renderer.validFromUs, 500000);
    expect(renderer.generation, greaterThan(generation));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'future static content wakes at entry and expiry without continuous frames',
    (tester) async {
      var now = 0;
      final clock = _Clock(_anchor());
      final renderer = DanmakuWindowRenderer<void>(
        option: const DanmakuOption(
          fontSize: 20,
          staticDuration: 1,
          safeArea: false,
        ),
        size: const Size(320, 120),
      );
      addTearDown(renderer.dispose);
      addTearDown(clock.events.close);
      var frames = 0;
      int? nextPreparation = 1500000;
      await tester.pumpWidget(
        _host(
          DanmakuWindowScreen<void>(
            renderer: renderer,
            clock: clock,
            size: const Size(320, 120),
            monotonicUs: () => now,
            frameTimeUs: () => now,
            nextPreparationUs: () => nextPreparation,
            prepareFrame: (r, p, {required effectiveRate}) {
              frames++;
              if (p >= 1500000) nextPreparation = null;
              if (r.hasPrepared('fixed')) return;
              r.prepare(
                [
                  DanmakuWindowContent(
                    'fixed',
                    1000000,
                    DanmakuContentItem<void>(
                      'fixed',
                      type: DanmakuItemType.top,
                    ),
                  ),
                ],
                generation: r.generation,
                preparedUntilUs: 3000000,
              );
            },
          ),
        ),
      );
      expect(renderer.activeCount, 0);
      expect(tester.hasRunningAnimations, isFalse);
      final initial = frames;
      now = 200000;
      await tester.pump(const Duration(milliseconds: 200));
      expect(frames, initial);
      now = 1000000;
      await tester.pump(const Duration(milliseconds: 800));
      expect(renderer.activeCount, 1);
      expect(tester.hasRunningAnimations, isFalse);
      final afterEntry = frames;
      now = 1500000;
      await tester.pump(const Duration(milliseconds: 500));
      expect(frames, afterEntry + 1);
      expect(renderer.activeCount, 1);
      now = 2000000;
      await tester.pump(const Duration(milliseconds: 500));
      expect(renderer.activeCount, 0);
      expect(tester.hasRunningAnimations, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('preparation receives the observed media rate', (tester) async {
    final clock = _Clock(_anchor(rate: 2));
    final renderer = _renderer();
    addTearDown(renderer.dispose);
    addTearDown(clock.events.close);
    final rates = <double>[];
    await tester.pumpWidget(
      _host(
        DanmakuWindowScreen<void>(
          renderer: renderer,
          clock: clock,
          size: const Size(320, 120),
          monotonicUs: () => 0,
          frameTimeUs: () => 0,
          prepareFrame: (r, p, {required effectiveRate}) {
            rates.add(effectiveRate);
            _prepare(r, p);
          },
        ),
      ),
    );
    expect(rates.last, 2);
    clock.emit(_anchor(rate: .5, advancing: false));
    expect(rates.last, .5);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'frame time uses media anchor; pause freezes and invalidation clears',
    (tester) async {
      var now = 0;
      final clock = _Clock(_anchor());
      final renderer = _renderer();
      addTearDown(renderer.dispose);
      addTearDown(clock.events.close);
      final positions = <int>[];
      await tester.pumpWidget(
        _host(
          DanmakuWindowScreen<void>(
            renderer: renderer,
            clock: clock,
            size: const Size(320, 120),
            monotonicUs: () => now,
            frameTimeUs: () => now,
            prepareFrame: (r, p, {required effectiveRate}) {
              positions.add(p);
              _prepare(r, p);
            },
          ),
        ),
      );
      now = 100000;
      await tester.pump(const Duration(milliseconds: 100));
      expect(positions.last, 100000);
      clock.emit(_anchor(position: 200000, observed: now, advancing: false));
      final frames = positions.length;
      now = 900000;
      await tester.pump(const Duration(seconds: 1));
      expect(positions.last, 200000);
      expect(positions.length, frames);
      final previousHandle = renderer.interaction;
      final layouts = renderer.rasters.layouts;
      clock.emit(null);
      expect(previousHandle.isValid, isFalse);
      expect(renderer.activeCount, 0);
      clock.emit(
        _anchor(
          position: 500000,
          observed: now,
          continuity: 1,
          advancing: false,
        ),
      );
      expect(renderer.validFromUs, 0);
      expect(renderer.rasters.layouts, layouts);
      expect(positions.last, 500000);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(clock.events.hasListener, isFalse);
    },
  );

  testWidgets(
    'expired extrapolation stops frames until a fresh anchor arrives',
    (tester) async {
      var now = 0;
      final clock = _Clock(_anchor(validFor: 100000));
      final renderer = _renderer();
      addTearDown(renderer.dispose);
      addTearDown(clock.events.close);
      final positions = <int>[];
      await tester.pumpWidget(
        _host(
          DanmakuWindowScreen<void>(
            renderer: renderer,
            clock: clock,
            size: const Size(320, 120),
            monotonicUs: () => now,
            frameTimeUs: () => now,
            prepareFrame: (r, p, {required effectiveRate}) {
              positions.add(p);
              _prepare(r, p);
            },
          ),
        ),
      );
      now = 200000;
      await tester.pump(const Duration(milliseconds: 200));
      expect(positions.last, 100000);
      final frames = positions.length;
      now = 2000000;
      await tester.pump(const Duration(seconds: 1));
      expect(positions.length, frames);
      clock.emit(_anchor(position: 1000000, observed: now, validFor: 100000));
      now += 50000;
      await tester.pump(const Duration(milliseconds: 50));
      expect(positions.last, 1050000);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'paused input completion wakes one update and subscriptions detach on unmount',
    (tester) async {
      final clock = _Clock(_anchor(position: 500000, advancing: false));
      final updates = StreamController<Object?>.broadcast(sync: true);
      final renderer = _renderer();
      addTearDown(renderer.dispose);
      addTearDown(clock.events.close);
      addTearDown(updates.close);
      var ready = false;
      var frames = 0;
      await tester.pumpWidget(
        _host(
          DanmakuWindowScreen<void>(
            renderer: renderer,
            clock: clock,
            inputChanges: updates.stream,
            size: const Size(320, 120),
            monotonicUs: () => 0,
            frameTimeUs: () => 0,
            prepareFrame: (r, p, {required effectiveRate}) {
              frames++;
              if (ready) _prepare(r, p);
            },
          ),
        ),
      );
      expect(renderer.activeCount, 0);
      final before = frames;
      ready = true;
      updates.add(null);
      expect(renderer.activeCount, 1);
      expect(frames, before + 1);
      await tester.pump(const Duration(seconds: 1));
      expect(frames, before + 1);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(clock.events.hasListener, isFalse);
      expect(updates.hasListener, isFalse);
    },
  );

  testWidgets(
    'hiding stops work; showing evaluates absolute time; clock replacement detaches old events',
    (tester) async {
      var now = 0;
      final first = _Clock(_anchor());
      final second = _Clock(_anchor(position: 800000, advancing: false));
      final renderer = _renderer();
      addTearDown(renderer.dispose);
      addTearDown(first.events.close);
      addTearDown(second.events.close);
      final positions = <int>[];
      Widget screen(_Clock clock, double opacity, {bool enabled = true}) =>
          _host(
            TickerMode(
              enabled: enabled,
              child: DanmakuWindowScreen<void>(
                renderer: renderer,
                clock: clock,
                opacity: opacity,
                size: const Size(320, 120),
                monotonicUs: () => now,
                frameTimeUs: () => now,
                prepareFrame: (r, p, {required effectiveRate}) {
                  positions.add(p);
                  _prepare(r, p);
                },
              ),
            ),
          );
      await tester.pumpWidget(screen(first, 1));
      await tester.pumpWidget(screen(first, 0));
      final before = positions.length;
      now = 500000;
      await tester.pump(const Duration(milliseconds: 500));
      expect(positions.length, before);
      await tester.pumpWidget(screen(first, 1));
      expect(positions.last, 500000);
      await tester.pumpWidget(screen(first, 1, enabled: false));
      final mutedFrames = positions.length;
      now = 1500000;
      await tester.pump(const Duration(seconds: 1));
      expect(positions.length, mutedFrames);
      await tester.pumpWidget(screen(first, 1));
      expect(positions.last, 1500000);
      await tester.pumpWidget(screen(second, 1));
      expect(first.events.hasListener, isFalse);
      expect(positions.last, 800000);
      first.emit(null);
      expect(renderer.activeCount, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(second.events.hasListener, isFalse);
    },
  );
}
