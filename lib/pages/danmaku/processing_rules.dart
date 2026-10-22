import 'package:pili_aurora/grpc/bilibili/community/service/dm/v1.pb.dart';
import 'package:pili_aurora/models/user/danmaku_rule.dart';
import 'package:pili_aurora/utils/danmaku_utils.dart';
import 'package:pili_aurora/pages/danmaku/element_size.dart';
import 'package:pili_aurora/services/danmaku/work_quota.dart';

/// worker 仅接收当前批次的规则快照，不持有页面或来源控制器。
class DanmakuProcessingRules {
  DanmakuProcessingRules({
    this.merge = true,
    this.fileSource = true,
    this.segmentIndex,
    this.selfHash,
    RuleFilter? filter,
  }) : _filter = _snapshot(filter, selfHash);

  static RuleFilter _snapshot(RuleFilter? filter, String? selfHash) {
    var bytes = 256 + 2 * (selfHash?.length ?? 0);
    void add(int size) {
      bytes += size;
      if (bytes > DanmakuProcessingBudget.rulesBytes) {
        throw DanmakuWorkTooLarge(bytes, DanmakuProcessingBudget.rulesBytes);
      }
    }

    add(0);
    for (final text in filter?.dmFilterString ?? const <String>[]) {
      add(64 + 2 * text.length);
    }
    for (final pattern in filter?.dmRegExp ?? const <RegExp>[]) {
      add(128 + 2 * pattern.pattern.length);
    }
    for (final text in filter?.dmUid ?? const <String>{}) {
      add(96 + 2 * text.length);
    }
    return RuleFilter(
      List.unmodifiable(filter?.dmFilterString ?? const <String>[]),
      List.unmodifiable(filter?.dmRegExp ?? const <RegExp>[]),
      Set.unmodifiable(filter?.dmUid ?? const <String>{}),
      filter?.count,
    );
  }

  final bool merge;
  final bool fileSource;
  final int? segmentIndex;
  final String? selfHash;
  final RuleFilter _filter;

  /// 字符串、正则描述及容器槽位；正则引擎的运行时堆由 VM 管理。
  int get storageBytes =>
      256 +
      2 * (selfHash?.length ?? 0) +
      _filter.dmFilterString.fold<int>(
        0,
        (sum, text) => sum + 64 + 2 * text.length,
      ) +
      _filter.dmRegExp.fold<int>(
        0,
        (sum, pattern) => sum + 128 + 2 * pattern.pattern.length,
      ) +
      _filter.dmUid.fold<int>(0, (sum, text) => sum + 96 + 2 * text.length);

  void requireBudget() {
    final bytes = storageBytes;
    if (bytes > DanmakuProcessingBudget.rulesBytes) {
      throw DanmakuWorkTooLarge(bytes, DanmakuProcessingBudget.rulesBytes);
    }
  }

  bool retain(DanmakuElem element) {
    if (!fileSource &&
        (segmentIndex == null ||
            DmUtils.calcSegment(element.progress) != segmentIndex)) {
      return false;
    }
    if (selfHash != null) element.isSelf = element.midHash == selfHash;
    return element.isSelf || _filter.count == 0 || !_filter.remove(element);
  }
}
