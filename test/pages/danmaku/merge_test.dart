import 'dart:async';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/grpc/bilibili/community/service/dm/v1.pb.dart';
import 'package:pili_aurora/pages/danmaku/merge.dart';

DanmakuElem _dm(
  String text,
  int time, {
  int mode = 1,
  bool self = false,
  int pool = 0,
}) => DanmakuElem(
  content: text,
  progress: time,
  mode: mode,
  isSelf: self,
  pool: pool,
);

void main() {
  test('ordered batches preserve anchors and update earlier counts', () {
    final cursor = DanmakuMergeCursor();
    final first = cursor.appendOrdered([
      _dm('相同内容', 0),
      _dm('固定项', 1, mode: 5),
    ]);
    final second = cursor.appendOrdered([
      _dm('相同内容', 20000),
      _dm('相同内容', 20001),
      _dm('相同内容', 20001, self: true),
    ]);
    expect(first.map((e) => e.count), [2, 1]);
    expect(second.map((e) => e.progress), [20001, 20001]);
    expect(second.map((e) => e.count), [1, 1]);
  });

  test('batch partition does not alter dense matching or result order', () {
    final input = List.generate(
      5000,
      (i) => _dm(
        i % 3 == 0 ? '重复的长弹幕内容' : '独立条目编号$i',
        i * 11,
        mode: i % 31 == 0 ? 7 : 1,
        self: i % 43 == 0,
        pool: i % 7 == 0 ? 3 : 0,
      ),
    );
    List<List<int>> run(int batchSize) {
      final cursor = DanmakuMergeCursor();
      final result = <DanmakuElem>[];
      for (var start = 0; start < input.length; start += batchSize) {
        result.addAll(
          cursor.appendOrdered([
            for (var i = start; i < min(start + batchSize, input.length); i++)
              DanmakuElem.fromBuffer(input[i].writeToBuffer()),
          ]),
        );
      }
      return result.map((e) => e.writeToBuffer()).toList();
    }

    final expected = run(input.length);
    for (final size in [1, 7, 256, 1024]) {
      expect(run(size), expected, reason: 'batchSize=$size');
    }
  });

  test('unordered append fails before modifying existing merge state', () {
    final cursor = DanmakuMergeCursor();
    final first = cursor.appendOrdered([_dm('重复', 100)]).single;
    expect(
      () => cursor.appendOrdered([_dm('重复', 101), _dm('重复', 99)]),
      throwsArgumentError,
    );
    expect(first.count, 1);
    cursor.appendOrdered([_dm('重复', 101)]);
    expect(first.count, 2);
  });

  test(
    'merges repeated rating pool text while preserving different scores',
    () {
      final result = DanmakuMerger().merge([
        _dm('5', 26600, pool: 3),
        _dm('5', 27082, pool: 3),
        _dm('1', 42600, pool: 3),
        _dm('5', 42600, pool: 3),
        _dm('1', 42796, pool: 3),
      ]);
      expect(result.map((e) => e.content), ['5', '1']);
      expect(result.map((e) => e.count), [3, 2]);
      expect(result.every((e) => e.pool == 3), isTrue);
    },
  );

  test('rating pool shares ordinary matching and the anchored time window', () {
    final result = DanmakuMerger().merge([
      _dm('5', 0, pool: 3),
      _dm('５！', 1000),
      _dm('5', 20000, pool: 3),
      _dm('5', 20001, pool: 3),
      _dm('5', 20002, pool: 3, self: true),
      _dm('5', 20003, pool: 3, mode: 5),
      _dm('5', 20004, pool: 3, mode: 7),
    ]);
    expect(result.map((e) => e.progress), [0, 20001, 20002, 20003, 20004]);
    expect(result.map((e) => e.count), [3, 1, 1, 1, 1]);
  });

  test(
    'background merge preserves metadata and leaves input untouched',
    () async {
      final elements = [
        _dm('同样的内容', 20)..idStr = 'original',
        _dm('同样的内容', 30),
        _dm('同样的内容', 40, self: true),
        _dm('同样的内容', 10, mode: 5),
      ];
      final originalCounts = elements.map((e) => e.count).toList();
      var eventLoopRan = false;
      final timer = Timer(Duration.zero, () => eventLoopRan = true);
      final result = await mergeDanmakuInBackground(elements);
      // 后台完成前主 isolate 可以处理事件；结果携带完整弹幕元数据。
      expect(eventLoopRan, isTrue);
      timer.cancel();
      expect(result.map((e) => e.progress), [10, 20, 40]);
      expect(result.map((e) => e.count), [1, 2, 1]);
      expect(result[1].idStr, 'original');
      expect(result.last.isSelf, isTrue);
      expect(elements.map((e) => e.count), originalCounts);
    },
  );

  test(
    'bounded matcher agrees with full edit distance across shared affixes',
    () {
      final random = Random(42);
      const alphabet = ['a', 'b', 'c', 'd', 'e', 'f', '好', '看', '😀'];
      for (var i = 0; i < 1000; i++) {
        final length = [7, 8, 15, 16, 40, 198, 200, 202][i % 8];
        final first = List.generate(
          length,
          (_) => alphabet[random.nextInt(alphabet.length)],
        );
        final second = first.toList();
        for (var edit = 0; edit < i % 5; edit++) {
          final index = random.nextInt(second.length);
          switch (random.nextInt(3)) {
            case 0:
              second[index] = alphabet[random.nextInt(alphabet.length)];
            case 1:
              second.insert(index, alphabet[random.nextInt(alphabet.length)]);
            case 2:
              second.removeAt(index);
          }
        }
        final text = first.join();
        final other = second.join();
        final normalized = DanmakuMerger.normalize(text).runes.toList();
        final normalizedOther = DanmakuMerger.normalize(other).runes.toList();
        final fuzzy =
            normalizedOther.length >= 8 && normalizedOther.length <= 200;
        final matches =
            normalized.join(',') == normalizedOther.join(',') ||
            (fuzzy &&
                _editDistance(normalized, normalizedOther) <=
                    min(2, normalizedOther.length ~/ 8));
        final result = DanmakuMerger().merge([_dm(text, 0), _dm(other, 1)]);
        expect(
          result.length,
          matches ? 1 : 2,
          reason: 'case $i: $text / $other',
        );
      }
    },
  );

  test('repeated digits retain their numeric meaning', () {
    final result = DanmakuMerger().merge([
      _dm('现在已经有1000个人了', 0),
      _dm('现在已经有100个人了', 10),
      _dm('111', 20),
      _dm('11', 30),
    ]);
    expect(result, hasLength(4));
  });

  test(
    'dense windows evict matching state without dropping original messages',
    () {
      final elements = List.generate(2050, (i) => _dm('弹幕$i', i))
        ..addAll([_dm('弹幕0', 2051), _dm('弹幕0', 2052)]);
      final result = DanmakuMerger().merge(elements);
      expect(result, hasLength(2051));
      expect(result.first.count, 1);
      expect(result.last.count, 2);
    },
  );

  test('sorts input and anchors each 20 second window to its first item', () {
    final result = DanmakuMerger().merge([
      _dm('精彩', 20001),
      _dm('精彩', 10000),
      _dm('精彩', 0),
      _dm('精彩', 20000),
    ]);
    expect(result.map((e) => e.progress), [0, 20001]);
    expect(result.map((e) => e.count), [3, 1]);
  });

  test('normalizes punctuation, full width, case and repeated cheers', () {
    final result = DanmakuMerger().merge([
      _dm('ＡＢＣ，好耶！！', 0),
      _dm('abc 好耶', 10),
      _dm('哈哈哈哈哈', 20),
      _dm('哈哈', 30),
    ]);
    expect(result.map((e) => e.count), [2, 2]);
    expect(result.first.content, 'ＡＢＣ，好耶！！');
  });

  test(
    'merges a small typo in long text, preserves short and opposite messages',
    () {
      final result = DanmakuMerger().merge([
        _dm('这一段动画真的太精彩了', 0),
        _dm('这一段动画真得太精彩了', 10),
        _dm('好看', 20),
        _dm('不好看', 30),
        _dm('这个角色真的很好看', 40),
        _dm('这个角色真的不好看', 50),
        _dm('现在已经有100个人了', 60),
        _dm('现在已经有101个人了', 70),
      ]);
      expect(result, hasLength(7));
      expect(result.first.count, 2);
    },
  );

  test(
    'keeps own, advanced, subtitle and different mode elements independent',
    () {
      final elements = [
        _dm('同样的内容', 0),
        _dm('同样的内容', 1, mode: 5),
        _dm('同样的内容', 2, self: true),
        _dm('同样的内容', 3, mode: 7),
        _dm('同样的内容', 4, pool: 1),
        _dm('同样的内容', 5, pool: 1),
        _dm('同样的内容', 6, pool: 2),
        _dm('同样的内容', 7, pool: 2),
        _dm('同样的内容', 8, pool: 4),
        _dm('同样的内容', 9, pool: 4),
      ];
      expect(DanmakuMerger().merge(elements), hasLength(10));
      expect(elements.every((e) => e.count == 1), isTrue);
    },
  );

  test('reprocessing elements resets old merge counts', () {
    final elements = [_dm('重复', 0), _dm('重复', 10)];
    final merger = DanmakuMerger();
    expect(merger.merge(elements).single.count, 2);
    expect(merger.merge(elements).single.count, 2);
  });

  test('font growth respects switch, threshold, speed and bounds', () {
    double scale(
      int count, {
      bool enabled = true,
      int threshold = 7,
      double base = 7,
    }) => mergedDanmakuFontScale(
      count,
      enabled: enabled,
      threshold: threshold,
      logBase: base,
    );
    expect(scale(7), 1);
    expect(scale(8), greaterThan(1));
    expect(scale(49), closeTo(2, 0.0001));
    expect(scale(100000), 2);
    expect(scale(100, enabled: false), 1);
    expect(scale(4, threshold: 2, base: 7), 1);
    expect(scale(10, base: 3), greaterThan(scale(10)));
  });
}

int _editDistance(List<int> first, List<int> second) {
  var previous = List.generate(second.length + 1, (i) => i);
  for (var i = 0; i < first.length; i++) {
    final current = List<int>.filled(second.length + 1, 0)..[0] = i + 1;
    for (var j = 0; j < second.length; j++) {
      current[j + 1] = min(
        previous[j + 1] + 1,
        min(current[j] + 1, previous[j] + (first[i] == second[j] ? 0 : 1)),
      );
    }
    previous = current;
  }
  return previous.last;
}
