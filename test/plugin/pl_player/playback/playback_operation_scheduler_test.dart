import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/plugin/pl_player/utils/playback_load_queue.dart';

void main() {
  test('替换排队任务保留结果泛型、通知取消并让最新任务继续执行', () async {
    final clock = Stopwatch()..start();
    final scheduler = PlaybackOperationScheduler(now: () => clock.elapsed);
    final gate = Completer<int>();
    final events = <String>[];
    var pendingCancelled = 0;
    final deadline = clock.elapsed + const Duration(seconds: 5);
    addTearDown(() async {
      if (!gate.isCompleted) gate.complete(1);
      scheduler.dispose();
      await scheduler.drained;
    });

    final active = scheduler.submit<int>(
      slot: PlaybackOperationSlot.load,
      deadline: deadline,
      operation: (_) {
        events.add('active');
        return gate.future;
      },
    );
    final pending = scheduler.submit<String>(
      slot: PlaybackOperationSlot.load,
      deadline: deadline,
      cancel: () => pendingCancelled++,
      operation: (_) async {
        events.add('pending');
        return 'old';
      },
    );
    final latest = scheduler.submit<bool>(
      slot: PlaybackOperationSlot.load,
      deadline: deadline,
      operation: (_) async {
        events.add('latest');
        return true;
      },
    );

    expect((await active).outcome, PlaybackOperationOutcome.superseded);
    expect((await pending).outcome, PlaybackOperationOutcome.superseded);
    expect(pendingCancelled, 1);
    expect(events, ['active']);
    expect(scheduler.isRunning, isTrue);

    gate.complete(1);
    final result = await latest;
    expect(result.outcome, PlaybackOperationOutcome.completed);
    expect(result.value, isTrue);
    await scheduler.drained;
    expect(events, ['active', 'latest']);
    expect(scheduler.isRunning, isFalse);
  });
}
