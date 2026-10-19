import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/services/danmaku/work_quota.dart';

void main() {
  test('decode and merge share bytes until actual completion', () async {
    final quota = DanmakuWorkQuota(maxBytes: 10);
    final firstDone = Completer<void>();
    final started = <int>[];
    final first = quota.run(6, () async {
      started.add(1);
      await firstDone.future;
    });
    final second = quota.run(6, () => started.add(2));
    await Future<void>.delayed(Duration.zero);
    expect(started, [1]);
    firstDone.complete();
    await Future.wait([first, second]);
    expect(started, [1, 2]);
  });

  test('task limit applies and failure releases permits', () async {
    final quota = DanmakuWorkQuota(maxTasks: 1);
    final done = Completer<void>();
    final first = quota.run(1, () async {
      await done.future;
      throw StateError('failed');
    });
    final failure = expectLater(first, throwsStateError);
    var started = false;
    final second = quota.run(1, () => started = true);
    await Future<void>.delayed(Duration.zero);
    expect(started, isFalse);
    done.complete();
    await failure;
    await second;
    expect(started, isTrue);
  });

  test('oversized work runs exclusively and preserves FIFO', () async {
    final quota = DanmakuWorkQuota(maxBytes: 10);
    final done = Completer<void>();
    final order = <int>[];
    final first = quota.run(20, () async {
      order.add(1);
      await done.future;
    });
    final second = quota.run(1, () => order.add(2));
    await Future<void>.delayed(Duration.zero);
    expect(order, [1]);
    done.complete();
    await Future.wait([first, second]);
    expect(order, [1, 2]);
  });
}
