import 'dart:collection';
import 'dart:math' as math;

import 'package:pili_aurora/grpc/bilibili/community/service/dm/v1.pb.dart';

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
    final result = <DanmakuElem>[];

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
      if (element.isSelf ||
          element.pool != 0 ||
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
      final text = normalize(element.content);
      final key = (element.mode, text);
      var match = exact[key];
      final runes = text.runes.toList();
      if (match == null && runes.length >= 8 && runes.length <= 200) {
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
            if (_meaning.allMatches(text).map((m) => m[0]).join() ==
                    _meaning
                        .allMatches(candidate.text)
                        .map((m) => m[0])
                        .join() &&
                _withinDistance(runes, candidate.runes, distance)) {
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
      final group = _MergeGroup(element, text, runes);
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

  static bool _withinDistance(List<int> first, List<int> second, int limit) {
    var previous = List<int>.generate(second.length + 1, (i) => i);
    for (var i = 1; i <= first.length; i++) {
      final current = List<int>.filled(second.length + 1, limit + 1);
      current[0] = i;
      var minimum = limit + 1;
      for (
        var j = math.max(1, i - limit);
        j <= math.min(second.length, i + limit);
        j++
      ) {
        current[j] = math.min(
          previous[j] + 1,
          math.min(
            current[j - 1] + 1,
            previous[j - 1] + (first[i - 1] == second[j - 1] ? 0 : 1),
          ),
        );
        minimum = math.min(minimum, current[j]);
      }
      if (minimum > limit) return false;
      previous = current;
    }
    return previous.last <= limit;
  }
}

class _MergeGroup {
  _MergeGroup(this.element, this.text, this.runes);
  final DanmakuElem element;
  final String text;
  final List<int> runes;
}

double mergedDanmakuFontScale(
  int count, {
  required bool enabled,
  required int threshold,
  required double logBase,
}) => !enabled || count <= threshold || count <= 1
    ? 1
    : (math.log(count) / math.log(logBase)).clamp(1.0, 2.0);
