import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/services/danmaku/work_quota.dart';
import 'package:pili_aurora/services/diagnostics/diagnostics.dart';

void main() {
  test(
    'global quota diagnostics remain readable through cancelled work',
    () async {
      final quota = DanmakuWorkQuota.instance;
      final token = DanmakuWorkToken();
      final entered = Completer<void>();
      final finish = Completer<void>();
      final pending = quota.run(23, () async {
        entered.complete();
        await finish.future;
      }, token: token);
      await entered.future;
      token.cancel();
      Map<String, Object?> read() => Diagnostics.instance.readSources(
        prefix: 'danmaku.processWorkQuota',
      );
      expect(
        read()['danmaku.processWorkQuota'],
        containsPair('obsoleteRunningTasks', 1),
      );
      expect(
        read()['danmaku.processWorkQuota'],
        containsPair('obsoleteReservedBytes', 23),
      );
      final localQuota = DanmakuWorkQuota();
      expect(localQuota.snapshot['runningTasks'], 0);
      expect(read().keys, ['danmaku.processWorkQuota']);
      finish.complete();
      await pending;
      expect(
        read()['danmaku.processWorkQuota'],
        containsPair('obsoleteRunningTasks', 0),
      );
      expect(
        read()['danmaku.processWorkQuota'],
        containsPair('obsoleteReservedBytes', 0),
      );
    },
  );
  test('retained storage reduces child allowance and child expires with its parent', () async {
    final quota = DanmakuWorkQuota(maxBytes: 10);
    late DanmakuWorkLease child;
    await quota.runWithLease(10, (lease) {
      child = lease.retaining(4)..requireBytes(6);
      expect(() => child.requireBytes(7), throwsA(isA<DanmakuWorkTooLarge>()));
    });
    expect(() => child.requireBytes(0), throwsStateError);
    await expectLater(child.execute(() => 1), throwsStateError);
  });
  test(
    'waiting count and bytes reject excess work, cancellation returns capacity',
    () async {
      final quota = DanmakuWorkQuota(maxWaitingTasks: 1, maxWaitingBytes: 100);
      final done = Completer<void>();
      final first = quota.run(1, () => done.future);
      final token = DanmakuWorkToken();
      final waiting = quota.run(1, () => 1, waitingBytes: 80, token: token);
      expect(quota.snapshot['waitingTasks'], 1);
      expect(quota.snapshot['waitingBytes'], 80);
      await expectLater(
        quota.run(1, () => 2, waitingBytes: 1),
        throwsA(isA<DanmakuWorkBusy>()),
      );
      final cancelled = expectLater(
        waiting,
        throwsA(isA<DanmakuWorkCancelled>()),
      );
      token.cancel();
      await cancelled;
      expect(quota.snapshot['waitingBytes'], 0);
      await expectLater(
        quota.run(1, () => 3, waitingBytes: 101),
        throwsA(isA<DanmakuWorkBusy>()),
      );
      final available = quota.available.first;
      final next = quota.run(1, () => 4, waitingBytes: 100);
      done.complete();
      await first;
      await available;
      expect(await next, 4);
      expect(quota.snapshot.values, everyElement(0));
    },
  );

  test('lease spans child stages and expires after result transfer', () async {
    final quota = DanmakuWorkQuota();
    late DanmakuWorkLease saved;
    final entered = Completer<void>();
    final finish = Completer<void>();
    var nextStarted = false;
    final first = quota.runWithLease(1, (lease) {
      saved = lease;
      return lease.execute(() async {
        entered.complete();
        await finish.future;
        return 42;
      });
    });
    await entered.future;
    final next = quota.run(1, () => nextStarted = true);
    await Future<void>.delayed(Duration.zero);
    expect(nextStarted, isFalse);
    finish.complete();
    expect(await first, 42);
    await next;
    await expectLater(saved.execute(() => 0), throwsStateError);
  });

  test('cancelled waiting work never starts or blocks later work', () async {
    final quota = DanmakuWorkQuota(maxTasks: 1);
    final done = Completer<void>();
    final first = quota.run(1, () => done.future);
    final token = DanmakuWorkToken();
    var started = false;
    final waiting = quota.run(1, () => started = true, token: token);
    final cancelled = expectLater(
      waiting,
      throwsA(isA<DanmakuWorkCancelled>()),
    );
    token.cancel();
    await cancelled;
    expect(started, isFalse);
    final last = quota.run(1, () => 42);
    done.complete();
    await first;
    expect(await last, 42);
  });

  test('cancelling running work retains its permit until completion', () async {
    final quota = DanmakuWorkQuota(maxTasks: 1);
    final token = DanmakuWorkToken();
    final entered = Completer<void>();
    final done = Completer<void>();
    final first = quota.run(1, () async {
      entered.complete();
      await done.future;
    }, token: token);
    await entered.future;
    expect(quota.snapshot['obsoleteRunningTasks'], 0);
    expect(quota.snapshot['obsoleteReservedBytes'], 0);
    token.cancel();
    expect(quota.snapshot['obsoleteRunningTasks'], 1);
    expect(quota.snapshot['obsoleteReservedBytes'], 1);
    var started = false;
    final second = quota.run(1, () => started = true);
    await Future<void>.delayed(Duration.zero);
    expect(started, isFalse);
    done.complete();
    await first;
    await second;
    expect(started, isTrue);
    expect(quota.snapshot['obsoleteRunningTasks'], 0);
    expect(quota.snapshot['obsoleteReservedBytes'], 0);
  });

  test('cancellation between reservation and start releases permit', () async {
    final quota = DanmakuWorkQuota(maxTasks: 1);
    final token = DanmakuWorkToken();
    final first = quota.run(
      1,
      () => fail('obsolete work started'),
      token: token,
    );
    final cancelled = expectLater(first, throwsA(isA<DanmakuWorkCancelled>()));
    token.cancel();
    await cancelled;
    expect(await quota.run(1, () => 42), 42);
  });

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

  test(
    'oversized work is rejected before retaining a waiting ticket',
    () async {
      final quota = DanmakuWorkQuota(maxBytes: 10);
      await expectLater(
        quota.run(11, () => fail('oversized work started')),
        throwsA(isA<DanmakuWorkTooLarge>()),
      );
      expect(quota.snapshot.values, everyElement(0));
      expect(await quota.run(10, () => 42), 42);
    },
  );

  test('byte limit applies to combined concurrent tasks', () async {
    final quota = DanmakuWorkQuota(maxTasks: 2, maxBytes: 10);
    final entered = Completer<void>();
    final finish = Completer<void>();
    final first = quota.run(6, () async {
      entered.complete();
      await finish.future;
    });
    await entered.future;
    var secondStarted = false;
    final second = quota.run(5, () => secondStarted = true);
    expect(quota.snapshot['reservedBytes'], 6);
    expect(quota.snapshot['waitingTasks'], 1);
    await Future<void>.delayed(Duration.zero);
    expect(secondStarted, isFalse);
    finish.complete();
    await Future.wait([first, second]);
    expect(secondStarted, isTrue);
  });

  test('child stage validates its reservation before allocating', () async {
    final quota = DanmakuWorkQuota(maxBytes: 10);
    await quota.runWithLease(6, (lease) {
      expect(lease.reservedBytes, 6);
      lease.requireBytes(6);
      expect(() => lease.requireBytes(7), throwsA(isA<DanmakuWorkTooLarge>()));
      expect(() => lease.requireBytes(-1), throwsArgumentError);
    });
    expect(quota.snapshot.values, everyElement(0));
  });
}
