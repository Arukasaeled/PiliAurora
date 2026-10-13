import 'package:pili_aurora/models/dynamics/up.dart';
import 'package:pili_aurora/models/model_avatar.dart';
import 'package:pili_aurora/utils/parse_int.dart';

class FollowItemModel extends UpItem {
  int? attribute;
  int? mtime;
  String? sign;
  BaseOfficialVerify? officialVerify;

  FollowItemModel({
    required super.mid,
    this.attribute,
    this.mtime,
    super.uname,
    super.face,
    this.sign,
    this.officialVerify,
  });

  factory FollowItemModel.fromJson(Map<String, dynamic> json) =>
      FollowItemModel(
        mid: json['mid'] as int? ?? 0,
        attribute: json['attribute'] as int?,
        mtime: safeToInt(json['mtime']),
        uname: json['uname'] as String?,
        face: json['face'] as String?,
        sign: json['sign'] as String?,
        officialVerify: json['official_verify'] == null
            ? null
            : BaseOfficialVerify.fromJson(
                json['official_verify'] as Map<String, dynamic>,
              ),
      );
}
