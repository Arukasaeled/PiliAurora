import 'dart:collection';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:pili_aurora/grpc/bilibili/community/service/dm/v1.pb.dart';
import 'package:pili_aurora/services/danmaku/work_quota.dart';

/// 仅传递弹幕数据，分段合并和本地文件合并均在后台完成。
Future<List<DanmakuElem>> mergeDanmakuInBackground(
  List<DanmakuElem> elements,
) => DanmakuWorkQuota.instance.run(
  elements.fold<int>(
    0,
    (bytes, element) =>
        bytes + 256 + element.content.length * 8 + element.midHash.length * 2,
  ),
  () => Isolate.run(() => DanmakuMerger().merge(elements)),
);

/// 合并窗口以首条弹幕为锚点，避免连续刷屏把后续整段内容吞掉。
class DanmakuMerger {
  static const windowMilliseconds = 20000;
  static const _maxGroups = 2048;
  static final _punctuation = RegExp(
    r'[\s，。！？、；：,.!?;:~～…「」『』（）()【】\[\]"“”‘’]',
  );
  static final _repeated = RegExp(r'([^0-9])\1{2,}', unicode: true);
  static final _meaning = RegExp(r'[不没无别非未]|[0-9]+');

  List<DanmakuElem> merge(List<DanmakuElem> elements) {
    final ordered = elements.indexed.toList()
      ..sort((a, b) {
        final time = a.$2.progress.compareTo(b.$2.progress);
        return time == 0 ? a.$1.compareTo(b.$1) : time;
      });
    final groups = Queue<_MergeGroup>();
    final exact = <(int, String), _MergeGroup>{};
    final lengths = <(int, int), Queue<_MergeGroup>>{};
    final normalizedTexts = <String, String>{};
    final result = <DanmakuElem>[];
    final matcher = _DistanceMatcher();

    String normalizedText(String content) {
      final cached = normalizedTexts[content];
      if (cached != null) return cached;
      final text = normalize(content);
      // 重复原文复用归一化结果；缓存限界，分散文本不会持续增加匹配状态。
      if (normalizedTexts.length >= _maxGroups) {
        normalizedTexts.remove(normalizedTexts.keys.first);
      }
      normalizedTexts[content] = text;
      return text;
    }

    void evict() {
      final group = groups.removeFirst();
      final key = (group.element.mode, group.text);
      if (identical(exact[key], group)) exact.remove(key);
      final lengthKey = (group.element.mode, group.runes.length);
      final candidates = lengths[lengthKey]!..removeFirst();
      if (candidates.isEmpty) lengths.remove(lengthKey);
    }

    for (final (_, element) in ordered) {
      element.count = 1;
      // 互动池包含评分数字等普通文字弹幕，沿用普通池的合并规则。
      if (element.isSelf ||
          (element.pool != 0 && element.pool != 3) ||
          element.mode < 1 ||
          element.mode > 6) {
        result.add(element);
        continue;
      }
      while (groups.isNotEmpty &&
          element.progress - groups.first.element.progress >
              windowMilliseconds) {
        evict();
      }
      final text = normalizedText(element.content);
      final key = (element.mode, text);
      var match = exact[key];
      if (match != null) {
        match.element.count++;
        continue;
      }
      final runes = text.runes.toList();
      // 语义特征每条提取一次，不随候选数量重复执行正则匹配。
      final meaning = _meaning.allMatches(text).map((m) => m[0]).join();
      if (runes.length >= 8 && runes.length <= 200) {
        final distance = math.min(2, runes.length ~/ 8).clamp(1, 2);
        var checked = 0;
        search:
        for (
          var length = runes.length - distance;
          length <= runes.length + distance;
          length++
        ) {
          for (final candidate
              in lengths[(element.mode, length)] ?? const <_MergeGroup>[]) {
            if (++checked > 64) break search;
            // 数字与否定词保留语义，避免把不同时间、比分或相反观点合并。
            if (meaning == candidate.meaning &&
                matcher.withinDistance(runes, candidate.runes, distance)) {
              match = candidate;
              break search;
            }
          }
        }
      }
      if (match != null) {
        match.element.count++;
        continue;
      }
      final group = _MergeGroup(element, text, runes, meaning);
      if (groups.length >= _maxGroups) evict();
      groups.add(group);
      exact[key] = group;
      (lengths[(element.mode, runes.length)] ??= Queue()).add(group);
      result.add(element);
    }
    return result;
  }

  static String normalize(String text) {
    final halfWidth = String.fromCharCodes(
      text.runes.map(
        (rune) => rune >= 0xff01 && rune <= 0xff5e ? rune - 0xfee0 : rune,
      ),
    );
    final normalized = halfWidth
        .toLowerCase()
        .replaceAll(_punctuation, '')
        .replaceAllMapped(_repeated, (match) => '${match[1]}${match[1]}');
    return normalized.isEmpty ? text.trim() : normalized;
  }
}

class _DistanceMatcher {
  // 查询长度最多 200，候选可比查询长 2；另留一列存放边界哨兵。
  final _first = Uint16List(204);
  final _second = Uint16List(204);

  bool withinDistance(List<int> first, List<int> second, int limit) {
    var start = 0;
    var firstEnd = first.length;
    var secondEnd = second.length;
    // 去掉相同前后缀后再计算距离，长文本的少量差异无需扫描整段矩阵。
    while (start < firstEnd &&
        start < secondEnd &&
        first[start] == second[start]) {
      start++;
    }
    while (firstEnd > start &&
        secondEnd > start &&
        first[firstEnd - 1] == second[secondEnd - 1]) {
      firstEnd--;
      secondEnd--;
    }
    final firstLength = firstEnd - start;
    final secondLength = secondEnd - start;
    if ((firstLength - secondLength).abs() > limit) return false;
    if (firstLength == 0 || secondLength == 0) return true;

    var previous = _first;
    var current = _second;
    final infinity = limit + 1;
    final initialEnd = math.min(secondLength, limit);
    for (var j = 0; j <= initialEnd; j++) {
      previous[j] = j;
    }
    previous[initialEnd + 1] = infinity;
    for (var i = 1; i <= firstLength; i++) {
      current[0] = i;
      final lower = math.max(1, i - limit);
      final upper = math.min(secondLength, i + limit);
      if (lower > 1) current[lower - 1] = infinity;
      current[upper + 1] = infinity;
      var minimum = infinity;
      for (var j = lower; j <= upper; j++) {
        current[j] = math.min(
          previous[j] + 1,
          math.min(
            current[j - 1] + 1,
            previous[j - 1] +
                (first[start + i - 1] == second[start + j - 1] ? 0 : 1),
          ),
        );
        minimum = math.min(minimum, current[j]);
      }
      if (minimum > limit) return false;
      final swap = previous;
      previous = current;
      current = swap;
    }
    return previous[secondLength] <= limit;
  }
}

class _MergeGroup {
  _MergeGroup(this.element, this.text, this.runes, this.meaning);
  final DanmakuElem element;
  final String text;
  final List<int> runes;
  final String meaning;
}

double mergedDanmakuFontScale(
  int count, {
  required bool enabled,
  required int threshold,
  required double logBase,
}) => !enabled || count <= threshold || count <= 1
    ? 1
    : (math.log(count) / math.log(logBase)).clamp(1.0, 2.0);
