import 'dart:async';

import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/pages/danmaku/interaction.dart';
import 'package:pili_aurora/pages/danmaku/live_layer.dart';
import 'package:pili_aurora/pages/danmaku/live_queue.dart';

void main() {
  testWidgets(
    'parent rebuilds retain live elapsed time between limited frames',
    (tester) async {
      tester.view.display.refreshRate = 120;
      addTearDown(tester.view.display.resetRefreshRate);
      final messages = StreamController<LiveDanmakuMessage<void>>.broadcast(
        sync: true,
      );
      var now = 0;
      late DanmakuInteractionHandle<void> Function() interaction;
      Widget screen() => Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: const MediaQueryData(),
          child: LiveDanmakuLayer<void>(
            messages: messages.stream,
            running: true,
            visible: true,
            option: const DanmakuOption(duration: 8),
            size: const Size(800, 400),
            frameRate: 30,
            monotonicUs: () => now,
            createdInteraction: (get, _) => interaction = get,
          ),
        ),
      );
      await tester.pumpWidget(screen());
      messages.add(
        const LiveDanmakuMessage(
          identity: 'one',
          receivedAtUs: 0,
          text: 'scroll',
        ),
      );
      await tester.pump();
      final initial = interaction().snapshot.single.bounds;
      var previous = initial.left;
      final moves = <int>[];
      for (var slot = 1; slot <= 120; slot++) {
        final next = (slot * 1000000 / 120).round();
        await tester.binding.delayed(Duration(microseconds: next - now));
        now = next;
        await tester.pumpWidget(screen());
        final x = interaction().snapshot.single.bounds.left;
        if (x != previous) moves.add(now);
        previous = x;
      }
      expect(moves.length, inInclusiveRange(29, 31));
      expect(
        initial.left - previous,
        closeTo((800 + initial.width) / 8 * moves.last / 1000000, 0.0001),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await messages.close();
    },
  );

  testWidgets('message arrivals preserve 30 FPS scrolling cadence on 120 Hz', (
    tester,
  ) async {
    tester.view.display.refreshRate = 120;
    addTearDown(tester.view.display.resetRefreshRate);
    final messages = StreamController<LiveDanmakuMessage<void>>.broadcast(
      sync: true,
    );
    var now = 0;
    late DanmakuInteractionHandle<void> Function() interaction;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: const MediaQueryData(),
          child: LiveDanmakuLayer<void>(
            messages: messages.stream,
            running: true,
            visible: true,
            option: const DanmakuOption(massiveMode: true),
            size: const Size(800, 400),
            frameRate: 30,
            monotonicUs: () => now,
            createdInteraction: (get, _) => interaction = get,
          ),
        ),
      ),
    );
    messages.add(
      const LiveDanmakuMessage(
        identity: 'tracked',
        receivedAtUs: 0,
        text: 'tracked',
      ),
    );
    await tester.pump();
    final moves = <int>[];
    double? previous;
    for (var slot = 1; slot <= 120; slot++) {
      final next = (slot * 1000000 / 120).round();
      await tester.binding.delayed(Duration(microseconds: next - now));
      now = next;
      messages.add(
        LiveDanmakuMessage(
          identity: slot,
          receivedAtUs: now,
          text: 'new $slot',
        ),
      );
      tester.binding.scheduleFrame();
      await tester.pump();
      final x = interaction().snapshot
          .firstWhere((item) => item.text == 'tracked')
          .bounds
          .left;
      if (previous != null && x != previous) moves.add(now);
      previous = x;
    }
    expect(moves.length, inInclusiveRange(29, 31));
    for (var i = 1; i < moves.length; i++) {
      expect(moves[i] - moves[i - 1], inInclusiveRange(33332, 33334));
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await messages.close();
  });

  testWidgets('message burst shares one bounded admission pass per frame', (
    tester,
  ) async {
    final messages = StreamController<LiveDanmakuMessage<void>>.broadcast(
      sync: true,
    );
    late DanmakuInteractionHandle<void> Function() interaction;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: const MediaQueryData(),
          child: LiveDanmakuLayer<void>(
            messages: messages.stream,
            running: true,
            visible: true,
            option: const DanmakuOption(massiveMode: true),
            size: const Size(800, 400),
            monotonicUs: () => 0,
            createdInteraction: (get, _) => interaction = get,
          ),
        ),
      ),
    );
    await tester.pump();
    for (var i = 0; i < 50; i++) {
      messages.add(
        LiveDanmakuMessage(identity: i, receivedAtUs: 0, text: 'item$i'),
      );
    }
    await tester.pump();
    expect(interaction().snapshot.length, 24);
    await tester.pump(const Duration(milliseconds: 20));
    expect(interaction().snapshot.length, 48);
    await tester.pumpWidget(const SizedBox.shrink());
    await messages.close();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'live motion, pause, expiry and hidden subscription use shared window',
    (tester) async {
      final messages = StreamController<LiveDanmakuMessage<void>>.broadcast(
        sync: true,
      );
      var now = 0;
      var running = true;
      var visible = true;
      late DanmakuInteractionHandle<void> Function() interaction;
      Widget build() => Directionality(
        textDirection: TextDirection.ltr,
        child: MediaQuery(
          data: const MediaQueryData(),
          child: LiveDanmakuLayer<void>(
            messages: messages.stream,
            running: running,
            visible: visible,
            option: const DanmakuOption(duration: 2),
            size: const Size(800, 400),
            monotonicUs: () => now,
            createdInteraction: (get, _) => interaction = get,
          ),
        ),
      );
      await tester.pumpWidget(build());
      await tester.pump();
      expect(messages.hasListener, isTrue);
      messages.add(
        const LiveDanmakuMessage(
          identity: 'one',
          receivedAtUs: 0,
          text: 'scroll',
        ),
      );
      await tester.pump();
      expect(interaction().snapshot, hasLength(1));
      final initialX = interaction().snapshot.single.bounds.left;
      now = 1000000;
      await tester.pump(const Duration(seconds: 1));
      final pausedX = interaction().snapshot.single.bounds.left;
      expect(pausedX, lessThan(initialX));
      running = false;
      await tester.pumpWidget(build());
      now = 4000000;
      await tester.pump(const Duration(seconds: 3));
      expect(interaction().snapshot, hasLength(1));
      expect(interaction().snapshot.single.bounds.left, pausedX);
      running = true;
      await tester.pumpWidget(build());
      now = 5000000;
      await tester.pump(const Duration(seconds: 1));
      expect(interaction().snapshot, isEmpty);
      expect(tester.binding.hasScheduledFrame, isFalse);
      visible = false;
      final previous = interaction();
      await tester.pumpWidget(build());
      await tester.pump();
      expect(messages.hasListener, isFalse);
      expect(previous.isValid, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
      await messages.close();
      expect(tester.takeException(), isNull);
    },
  );
}
