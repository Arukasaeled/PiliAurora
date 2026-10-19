import 'package:pili_aurora/grpc/bilibili/community/service/dm/v1.pb.dart';
import 'package:pili_aurora/pages/danmaku/cache.dart';
import 'package:pili_aurora/pages/danmaku/timeline_range.dart';
import 'package:flutter_test/flutter_test.dart';

DanmakuElem _element(int progress, int id) => DanmakuElem(
  progress: progress,
  content: '弹幕$id',
);

void main() {
  test('微秒范围按时间和原始次序排序，遵守半开边界', () {
    final first = _element(101, 1);
    final second = _element(101, 2);
    final cache = DanmakuCache()
      ..addSegmentBuckets(0, {
        1: [_element(199, 3), first, _element(100, 0), second],
        2: [_element(200, 4)],
      });
    final range = cache.readRange(100001, 200000);
    expect(range.entries.map((entry) => entry.positionUs), [
      101000,
      101000,
      199000,
    ]);
    expect(range.entries.take(2).map((entry) => entry.element), [
      first,
      second,
    ]);
    expect(range.isLoaded, isTrue);
    expect(range.entries.clear, throwsUnsupportedError);
    expect(cache.readRange(200000, 200000).entries, isEmpty);
  });

  test('覆盖区分已加载空段与缺失段，修订随写入和淘汰变化', () {
    final cache = DanmakuCache(maxSegments: 1);
    final missing = cache.readRange(359999999, 360000001);
    expect(missing.isLoaded, isFalse);
    cache.addSegmentBuckets(0, {});
    final partial = cache.readRange(359999999, 360000001);
    expect(partial.entries, isEmpty);
    expect(partial.coverage.map((range) => range.state), [
      DanmakuCoverageState.loaded,
      DanmakuCoverageState.missing,
    ]);
    expect(partial.coverage.first.endUs, 360000000);
    expect(partial.revision, greaterThan(missing.revision));
    cache.addSegmentBuckets(1, {});
    final evicted = cache.readRange(0, 720000000);
    expect(evicted.coverage.map((range) => range.state), [
      DanmakuCoverageState.missing,
      DanmakuCoverageState.loaded,
    ]);
    expect(evicted.revision, greaterThan(partial.revision));
    expect(partial.coverage.first.state, DanmakuCoverageState.loaded);
    cache.clear();
    expect(cache.readRange(360000000, 360000001).isLoaded, isFalse);
  });

  test('完整本地文件的空白范围已覆盖，clear 撤销覆盖', () {
    final cache = DanmakuCache()..addFileElements([]);
    expect(cache.readRange(0, 900000000).isLoaded, isTrue);
    cache.clear();
    expect(cache.readRange(0, 1).isLoaded, isFalse);
    expect(() => cache.readRange(-1, 1), throwsArgumentError);
    expect(() => cache.readRange(2, 1), throwsArgumentError);
  });

  test(
    'lookahead respects bounds and limit without changing eviction order',
    () {
      final cache = DanmakuCache(maxSegments: 2)
        ..addSegmentBuckets(0, {
          0: [_element(0, 0)],
          1: [_element(100, 1), _element(150, 2)],
          2: [_element(200, 3)],
        })
        ..addSegmentBuckets(1, {
          3600: [_element(360000, 4)],
        });
      expect(cache.peekRange(100, 200).map((element) => element.progress), [
        100,
        150,
      ]);
      expect(
        cache.peekRange(100, 201, limit: 1).map((element) => element.progress),
        [100],
      );
      expect(cache.peekRange(0, 100, limit: 0), isEmpty);
      cache.addSegmentBuckets(2, {});
      expect(cache.containsSegment(0), isFalse);
      expect(cache.containsSegment(1), isTrue);
    },
  );
  test('high density segment remains cached without repeated reload', () {
    final cache = DanmakuCache(
      maxBuckets: 10,
      maxElements: 12,
      maxElementsPerBucket: 3,
    );
    // ignore: cascade_invocations
    cache
      ..addSegmentBuckets(0, {
        0: List.generate(100, (i) => _element(0, i)),
        1: [_element(100, 101)],
      })
      ..addSegmentBuckets(0, {
        0: [_element(0, 999)],
      });

    expect(cache.containsSegment(0), isTrue);
    expect(cache.elementCount, 4);
    expect(cache.getAt(0), hasLength(3));
    expect(cache.getAt(100), hasLength(1));
    expect(cache.getAt(0), hasLength(3));
  });

  test('eviction removes a complete old segment', () {
    final cache = DanmakuCache(
      maxBuckets: 2,
      maxElements: 3,
      maxElementsPerBucket: 3,
    );
    // ignore: cascade_invocations
    cache
      ..addSegmentBuckets(0, {
        0: [_element(0, 0)],
        1: [_element(100, 1)],
      })
      ..addSegmentBuckets(1, {
        3600: [_element(360000, 2)],
        3601: [_element(360100, 3)],
      });

    expect(cache.containsSegment(0), isFalse);
    expect(cache.containsSegment(1), isTrue);
    expect(cache.bucketCount, 2);
    expect(cache.elementCount, 2);
    expect(cache.getAt(0), isNull);
    expect(cache.getAt(360000), hasLength(1));
  });

  test('empty segment is marked loaded until eviction', () {
    final cache = DanmakuCache(
      maxBuckets: 1,
      maxElements: 1,
      maxSegments: 1,
    );
    // ignore: cascade_invocations
    cache.addSegmentBuckets(0, {});
    expect(cache.containsSegment(0), isTrue);
    cache
      ..addSegmentBuckets(1, {
        3600: [_element(360000, 1)],
      })
      ..addSegmentBuckets(2, {
        7200: [_element(720000, 2)],
      });

    expect(cache.containsSegment(0), isFalse);
    expect(cache.containsSegment(1), isFalse);
    expect(cache.containsSegment(2), isTrue);
  });

  test('local file elements are retained without network limits', () {
    final cache = DanmakuCache(
      maxBuckets: 1,
      maxElements: 1,
      maxElementsPerBucket: 1,
    );
    // ignore: cascade_invocations
    cache.addFileElements([
      _element(0, 0),
      _element(0, 1),
      _element(360000, 2),
    ]);

    expect(cache.getAt(0), hasLength(2));
    expect(cache.getAt(360000), hasLength(1));
    expect(cache.elementCount, 3);
  });
}
