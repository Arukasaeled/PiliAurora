import 'package:pili_aurora/utils/parse_int.dart';

/// 列表明确标识的合作视频及其已知作者；补查结果写回作者集合。
class VideoAuthors {
  VideoAuthors({this.isCooperation = false, this.mids});

  final bool isCooperation;
  Set<int>? mids;

  factory VideoAuthors.fromJson(Map<String, dynamic> json) {
    final staff = json['staff'];
    final mids = staff is List
        ? staff
              .whereType<Map>()
              .map((item) => safeToInt(item['mid']))
              .whereType<int>()
              .where((mid) => mid > 0)
              .toSet()
        : null;
    return VideoAuthors(
      isCooperation:
          json['rights']?['is_cooperation'] == 1 ||
          json['is_union_video'] == 1 ||
          json['is_cooperation'] == 1 ||
          mids?.isNotEmpty == true,
      mids: mids?.isNotEmpty == true ? mids : null,
    );
  }
}

typedef CooperativeVideo = ({
  int? aid,
  String? bvid,
  int? ownerMid,
  VideoAuthors authors,
});

abstract class BaseSimpleVideoItemModel {
  late String title;
  String? bvid;
  int? cid;
  String? cover;
  int duration = -1;
  late BaseOwner owner;
  late BaseStat stat;
  VideoAuthors authors = VideoAuthors();
}

abstract class BaseVideoItemModel extends BaseSimpleVideoItemModel {
  int? aid;
  String? desc;
  int? pubdate;
  bool isFollowed = false;
}

abstract class BaseOwner {
  int? mid;
  String? name;
}

abstract class BaseStat {
  int? view;
  int? like;
  int? danmu;
}

class Stat extends BaseStat {
  Stat.fromJson(Map<String, dynamic> json) {
    view = json["view"];
    like = json["like"];
    danmu = json['danmaku'];
  }
}

class PlayStat extends BaseStat {
  PlayStat.fromJson(Map<String, dynamic> json) {
    view = json['play'];
    danmu = json['danmaku'];
  }
}
