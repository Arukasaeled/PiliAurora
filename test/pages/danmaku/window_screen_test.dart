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

void main() {
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
      clock.emit(null);
      expect(renderer.activeCount, 0);
      clock.emit(
        _anchor(
          position: 500000,
          observed: now,
          continuity: 1,
          advancing: false,
        ),
      );
      expect(renderer.validFromUs, 500000);
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
