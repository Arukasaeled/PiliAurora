import 'package:pili_aurora/models/dynamics/result.dart';
import 'package:pili_aurora/models/model_video.dart';
import 'package:pili_aurora/models/remote/dynamic/dyn_topic_feed/item.dart';
import 'package:pili_aurora/models/remote/dynamic/dyn_topic_feed/topic_card_list.dart';
import 'package:pili_aurora/models/remote/live/live_feed_index/card_data_list_item.dart';
import 'package:pili_aurora/models/remote/live/live_feed_index/card_list.dart';
import 'package:pili_aurora/models/search/result.dart';
import 'package:pili_aurora/models/remote/popular/popular_precious/data.dart';
import 'package:pili_aurora/models/remote/popular/popular_series_one/data.dart';

abstract final class MediaAuthorFilter {
  static bool isBlocked(
    Object? item,
    bool Function(int?) contains, {
    bool includeCoauthors = true,
  }) {
    return switch (item) {
      BaseSimpleVideoItemModel(:final owner, :final authors) =>
        contains(owner.mid) ||
            (includeCoauthors &&
                authors.isCooperation &&
                authors.mids?.any(contains) == true),
      SearchArticleItemModel(:final mid) => contains(mid),
      SearchLiveItemModel(:final uid) => contains(uid),
      SearchUserItemModel(:final mid) => contains(mid),
      SearchUser(:final mid) => contains(mid),
      CardLiveItem(:final uid) => contains(uid),
      LiveCardList(:final cardData) => isBlocked(
        cardData?.smallCardV1,
        contains,
      ),
      DynamicItemModel(:final modules, :final orig) =>
        contains(modules.moduleAuthor?.mid) ||
            (includeCoauthors &&
                videos(item).any(
                  (video) =>
                      video.authors.isCooperation &&
                      video.authors.mids?.any(contains) == true,
                )) ||
            isBlocked(orig, contains, includeCoauthors: includeCoauthors),
      TopicCardItem(:final dynamicCardItem) => isBlocked(
        dynamicCardItem,
        contains,
        includeCoauthors: includeCoauthors,
      ),
      _ => false,
    };
  }

  /// 读取响应中的视频引用，避免补查前调用会推进游标的页面响应钩子。
  static Iterable<CooperativeVideo> videos(Object? source) sync* {
    switch (source) {
      case BaseVideoItemModel(
        :final aid,
        :final bvid,
        :final owner,
        :final authors,
      ):
        yield (aid: aid, bvid: bvid, ownerMid: owner.mid, authors: authors);
      case DynamicItemModel(:final modules, :final orig):
        final major = modules.moduleDynamic?.major;
        for (final archive in [major?.archive, major?.ugcSeason]) {
          if (archive != null) {
            yield (
              aid: archive.aid,
              bvid: archive.bvid,
              ownerMid: modules.moduleAuthor?.mid,
              authors: archive.authors,
            );
          }
        }
        yield* videos(orig);
      case TopicCardItem(:final dynamicCardItem):
        yield* videos(dynamicCardItem);
      case List():
        for (final item in source) {
          yield* videos(item);
        }
      case SearchNumData(:final list):
        yield* videos(list);
      case DynamicsDataModel(:final items):
        yield* videos(items);
      case TopicCardList(:final items):
        yield* videos(items);
      case PopularPreciousData(:final list):
        yield* videos(list);
      case PopularSeriesOneData(:final list):
        yield* videos(list);
    }
  }

  static Object? contentKey(Object? item) => switch (item) {
    BaseVideoItemModel(:final aid, :final bvid) =>
      bvid != null && bvid.isNotEmpty
          ? ('video', bvid)
          : aid != null
          ? ('av', aid)
          : null,
    SearchArticleItemModel(:final id) => id == null ? null : ('article', id),
    SearchLiveItemModel(:final roomid) =>
      roomid == null ? null : ('live', roomid),
    CardLiveItem(:final roomid) => roomid == null ? null : ('live', roomid),
    LiveCardList(:final cardData) => contentKey(cardData?.smallCardV1),
    DynamicItemModel(:final idStr) =>
      idStr == null ? null : ('dynamic', '$idStr'),
    TopicCardItem(:final dynamicCardItem) => contentKey(dynamicCardItem),
    SearchUserItemModel(:final mid) => mid == null ? null : ('user', mid),
    _ => null,
  };
}
