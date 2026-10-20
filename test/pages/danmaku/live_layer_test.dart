import 'dart:async';

import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/pages/danmaku/interaction.dart';
import 'package:pili_aurora/pages/danmaku/live_layer.dart';
import 'package:pili_aurora/pages/danmaku/live_queue.dart';

void main() {
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
            option: const DanmakuOption(staticDuration: 2),
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
          text: 'top',
          type: DanmakuItemType.top,
        ),
      );
      await tester.pump();
      expect(interaction().snapshot, hasLength(1));
      now = 1000000;
      await tester.pump(const Duration(seconds: 1));
      running = false;
      await tester.pumpWidget(build());
      now = 4000000;
      await tester.pump(const Duration(seconds: 3));
      expect(interaction().snapshot, hasLength(1));
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
