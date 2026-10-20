import 'dart:async';

import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:fixnum/fixnum.dart';
import 'package:pili_aurora/grpc/bilibili/community/service/dm/v1.pb.dart';
import 'package:pili_aurora/pages/danmaku/danmaku_model.dart';
import 'package:pili_aurora/pages/danmaku/timeline_range.dart';

/// 本地发送与随后到达的服务端条目使用同一份来源身份。
class DanmakuEchoSource implements DanmakuTimelineSource {
  DanmakuEchoSource(this.source) {
    _subscription = source.changes.listen(_changes.add);
  }

  final DanmakuTimelineSource source;
  final _echoes =
      <
        int,
        ({DanmakuElem element, DanmakuContentItem<DanmakuExtra> content})
      >{};
  final _removed = <int>{};
  final _changes = StreamController<DanmakuSourceChange>.broadcast(sync: true);
  late final StreamSubscription<DanmakuSourceChange> _subscription;
  int _revision = 0;
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
    _echoes[id] = (element: element, content: content);
    _changed(element.progress * 1000);
  }

  DanmakuContentItem<DanmakuExtra>? contentFor(DanmakuElem element) =>
      _echoes[element.id.toInt()]?.content;

  void remove(Object identity) {
    // 交互身份由编排器生成；快照的业务 id 由挂载处解析后传入。
    if (identity is! int) return;
    _echoes.remove(identity);
    if (_removed.length == 256) _removed.remove(_removed.first);
    _removed.add(identity);
    _revision++;
    _changes.add(
      DanmakuSourceChange(
        kind: DanmakuSourceChangeKind.invalidated,
        ruleRevision: _revision,
      ),
    );
  }

  void _changed(int sourceUs) {
    _revision++;
    _changes.add(
      DanmakuSourceChange(
        kind: DanmakuSourceChangeKind.ready,
        ruleRevision: _revision,
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
    final entries = <DanmakuTimelineEntry>[
      for (final entry in range.entries)
        if (!_removed.contains(entry.element.id.toInt()) &&
            !_echoes.containsKey(entry.element.id.toInt()))
          entry,
      for (final echo in _echoes.values)
        if (echo.element.progress * 1000 >= startUs &&
            echo.element.progress * 1000 < endUs)
          DanmakuTimelineEntry(echo.element),
    ];
    final ordered = entries.indexed.toList()
      ..sort((a, b) {
        final time = a.$2.positionUs.compareTo(b.$2.positionUs);
        return time == 0 ? a.$1.compareTo(b.$1) : time;
      });
    return DanmakuTimelineRange(
      startUs: startUs,
      endUs: endUs,
      revision: range.revision + _revision,
      ruleRevision: range.ruleRevision,
      entries: ordered.map((item) => item.$2),
      coverage: range.coverage,
    );
  }

  @override
  Future<void> ensureRange(int startUs, int endUs) =>
      source.ensureRange(startUs, endUs);

  void dispose() {
    unawaited(_subscription.cancel());
    _echoes.clear();
    _removed.clear();
    unawaited(_changes.close());
  }
}
