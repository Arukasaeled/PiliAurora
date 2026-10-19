import 'package:pili_aurora/grpc/bilibili/community/service/dm/v1.pb.dart';
import 'package:pili_aurora/models/user/danmaku_rule.dart';
import 'package:pili_aurora/utils/danmaku_utils.dart';

/// worker 仅接收当前批次的规则快照，不持有页面或来源控制器。
class DanmakuProcessingRules {
  DanmakuProcessingRules({
    this.merge = true,
    this.fileSource = true,
    this.segmentIndex,
    this.selfHash,
    RuleFilter? filter,
  }) : _filter = RuleFilter(
         List.unmodifiable(filter?.dmFilterString ?? const <String>[]),
         List.unmodifiable(filter?.dmRegExp ?? const <RegExp>[]),
         Set.unmodifiable(filter?.dmUid ?? const <String>{}),
         filter?.count,
       );

  final bool merge;
  final bool fileSource;
  final int? segmentIndex;
  final String? selfHash;
  final RuleFilter _filter;

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
