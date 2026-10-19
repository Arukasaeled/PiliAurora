import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/grpc/bilibili/community/service/dm/v1.pb.dart';
import 'package:pili_aurora/pages/danmaku/raw_cache.dart';
import 'package:pili_aurora/pages/danmaku/element_size.dart';

void main() {
  test(
    'complete segments obey byte and count budgets without read promotion',
    () {
      final cache = DanmakuRawCache(maxSegments: 2, maxBytes: 1300);
      final input = [DanmakuElem(content: 'a')];
      cache
        ..retain(0, input)
        ..retain(1, input);
      expect(cache[0], same(input));
      cache.retain(2, input);
      expect(cache.keys, [1, 2]);
      expect(cache.estimatedBytes, lessThanOrEqualTo(1300));
      cache.clear();
      expect(cache.length, 0);
      expect(cache.estimatedBytes, 0);
    },
  );

  test(
    'replacement releases old accounting; oversized segment is not retained',
    () {
      final cache = DanmakuRawCache(maxBytes: 1300);
      final input = [DanmakuElem(content: 'a')];
      cache
        ..retain(0, input)
        ..retain(1, input)
        ..retain(0, input);
      expect(cache.keys, [1, 0]);
      expect(cache.retain(0, [DanmakuElem(extra: 'x' * 1000)]), isFalse);
      expect(cache.keys, [1]);
      expect(
        cache.estimatedBytes,
        64 + 8 + estimateDanmakuElementBytes(input.single),
      );
    },
  );

  test('byte pressure evicts a full segment before count limit', () {
    final cache = DanmakuRawCache(maxBytes: 700)
      ..retain(0, [DanmakuElem(content: 'a')])
      ..retain(1, [DanmakuElem(content: 'b')]);
    expect(cache.keys, [1]);
    expect(DanmakuRawCache(maxBytes: 1).retain(0, []), isFalse);
  });

  test('all text metadata contributes to the estimate', () {
    final base = estimateDanmakuElementBytes(DanmakuElem());
    final withMetadata = DanmakuElem(
      content: 'a',
      midHash: 'b',
      action: 'c',
      idStr: 'd',
      animation: 'e',
      extra: 'f',
    );
    expect(estimateDanmakuElementBytes(withMetadata), base + 12);
  });
}
