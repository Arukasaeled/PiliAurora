import 'package:pili_aurora/models/model_owner.dart';
import 'package:pili_aurora/models/model_video.dart';

abstract class BaseRcmdVideoItemModel extends BaseVideoItemModel {
  String? goto;
  String? uri;
  String? rcmdReason;

  // app推荐专属
  int? param;
  String? pgcBadge;
}

class RcmdVideoItemModel extends BaseRcmdVideoItemModel {
  RcmdVideoItemModel.fromJson(Map<String, dynamic> json) {
    aid = json["id"];
    bvid = json["bvid"];
    cid = json["cid"];
    goto = json["goto"];
    uri = json["uri"];
    cover = json["pic"];
    title = json["title"];
    duration = json["duration"];
    pubdate = json["pubdate"];
    owner = Owner.fromJson(json["owner"]);
    authors = VideoAuthors.fromJson(json);
    stat = Stat.fromJson(json["stat"]);
    isFollowed = json["is_followed"] == 1;
    rcmdReason = json["rcmd_reason"]?['content'];
  }
}
