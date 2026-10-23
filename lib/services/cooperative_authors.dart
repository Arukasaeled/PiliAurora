import 'dart:async';
import 'dart:collection';

import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/video.dart';
import 'package:pili_aurora/models/model_video.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/id_utils.dart';
import 'package:pili_aurora/utils/parse_int.dart';

typedef _AuthorCacheEntry = ({Set<int>? mids, DateTime expiresAt});

/// 缓存作者身份而非屏蔽结论，拉黑/解除后直接使用当前黑名单重算。
class CooperativeAuthors {
  CooperativeAuthors({
    required this.load,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  static final shared = CooperativeAuthors(load: _loadAuthors);
  static const _maxConcurrent = 2;
  static const _maxEntries = 256;
  final Future<Set<int>?> Function(String bvid) load;
  final DateTime Function() _now;
  final _cache = <String, _AuthorCacheEntry>{};
  final _pending = <String, Future<Set<int>?>>{};
  final _waiters = Queue<Completer<void>>();
  int _active = 0;

  static Future<Set<int>?> _loadAuthors(String bvid) async {
    final result = await VideoHttp.videoIntro(
      bvid: bvid,
      account: Accounts.main,
    );
    if (result case Success(:final response)) {
      final staff = response.staff;
      if (staff == null || staff.isEmpty) return null;
      final mids = <int>{
        ?response.owner?.mid,
        ...staff.map((author) => safeToInt(author.mid)).whereType<int>(),
      }..removeWhere((mid) => mid <= 0);
      return mids.isEmpty ? null : mids;
    }
    return null;
  }

  Future<void> prepare(
    List<CooperativeVideo> videos, {
    required bool Function() isCurrent,
  }) async {
    var index = 0;
    Future<void> worker() async {
      while (isCurrent() && index < videos.length) {
        final video = videos[index++];
        final bvid =
            video.bvid != null && IdUtils.bvRegexExact.hasMatch(video.bvid!)
            ? video.bvid!
            : video.aid != null && video.aid! > 0
            ? IdUtils.av2bv(video.aid!)
            : null;
        if (bvid == null) continue;
        final mids = await _resolve(bvid);
        if (isCurrent() && mids != null) video.authors.mids = mids;
      }
    }

    await Future.wait([
      for (var i = 0; i < _maxConcurrent && i < videos.length; i++) worker(),
    ]);
  }

  Future<Set<int>?> _resolve(String bvid) {
    final cached = _cache.remove(bvid);
    if (cached != null && _now().isBefore(cached.expiresAt)) {
      _cache[bvid] = cached;
      return Future.value(cached.mids);
    }
    if (_pending[bvid] case final pending?) return pending;
    final pending = _fetch(bvid);
    _pending[bvid] = pending;
    return pending.whenComplete(() {
      _pending.remove(bvid);
    });
  }

  Future<void> _acquire() async {
    if (_active < _maxConcurrent) {
      _active++;
    } else {
      final waiter = Completer<void>();
      _waiters.add(waiter);
      await waiter.future;
    }
  }

  Future<Set<int>?> _fetch(String bvid) async {
    await _acquire();
    Set<int>? mids;
    try {
      mids = await load(bvid);
    } catch (_) {
      // 补查失败时沿用已知作者，短暂缓存失败以避免反复请求。
    } finally {
      if (_waiters.isEmpty) {
        _active--;
      } else {
        _waiters.removeFirst().complete();
      }
    }
    _cache[bvid] = (
      mids: mids,
      expiresAt: _now().add(
        mids == null ? const Duration(minutes: 1) : const Duration(hours: 1),
      ),
    );
    while (_cache.length > _maxEntries) {
      _cache.remove(_cache.keys.first);
    }
    return mids;
  }
}
