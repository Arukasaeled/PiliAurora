import 'dart:async';
import 'dart:ui' as ui;

import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/pages/danmaku/live_queue.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('burst keeps latest candidates and original monotonic expiry', () {
    var now = 0;
    final accepted = <String>[];
    final queue = LiveDanmakuQueue<void>(
      nowUs: () => now,
      loadImage: (_) async => null,
      wake: () {},
      maxCandidates: 2,
      admit: (item) {
        accepted.add(item.text);
        return true;
      },
    );
    for (var i = 0; i < 4; i++) {
      queue.add(LiveDanmakuMessage(identity: i, receivedAtUs: 0, text: '$i'));
    }
    expect(queue.candidateCount, 2);
    now = 1000000;
    queue.process(running: true, fontSize: 20);
    expect(accepted, isEmpty);
    expect(queue.candidateCount, 0);
    queue.dispose();
  });
  test(
    'slow emote keeps task slot after fallback and never enters twice',
    () async {
      var now = 0;
      final pending = Completer<ui.Image?>();
      final accepted = <DanmakuContentItem<void>>[];
      final queue =
          LiveDanmakuQueue<void>(
              nowUs: () => now,
              loadImage: (_) => pending.future,
              wake: () {},
              admit: (item) {
                accepted.add(item);
                return true;
              },
            )
            ..add(
              const LiveDanmakuMessage(
                identity: 1,
                receivedAtUs: 0,
                text: '[x]',
                emotes: [LiveEmoteDescriptor('[x]', 'x', 12, 12)],
              ),
            )
            ..process(running: true, fontSize: 20);
      expect(queue.runningTasks, 1);
      now = 300001;
      queue.process(running: true, fontSize: 20);
      expect(accepted, hasLength(1));
      expect(queue.runningTasks, 1);
      expect(queue.reservedBytes, greaterThan(0));
      pending.complete(null);
      await Future<void>.delayed(Duration.zero);
      queue.process(running: true, fontSize: 20);
      expect(queue.runningTasks, 0);
      expect(queue.reservedBytes, 0);
      expect(accepted, hasLength(1));
      queue.dispose();
    },
  );
  test(
    'pause ages candidates while clear isolates in-flight resources',
    () async {
      var now = 0;
      final pending = Completer<ui.Image?>();
      var count = 0;
      final queue =
          LiveDanmakuQueue<void>(
            nowUs: () => now,
            loadImage: (_) => pending.future,
            wake: () {},
            admit: (_) {
              count++;
              return true;
            },
          )..add(
            const LiveDanmakuMessage(identity: 1, receivedAtUs: 0, text: 'one'),
          );
      now = 1000001;
      queue.process(running: false, fontSize: 20);
      expect(queue.candidateCount, 0);
      queue
        ..add(
          LiveDanmakuMessage(
            identity: 2,
            receivedAtUs: now,
            text: '[x]',
            emotes: const [LiveEmoteDescriptor('[x]', 'x', 12, 12)],
          ),
        )
        ..process(running: true, fontSize: 20)
        ..clear();
      expect(queue.runningTasks, 1);
      pending.complete(null);
      await Future<void>.delayed(Duration.zero);
      expect(queue.runningTasks, 0);
      expect(count, 0);
      queue.dispose();
    },
  );
}
