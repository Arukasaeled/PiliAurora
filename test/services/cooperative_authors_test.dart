import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/models/home/rcmd/result.dart';
import 'package:pili_aurora/models/model_hot_video_item.dart';
import 'package:pili_aurora/models/model_rec_video_item.dart';
import 'package:pili_aurora/models/model_video.dart';
import 'package:pili_aurora/models/search/result.dart';
import 'package:pili_aurora/services/cooperative_authors.dart';
import 'package:pili_aurora/utils/id_utils.dart';
import 'package:pili_aurora/utils/media_author_filter.dart';

CooperativeVideo _video(int aid, {bool bvidOnly = false}) => (
  aid: bvidOnly ? null : aid,
  bvid: bvidOnly ? IdUtils.av2bv(aid) : null,
  ownerMid: 8,
  authors: VideoAuthors(isCooperation: true),
);

void main() {
  test('同一视频合并查询，多个批次共享两个并发名额', () async {
    final calls = <String>[];
    final responses = <String, Completer<Set<int>?>>{};
    var active = 0;
    var peak = 0;
    final service = CooperativeAuthors(
      load: (bvid) async {
        calls.add(bvid);
        active++;
        if (active > peak) peak = active;
        final result = responses.putIfAbsent(bvid, Completer<Set<int>?>.new);
        try {
          return await result.future;
        } finally {
          active--;
        }
      },
    );
    final a = _video(1);
    final b = _video(2);
    final c = _video(3);
    final sameA = _video(1, bvidOnly: true);
    final d = _video(4);
    final first = service.prepare([a, b, c], isCurrent: () => true);
    final second = service.prepare([sameA, d], isCurrent: () => true);
    await Future<void>.delayed(Duration.zero);
    expect(calls, [IdUtils.av2bv(1), IdUtils.av2bv(2)]);
    responses[IdUtils.av2bv(1)]!.complete({7, 8});
    await Future<void>.delayed(Duration.zero);
    expect(calls, hasLength(3));
    responses[IdUtils.av2bv(2)]!.complete({8, 9});
    await Future<void>.delayed(Duration.zero);
    expect(calls.toSet(), {for (var i = 1; i <= 4; i++) IdUtils.av2bv(i)});
    responses[IdUtils.av2bv(3)]!.complete({8, 9});
    responses[IdUtils.av2bv(4)]!.complete({8, 9});
    await Future.wait([first, second]);
    expect(peak, 2);
    expect(a.authors.mids, {7, 8});
    expect(sameA.authors.mids, {7, 8});
    expect(calls, hasLength(4));
  });

  test('成功作者缓存跨批次复用，一小时后重新查询', () async {
    var now = DateTime(2026, 10, 23);
    var calls = 0;
    final service = CooperativeAuthors(
      now: () => now,
      load: (_) async {
        calls++;
        return calls == 1 ? {7, 8} : {8, 9};
      },
    );
    await service.prepare([_video(1)], isCurrent: () => true);
    final cached = _video(1);
    await service.prepare([cached], isCurrent: () => true);
    expect(calls, 1);
    expect(cached.authors.mids, {7, 8});
    now = now.add(const Duration(hours: 1));
    final refreshed = _video(1);
    await service.prepare([refreshed], isCurrent: () => true);
    expect(calls, 2);
    expect(refreshed.authors.mids, {8, 9});
  });

  test('失败保留未知状态并限频，一分钟后可重试', () async {
    var now = DateTime(2026, 10, 23);
    var calls = 0;
    final service = CooperativeAuthors(
      now: () => now,
      load: (_) async {
        calls++;
        if (calls == 1) throw StateError('fixture failure');
        return {7, 8};
      },
    );
    final failed = _video(1);
    await service.prepare([failed], isCurrent: () => true);
    await service.prepare([_video(1)], isCurrent: () => true);
    expect(failed.authors.mids, isNull);
    expect(calls, 1);
    now = now.add(const Duration(minutes: 1));
    final retry = _video(1);
    await service.prepare([retry], isCurrent: () => true);
    expect(calls, 2);
    expect(retry.authors.mids, {7, 8});
  });

  test('失效批次不写回作者并停止后续补查', () async {
    var current = true;
    final responses = <Completer<Set<int>?>>[];
    final service = CooperativeAuthors(
      load: (_) {
        final result = Completer<Set<int>?>();
        responses.add(result);
        return result.future;
      },
    );
    final videos = [_video(1), _video(2), _video(3)];
    final query = service.prepare(videos, isCurrent: () => current);
    await Future<void>.delayed(Duration.zero);
    current = false;
    for (final response in responses) {
      response.complete({7, 8});
    }
    await query;
    expect(responses, hasLength(2));
    expect(videos.every((video) => video.authors.mids == null), isTrue);
  });

  test('作者缓存保留最近使用的256条，淘汰旧条目', () async {
    var calls = 0;
    final service = CooperativeAuthors(
      load: (_) async {
        calls++;
        return {8, 9};
      },
    );
    await service.prepare([
      for (var i = 1; i <= 256; i++) _video(i),
    ], isCurrent: () => true);
    await service.prepare([_video(1), _video(257)], isCurrent: () => true);
    expect(calls, 257);
    await service.prepare([_video(1)], isCurrent: () => true);
    expect(calls, 257);
    await service.prepare([_video(2)], isCurrent: () => true);
    expect(calls, 258);
  });

  test('各视频列表模型保留合作标志及已有作者信息', () {
    final json = <String, dynamic>{
      'aid': 1,
      'id': 1,
      'bvid': IdUtils.av2bv(1),
      'title': 'fixture',
      'duration': 120,
      'owner': {'mid': 8},
      'stat': <String, dynamic>{},
      'rights': {'is_cooperation': 1},
      'staff': [
        {'mid': 8},
        {'mid': '7'},
      ],
    };
    final videos = <BaseVideoItemModel>[
      HotVideoItemModel.fromJson(json),
      RcmdVideoItemModel.fromJson(json),
      RcmdVideoItemAppModel.fromJson({
        ...json,
        'param': '1',
        'args': {'up_id': 8},
        'player_args': {'aid': 1, 'duration': 120},
      }),
      SearchVideoItemModel.fromJson({
        ...json,
        'rights': null,
        'is_union_video': 1,
        'mid': 8,
        'type': 'video',
        'duration': '02:00',
      }),
    ];
    for (final video in videos) {
      expect(video.authors.isCooperation, isTrue);
      expect(video.authors.mids, {7, 8});
      expect(MediaAuthorFilter.isBlocked(video, (mid) => mid == 7), isTrue);
      expect(MediaAuthorFilter.isBlocked(video, (mid) => mid == 9), isFalse);
    }
    expect(VideoAuthors.fromJson({}).isCooperation, isFalse);
    expect(VideoAuthors.fromJson({'is_union_video': 1}).isCooperation, isTrue);
  });
}
