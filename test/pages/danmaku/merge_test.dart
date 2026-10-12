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
      final elements = List.generate(2050, (i) => _dm('弹幕$i', i));
      elements.addAll([_dm('弹幕0', 2051), _dm('弹幕0', 2052)]);
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
      ];
      expect(DanmakuMerger().merge(elements), hasLength(6));
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
