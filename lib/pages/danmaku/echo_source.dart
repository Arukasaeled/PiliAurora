import 'dart:async';
import 'dart:math' as math;

import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:fixnum/fixnum.dart';
import 'package:pili_aurora/grpc/bilibili/community/service/dm/v1.pb.dart';
import 'package:pili_aurora/pages/danmaku/danmaku_model.dart';
import 'package:pili_aurora/pages/danmaku/timeline_range.dart';

/// 本地发送与随后到达的服务端条目使用同一份来源身份。
class DanmakuEchoSource implements DanmakuTimelineSource {
  DanmakuEchoSource(this.source) {
    _sourceRuleRevision = source.readRange(0, 0).ruleRevision;
    _ruleRevision = _sourceRuleRevision;
    _subscription = source.changes.listen(_sourceChanged);
  }

  final DanmakuTimelineSource source;
  final _echoes =
      <
        int,
        ({
          DanmakuElem element,
          DanmakuContentItem<DanmakuExtra> content,
          int mediaUs,
        })
      >{};
  final _removed = <int>{};
  final _changes = StreamController<DanmakuSourceChange>.broadcast(sync: true);
  late final StreamSubscription<DanmakuSourceChange> _subscription;
  int _revision = 0;
  int _ruleRevision = 0;
  int _sourceRuleRevision = 0;
  final _positions = <int, int>{};

  void _sourceChanged(DanmakuSourceChange change) {
    if (change.ruleRevision < _sourceRuleRevision) return;
    _sourceRuleRevision = change.ruleRevision;
    _revision++;
    if (change.kind == DanmakuSourceChangeKind.invalidated) _ruleRevision++;
    _changes.add(
      DanmakuSourceChange(
        kind: change.kind,
        ruleRevision: _ruleRevision,
        startUs: change.startUs,
        endUs: change.endUs,
      ),
    );
  }

  int _nextLocalId = -1;

  @override
  Stream<DanmakuSourceChange> get changes => _changes.stream;

  void add(DanmakuContentItem<DanmakuExtra> content, int mediaUs) {
    final extra = content.extra;
    if (_echoes.values.any((echo) => identical(echo.content, content))) return;
    final id = extra is VideoDanmaku ? extra.id : _nextLocalId--;
    if (_echoes.containsKey(id)) return;
    final element = DanmakuElem(
      id: Int64(id),
      idStr: id.toString(),
      progress: mediaUs ~/ 1000,
      mode: switch (content.type) {
        DanmakuItemType.top => 5,
        DanmakuItemType.bottom => 4,
        _ => 1,
      },
      color: content.color.toARGB32() & 0xffffff,
      content: content.text,
      midHash: extra is VideoDanmaku ? extra.mid : '',
      weight: 11,
    )..isSelf = true;
    if (_echoes.length == 64) _echoes.remove(_echoes.keys.first);
    _echoes[id] = (element: element, content: content, mediaUs: mediaUs);
    _changed(mediaUs);
  }

  DanmakuContentItem<DanmakuExtra>? contentFor(DanmakuElem element) =>
      _echoes[element.id.toInt()]?.content;

  void remove(Object identity) {
    // 交互身份由编排器生成；快照的业务 id 由挂载处解析后传入。
    if (identity is! int) return;
    final echo = _echoes.remove(identity);
    final sourceUs = echo == null ? _positions[identity] : echo.mediaUs;
    if (_removed.length == 256) _removed.remove(_removed.first);
    _removed.add(identity);
    _revision++;
    _ruleRevision++;
    for (final kind in [
      DanmakuSourceChangeKind.invalidated,
      DanmakuSourceChangeKind.ready,
    ]) {
      _changes.add(
        DanmakuSourceChange(
          kind: kind,
          ruleRevision: _ruleRevision,
          startUs: sourceUs ?? 0,
          endUs: sourceUs == null ? null : sourceUs + 1000,
        ),
      );
    }
  }

  void _changed(int sourceUs) {
    _revision++;
    _changes.add(
      DanmakuSourceChange(
        kind: DanmakuSourceChangeKind.ready,
        ruleRevision: _ruleRevision,
        startUs: sourceUs,
        endUs: sourceUs + 1000,
      ),
    );
  }

  @override
  DanmakuTimelineRange readRange(
    int startUs,
    int endUs, {
    int? maxEntriesPerBucket,
  }) {
    final range = source.readRange(
      startUs,
      endUs,
      maxEntriesPerBucket: maxEntriesPerBucket,
    );
    for (final entry in range.entries) {
      final id = entry.element.id.toInt();
      _positions.remove(id);
      if (_positions.length == 2048) _positions.remove(_positions.keys.first);
      _positions[id] = entry.positionUs;
    }
    final entries = <DanmakuTimelineEntry>[
      for (final entry in range.entries)
        if (!_removed.contains(entry.element.id.toInt()) &&
            !_echoes.containsKey(entry.element.id.toInt()) &&
            !range.coverage.any(
              (part) =>
                  part.state == DanmakuCoverageState.invalidated &&
                  entry.positionUs >= part.startUs &&
                  entry.positionUs < part.endUs,
            ))
          entry,
      for (final echo in _echoes.values)
        if (echo.mediaUs >= startUs && echo.mediaUs < endUs)
          DanmakuTimelineEntry(echo.element, localPositionUs: echo.mediaUs),
    ];
    final ordered = entries.indexed.toList()
      ..sort((a, b) {
        final time = a.$2.positionUs.compareTo(b.$2.positionUs);
        return time == 0 ? a.$1.compareTo(b.$1) : time;
      });
    final echoTimes =
        _echoes.values.map((echo) => echo.mediaUs).toSet().toList()..sort();
    final coverage = <DanmakuRangeCoverage>[];
    for (final part in range.coverage) {
      var cursor = part.startUs;
      for (final time in echoTimes) {
        if (time + 1000 <= cursor || time >= part.endUs) continue;
        if (cursor < time) {
          coverage.add(DanmakuRangeCoverage(cursor, time, part.state));
        }
        final end = math.min(part.endUs, time + 1000);
        coverage.add(
          DanmakuRangeCoverage(
            math.max(cursor, time),
            end,
            DanmakuCoverageState.loaded,
          ),
        );
        cursor = end;
      }
      if (cursor < part.endUs) {
        coverage.add(DanmakuRangeCoverage(cursor, part.endUs, part.state));
      }
    }
    return DanmakuTimelineRange(
      startUs: startUs,
      endUs: endUs,
      revision: range.revision + _revision,
      ruleRevision: _ruleRevision,
      entries: ordered.map((item) => item.$2),
      coverage: coverage,
    );
  }

  @override
  Future<void> ensureRange(int startUs, int endUs) =>
      source.ensureRange(startUs, endUs);

  void dispose() {
    unawaited(_subscription.cancel());
    _echoes.clear();
    _removed.clear();
    _positions.clear();
    unawaited(_changes.close());
  }
}
