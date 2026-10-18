import 'package:pili_aurora/models/remote/live/live_guard_top_list/item.dart';

class LiveGuardTopListData {
  int? count;
  List<LiveGuardTopListItem> tops;
  List<LiveGuardTopListItem> list;

  LiveGuardTopListData({
    this.count,
    this.tops = const [],
    this.list = const [],
  });

  factory LiveGuardTopListData.fromJson(Map<String, dynamic> json) {
    List<LiveGuardTopListItem> parseList(Object? value) {
      return (value as List<dynamic>? ?? const [])
          .map(
            (item) => LiveGuardTopListItem.fromJson(
              item as Map<String, dynamic>,
            ),
          )
          .toList();
    }

    final top3 = parseList(json['top3']);
    final list = parseList(json['list']);
    return LiveGuardTopListData(
      count: (json['info'] as Map<String, dynamic>?)?['num'] as int?,
      tops: top3.isNotEmpty ? top3 : list.take(3).toList(),
      list: list,
    );
  }
}
