import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/plugin/pl_player/playback/media_clock.dart';
import 'package:pili_aurora/plugin/pl_player/playback/native_media_clock_sampling.dart';

void main() {
  PlaybackMediaAnchor anchor(
    int positionUs, {
    int observedAtUs = 1000,
    bool advancing = true,
  }) => PlaybackMediaAnchor(
    positionUs: positionUs,
    observedAtUs: observedAtUs,
    effectiveRate: 1,
    advancing: advancing,
    ready: true,
    continuity: 1,
    validForUs: 500000,
  );

  test('忙时只保留最新请求，旧在途结果不发布', () async {
    final sampling = NativeMediaClockSampling();
    final firstStarted = Completer<void>();
    final latestStarted = Completer<void>();
    final firstRead = Completer<PlaybackMediaAnchor?>();
    final latestRead = Completer<PlaybackMediaAnchor?>();
    final published = <PlaybackMediaAnchor>[];
    final latestPublished = Completer<void>();
    var skippedReadStarted = false;

    sampling.request(() {
      firstStarted.complete();
      return firstRead.future;
    }, published.add);
    await firstStarted.future;

    sampling
      ..request(() async {
        skippedReadStarted = true;
        return anchor(2);
      }, published.add)
      ..request(
        () {
          latestStarted.complete();
          return latestRead.future;
        },
        (value) {
          published.add(value);
          latestPublished.complete();
        },
      );

    await Future<void>.delayed(Duration.zero);
    expect(latestStarted.isCompleted, isFalse);
    firstRead.complete(anchor(1));
    await latestStarted.future;
    expect(skippedReadStarted, isFalse);
    expect(published, isEmpty);

    latestRead.complete(anchor(3));
    await latestPublished.future;
    expect(published.map((value) => value.positionUs), [3]);
    await sampling.close();
  });

  test('invalidate丢弃旧请求并保留已发布冻结锚点的采样时刻', () async {
    final sampling = NativeMediaClockSampling();
    final frozen = anchor(12345, observedAtUs: 6789, advancing: false);
    final frozenPublished = Completer<void>();
    final staleStarted = Completer<void>();
    final staleRead = Completer<PlaybackMediaAnchor?>();
    var pendingReadStarted = false;
    final published = <PlaybackMediaAnchor>[];

    sampling.request(() async => frozen, (value) {
      published.add(value);
      frozenPublished.complete();
    });
    await frozenPublished.future;
    expect(frozen.positionAt(9000000), 12345);

    sampling.request(() {
      staleStarted.complete();
      return staleRead.future;
    }, published.add);
    await staleStarted.future;
    sampling
      ..request(() async {
        pendingReadStarted = true;
        return anchor(99999);
      }, published.add)
      ..invalidate();
    staleRead.complete(anchor(54321, observedAtUs: 7000));
    await sampling.close();

    expect(pendingReadStarted, isFalse);
    expect(published, hasLength(1));
    expect(published.single, same(frozen));
    expect(published.single.observedAtUs, 6789);
    expect(published.single.positionAt(9000000), 12345);
  });

  test('close等待在途读取完成，且不发布或启动后续请求', () async {
    final sampling = NativeMediaClockSampling();
    final firstStarted = Completer<void>();
    final firstRead = Completer<PlaybackMediaAnchor?>();
    final published = <PlaybackMediaAnchor>[];
    var queuedReadStarted = false;
    var afterCloseReadStarted = false;
    var closeCompleted = false;

    sampling.request(() {
      firstStarted.complete();
      return firstRead.future;
    }, published.add);
    await firstStarted.future;
    sampling.request(() async {
      queuedReadStarted = true;
      return anchor(2);
    }, published.add);

    final closed = sampling.close().then((_) => closeCompleted = true);
    sampling.request(() async {
      afterCloseReadStarted = true;
      return anchor(3);
    }, published.add);
    await Future<void>.delayed(Duration.zero);
    expect(closeCompleted, isFalse);

    firstRead.complete(anchor(1));
    await closed;

    expect(queuedReadStarted, isFalse);
    expect(afterCloseReadStarted, isFalse);
    expect(published, isEmpty);
  });

  test('读取失败后仍能执行并发布后续请求', () async {
    final sampling = NativeMediaClockSampling();
    final failedStarted = Completer<void>();
    final failedRead = Completer<PlaybackMediaAnchor?>();
    final nextStarted = Completer<void>();
    final nextRead = Completer<PlaybackMediaAnchor?>();
    final published = <PlaybackMediaAnchor>[];
    final nextPublished = Completer<void>();

    sampling.request(() {
      failedStarted.complete();
      return failedRead.future;
    }, published.add);
    await failedStarted.future;
    sampling.request(
      () {
        nextStarted.complete();
        return nextRead.future;
      },
      (value) {
        published.add(value);
        nextPublished.complete();
      },
    );

    failedRead.completeError(StateError('sample failed'));
    await nextStarted.future;
    nextRead.complete(anchor(2));
    await nextPublished.future;

    expect(published.map((value) => value.positionUs), [2]);
    await sampling.close();
  });
}
