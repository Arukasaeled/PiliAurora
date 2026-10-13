import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/reply.dart';
import 'package:pili_aurora/models/remote/emote/package.dart';
import 'package:pili_aurora/models/remote/emote/emote.dart';
import 'package:pili_aurora/pages/common/common_list_controller.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class RecentEmote {
  const RecentEmote(this.emote, this.width);

  final Emote emote;
  final double? width;

  factory RecentEmote.fromJson(Map<dynamic, dynamic> json) => RecentEmote(
    Emote(text: json['text'] as String?, url: json['url'] as String?),
    (json['width'] as num?)?.toDouble(),
  );

  Map<String, dynamic> toJson() => {
    'text': emote.text,
    'url': emote.url,
    'width': width,
  };
}

class EmotePanelController extends CommonListController<List<Package>?, Package>
    with GetTickerProviderStateMixin {
  TabController? tabController;
  final recentEmotes = <RecentEmote>[].obs;

  @override
  void onInit() {
    super.onInit();
    final history =
        GStorage.localCache.get(LocalCacheKey.recentEmotes) as List?;
    if (history != null) {
      recentEmotes.assignAll(
        history.map((item) => RecentEmote.fromJson(item as Map)),
      );
    }
    queryData();
  }

  void recordEmote(Emote emote, double? width) {
    recentEmotes.removeWhere(
      (item) => item.emote.text == emote.text && item.emote.url == emote.url,
    );
    recentEmotes.insert(0, RecentEmote(emote, width));
    if (recentEmotes.length > 40) recentEmotes.removeLast();
    GStorage.localCache.put(
      LocalCacheKey.recentEmotes,
      recentEmotes.map((item) => item.toJson()).toList(),
    );
  }

  @override
  bool customHandleResponse(bool isRefresh, Success<List<Package>?> response) {
    final previousIndex = tabController?.index;
    tabController?.dispose();
    tabController = null;
    final packages = response.response;
    if (packages?.isNotEmpty == true) {
      final length = packages!.length + 1;
      final preferredIndex = previousIndex ?? (recentEmotes.isEmpty ? 1 : 0);
      tabController = TabController(
        length: length,
        vsync: this,
        initialIndex: preferredIndex.clamp(0, length - 1).toInt(),
      );
    }
    loadingState.value = response;
    return true;
  }

  @override
  Future<LoadingState<List<Package>?>> customGetData() =>
      ReplyHttp.getEmoteList(business: 'reply');

  @override
  void onClose() {
    tabController?.dispose();
    super.onClose();
  }
}
