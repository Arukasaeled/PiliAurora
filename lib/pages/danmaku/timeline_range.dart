import 'package:pili_aurora/grpc/bilibili/community/service/dm/v1.pb.dart';

/// 来源接入处将服务端毫秒转换为媒体微秒。
class DanmakuTimelineEntry {
  const DanmakuTimelineEntry(this.element);

  final DanmakuElem element;
  int get positionUs => element.progress * Duration.microsecondsPerMillisecond;
}

enum DanmakuCoverageState { loaded, missing }

class DanmakuRangeCoverage {
  const DanmakuRangeCoverage(this.startUs, this.endUs, this.state);

  final int startUs;
  final int endUs;
  final DanmakuCoverageState state;
}

/// 半开范围 [startUs, endUs) 的来源快照；读取不改变缓存淘汰顺序。
class DanmakuTimelineRange {
  DanmakuTimelineRange({
    required this.startUs,
    required this.endUs,
    required this.revision,
    required Iterable<DanmakuTimelineEntry> entries,
    required Iterable<DanmakuRangeCoverage> coverage,
  }) : entries = List.unmodifiable(entries),
       coverage = List.unmodifiable(coverage);

  final int startUs;
  final int endUs;
  final int revision;
  final List<DanmakuTimelineEntry> entries;
  final List<DanmakuRangeCoverage> coverage;

  bool get isLoaded => coverage.every(
    (range) => range.state == DanmakuCoverageState.loaded,
  );
}
