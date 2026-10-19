import 'dart:async';
import 'dart:collection';
import 'dart:io' show File;

import 'package:pili_aurora/services/danmaku/work_quota.dart';

import 'package:pili_aurora/grpc/bilibili/community/service/dm/v1.pb.dart';
import 'package:pili_aurora/grpc/dm.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/pages/danmaku/cache.dart';
import 'package:pili_aurora/pages/danmaku/timeline_range.dart';
import 'package:pili_aurora/pages/danmaku/merge.dart';
import 'package:pili_aurora/plugin/pl_player/controller.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/danmaku_utils.dart';
import 'package:pili_aurora/utils/path_utils.dart';
import 'package:pili_aurora/utils/storage_pref.dart';
import 'package:pili_aurora/utils/utils.dart';
import 'package:pili_aurora/services/diagnostics/diagnostics.dart';
import 'package:path/path.dart' as path;

class PlDanmakuController {
  PlDanmakuController(
    this._cid,
    this._plPlayerController,
    this._isFileSource,
  ) : _mergeDanmaku = _plPlayerController.mergeDanmaku {
    _unregisterDiagnostics = Diagnostics.instance.register(
      'danmaku.$hashCode',
      () => {
        'elements': _cache.elementCount,
        'buckets': _cache.bucketCount,
        'pendingSegments': _requestedSeg.length,
        'localFile': _isFileSource,
        'frameRate': Pref.danmakuFrameRate,
        'enabled': _plPlayerController.enableShowDanmaku.value,
      },
    );
  }

  late final void Function() _unregisterDiagnostics;

  final int _cid;
  final PlPlayerController _plPlayerController;
  bool _mergeDanmaku;
  final bool _isFileSource;

  late final _isLogin = Accounts.main.isLogin;

  final _cache = DanmakuCache();
  // 请求中的分段单独记录；成功加载后由缓存记录，淘汰后允许重新请求。
  final Set<int> _requestedSeg = HashSet();
  bool _disposed = false;
  final _lifetimeWork = DanmakuWorkToken();
  var _ruleWork = DanmakuWorkToken();

  final _changes = StreamController<DanmakuSourceChange>.broadcast(sync: true);
  Stream<DanmakuSourceChange> get changes => _changes.stream;
  final _rawSegments = <int, List<DanmakuElem>>{};
  List<DanmakuElem>? _rawFile;
  int _ruleRevision = 0;
  final _invalidatedSegments = <int>{};
  bool _fileInvalidated = false;
  Future<void>? _reprocessing;

  /// 接受规则时先同步失效；重算仅提交当前修订的结果。
  Future<void> refreshRules() {
    if (_disposed) return Future.value();
    _ruleWork.cancel();
    _ruleWork = DanmakuWorkToken();
    _ruleRevision++;
    _mergeDanmaku = _plPlayerController.mergeDanmaku;
    _cache.clear();
    _invalidatedSegments
      ..clear()
      ..addAll(_rawSegments.keys);
    _fileInvalidated = _isFileSource;
    _changes.add(
      DanmakuSourceChange(
        kind: DanmakuSourceChangeKind.invalidated,
        ruleRevision: _ruleRevision,
      ),
    );
    return _reprocessing ??= _reprocess().whenComplete(
      () => _reprocessing = null,
    );
  }

  Future<void> _reprocess() async {
    var revision = -1;
    while (!_disposed && revision != _ruleRevision) {
      revision = _ruleRevision;
      if (_isFileSource) {
        final raw = _rawFile;
        if (raw != null) await handleDanmaku(raw);
      } else {
        for (final segment in _rawSegments.keys.toList()) {
          if (_disposed || revision != _ruleRevision) break;
          final raw = _rawSegments[segment];
          if (raw != null) await handleDanmaku(raw, segmentIndex: segment);
        }
      }
    }
  }

  void dispose() {
    _unregisterDiagnostics();
    _disposed = true;
    _lifetimeWork.cancel();
    _ruleWork.cancel();
    _cache.clear();
    _requestedSeg.clear();
    _rawSegments.clear();
    _rawFile = null;
    _invalidatedSegments.clear();
    unawaited(_changes.close());
  }

  Future<void> queryDanmaku(int segmentIndex) async {
    if (_isFileSource || _disposed) {
      return;
    }
    if (_requestedSeg.contains(segmentIndex) ||
        _cache.containsSegment(segmentIndex)) {
      return;
    }
    _requestedSeg.add(segmentIndex);
    try {
      final res = await DmGrpc.dmSegMobile(
        cid: _cid,
        segmentIndex: segmentIndex + 1,
        workToken: _lifetimeWork,
      );
      if (_disposed) return;

      if (res case Success(:final response)) {
        if (response.state == 1) {
          _plPlayerController.dmState.add(_cid);
        }
        // 合并完成并写入缓存前仍算请求中，避免播放时钟重复请求同一分段。
        await handleDanmaku(response.elems, segmentIndex: segmentIndex);
      }
    } finally {
      _requestedSeg.remove(segmentIndex);
    }
  }

  Future<void> handleDanmaku(
    List<DanmakuElem> elems, {
    int? segmentIndex,
  }) async {
    if (_disposed) return;
    final revision = _ruleRevision;
    if (_isFileSource) {
      _rawFile = elems;
    } else if (segmentIndex != null) {
      _rawSegments[segmentIndex] = elems;
      while (_rawSegments.length > _cache.maxSegments) {
        _rawSegments.remove(_rawSegments.keys.first);
      }
    }
    final filtered = <DanmakuElem>[];
    final retained = _isFileSource ? <DanmakuElem>[] : null;
    final segmentBuckets = segmentIndex == null
        ? null
        : <int, List<DanmakuElem>>{};
    final maxElementsPerBucket = _cache.maxElementsPerBucket;

    final filters = _plPlayerController.filters;
    final shouldFilter = filters.count != 0;
    for (final raw in elems) {
      final element = DanmakuElem.fromBuffer(raw.writeToBuffer());
      if (!_isFileSource &&
          (segmentIndex == null ||
              DmUtils.calcSegment(element.progress) != segmentIndex)) {
        continue;
      }
      if (_isLogin) {
        element.isSelf = element.midHash == _plPlayerController.midHash;
      }

      if (!element.isSelf && shouldFilter && filters.remove(element)) continue;
      filtered.add(element);
    }
    final List<DanmakuElem> processed;
    try {
      processed = _mergeDanmaku
          ? await mergeDanmakuInBackground(filtered, token: _ruleWork)
          : filtered;
    } on DanmakuWorkCancelled {
      return;
    }
    if (_disposed || revision != _ruleRevision) return;
    for (final element in processed) {
      if (_isFileSource) {
        retained!.add(element);
      } else {
        final bucketIndex = element.progress ~/ 100;
        final bucket = segmentBuckets![bucketIndex] ??= <DanmakuElem>[];
        if (bucket.length < maxElementsPerBucket) bucket.add(element);
      }
    }
    if (_isFileSource) {
      // 本地文件无法回源，保留完整弹幕。
      _cache.addFileElements(retained!);
      _fileInvalidated = false;
    } else if (segmentIndex != null) {
      _cache.addSegmentBuckets(segmentIndex, segmentBuckets!);
      _invalidatedSegments.remove(segmentIndex);
    }
    _changes.add(
      DanmakuSourceChange(
        kind: DanmakuSourceChangeKind.ready,
        ruleRevision: revision,
        startUs: segmentIndex == null ? 0 : segmentIndex * 360000000,
        endUs: segmentIndex == null ? null : (segmentIndex + 1) * 360000000,
      ),
    );
  }

  List<DanmakuElem>? getCurrentDanmaku(int progress) {
    if (_isFileSource) {
      initFileDmIfNeeded();
    } else {
      final int segmentIndex = DmUtils.calcSegment(progress);
      if (!_requestedSeg.contains(segmentIndex) &&
          !_cache.containsSegment(segmentIndex)) {
        queryDanmaku(segmentIndex);
        return null;
      }
    }
    return _cache.getAt(progress);
  }

  DanmakuTimelineRange readRange(int startUs, int endUs) => _cache.readRange(
    startUs,
    endUs,
    ruleRevision: _ruleRevision,
    missingState: (segment) =>
        _fileInvalidated || _invalidatedSegments.contains(segment)
        ? DanmakuCoverageState.invalidated
        : DanmakuCoverageState.missing,
  );

  Iterable<DanmakuElem> peekBufferedDanmaku(int start, int end) => readRange(
    start * 1000,
    end * 1000,
  ).entries.take(64).map((entry) => entry.element);

  bool _fileDmLoaded = false;

  void initFileDmIfNeeded() {
    if (_fileDmLoaded) return;
    _fileDmLoaded = true;
    _initFileDm();
  }

  @pragma('vm:notify-debugger-on-exception')
  Future<void> _initFileDm() async {
    try {
      final fileSource = _plPlayerController.currentFileSource;
      if (fileSource == null) return;
      final file = File(
        path.join(
          fileSource.dir,
          PathUtils.danmakuName,
        ),
      );
      if (!file.existsSync()) return;
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) return;
      final elem = DmSegMobileReply.fromBuffer(bytes).elems;
      await handleDanmaku(elem);
    } catch (e, s) {
      Utils.reportError(e, s);
    }
  }
}
