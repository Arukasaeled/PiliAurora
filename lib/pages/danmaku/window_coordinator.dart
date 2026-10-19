import 'dart:async';
import 'dart:math' as math;

import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:pili_aurora/grpc/bilibili/community/service/dm/v1.pb.dart';
import 'package:pili_aurora/pages/danmaku/timeline_range.dart';
import 'package:pili_aurora/pages/danmaku/window_renderer.dart';

/// 来源到普通窗口的有界准备；逐帧布局预算不改变固定时间桶内的内容选择。
class DanmakuWindowCoordinator<T> {
  DanmakuWindowCoordinator({
    required this.source,
    required this.renderer,
    required this.contentOf,
    this.preparePerFrame = 4,
    this.aheadUs = 2000000,
    this.refillUs = 500000,
    this.historyUs = 10000000,
  }) : assert(
         preparePerFrame > 0 &&
             preparePerFrame <= DanmakuDisplayLimits.maxPerBatch,
       ),
       assert(aheadUs > 0 && refillUs > 0 && refillUs <= aheadUs),
       assert(historyUs >= 0) {
    _subscription = source.changes.listen(_changed);
  }

  static const _bucketUs = 100000;
  final DanmakuTimelineSource source;
  final DanmakuWindowRenderer<T> renderer;
  final DanmakuContentItem<T>? Function(DanmakuElem) contentOf;
  final int preparePerFrame;
  final int aheadUs;
  final int refillUs;
  final int historyUs;
  final _updates = StreamController<void>.broadcast(sync: true);
  Stream<void> get updates => _updates.stream;
  late final StreamSubscription<DanmakuSourceChange> _subscription;
  int? _lastMediaUs;
  int _generation = -1;
  int _nextBucketUs = 0;
  int? _dirtyUs;
  List<DanmakuWindowContent<T>>? _pending;
  int _offset = 0;
  bool _requesting = false;
  bool _refilling = false;
  int _targetUntilUs = 0;
  int? _lastRequestUs;
  bool _disposed = false;
  bool requestFailed = false;

  void _changed(DanmakuSourceChange change) {
    if (_disposed) return;
    if (change.kind == DanmakuSourceChangeKind.invalidated) {
      renderer.reset(_lastMediaUs ?? 0);
    } else {
      final start = math.max(change.startUs, renderer.validFromUs);
      if (start < _nextBucketUs &&
          (change.endUs == null || change.endUs! > renderer.validFromUs)) {
        final bucket = start ~/ _bucketUs * _bucketUs;
        _dirtyUs = _dirtyUs == null ? bucket : math.min(_dirtyUs!, bucket);
      }
    }
    _pending = null;
    _updates.add(null);
  }

  Future<void> _request(int fromUs, int untilUs) async {
    _requesting = true;
    try {
      await source.ensureRange(fromUs, untilUs);
      requestFailed = false;
    } catch (_) {
      requestFailed = true;
    } finally {
      _requesting = false;
    }
  }

  void prepareFrame(DanmakuWindowRenderer<T> target, int mediaUs) {
    if (_disposed || !identical(target, renderer)) return;
    if (_lastMediaUs != null &&
        mediaUs - _lastMediaUs! > aheadUs &&
        (mediaUs < renderer.validFromUs || mediaUs >= renderer.validUntilUs)) {
      renderer.reset(mediaUs);
    }
    _lastMediaUs = mediaUs;
    if (_generation != renderer.generation) {
      _generation = renderer.generation;
      _nextBucketUs = renderer.validFromUs ~/ _bucketUs * _bucketUs;
      _pending = null;
      _dirtyUs = null;
      _refilling = false;
      _lastRequestUs = null;
    }
    final cutoff = math.min(
      renderer.validUntilUs,
      math.max(0, mediaUs - historyUs),
    );
    if (cutoff > renderer.validFromUs) renderer.trimBefore(cutoff);
    if (_dirtyUs != null) {
      _nextBucketUs = math.min(_nextBucketUs, _dirtyUs!);
      _dirtyUs = null;
      _pending = null;
      _refilling = true;
      _targetUntilUs = math.max(_targetUntilUs, mediaUs + aheadUs);
    }
    if (!_refilling) {
      if (_pending == null && _nextBucketUs - mediaUs >= refillUs) return;
      _refilling = true;
      _targetUntilUs = mediaUs + aheadUs;
    }
    if (!_requesting &&
        (_lastRequestUs == null ||
            (mediaUs - _lastRequestUs!).abs() >= _bucketUs)) {
      _lastRequestUs = mediaUs;
      unawaited(_request(mediaUs, _targetUntilUs));
    }
    final untilUs = _targetUntilUs;
    var remaining = preparePerFrame;
    var buckets = 0;
    while (remaining > 0 && _nextBucketUs < untilUs && buckets++ < 4) {
      final endUs = _nextBucketUs + _bucketUs;
      if (_pending == null) {
        final range = source.readRange(_nextBucketUs, endUs);
        if (!range.isLoaded) return;
        final occurrences = <Object, int>{};
        final eligible = range.entries
            .where((entry) => entry.positionUs >= renderer.validFromUs)
            .toList();
        final count = math.min(
          eligible.length,
          DanmakuDisplayLimits.maxPerBatch,
        );
        final candidates = <DanmakuWindowContent<T>>[];
        for (var index = 0; index < count; index++) {
          final entry = eligible[index * eligible.length ~/ count];
          final element = entry.element;
          final key = (
            element.idStr,
            element.id,
            element.progress,
            element.mode,
            element.midHash,
            element.content,
          );
          final ordinal = occurrences.update(
            key,
            (value) => value + 1,
            ifAbsent: () => 0,
          );
          final identity = (key, ordinal);
          if (renderer.hasPrepared(identity)) continue;
          final content = contentOf(element);
          if (content != null) {
            candidates.add(
              DanmakuWindowContent(identity, entry.positionUs, content),
            );
          }
        }
        _pending = candidates;
        _offset = 0;
      }
      final pending = _pending!;
      final end = math.min(_offset + remaining, pending.length);
      final complete = end == pending.length;
      final frontier = complete ? endUs : pending[end].sourceUs;
      if (!renderer.prepare(
        pending.sublist(_offset, end),
        generation: _generation,
        preparedUntilUs: math.max(renderer.validUntilUs, frontier),
      )) {
        return;
      }
      remaining -= end - _offset;
      _offset = end;
      if (!complete) return;
      _pending = null;
      _nextBucketUs = endUs;
    }
    if (_nextBucketUs >= untilUs && _pending == null) _refilling = false;
  }

  void dispose() {
    _disposed = true;
    _pending = null;
    unawaited(_subscription.cancel());
    unawaited(_updates.close());
  }
}
