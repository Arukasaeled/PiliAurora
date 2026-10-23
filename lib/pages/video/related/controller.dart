import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/video.dart';
import 'package:pili_aurora/models/model_hot_video_item.dart';
import 'package:pili_aurora/pages/common/discovery_list_controller.dart';
import 'package:get/get.dart';

class RelatedController
    extends
        DiscoveryListController<List<HotVideoItemModel>?, HotVideoItemModel> {
  @override
  bool get supportsPagination => false;

  RelatedController({this.autoQuery = true});
  String bvid = Get.arguments['bvid'];
  final bool autoQuery;

  @override
  void onInit() {
    super.onInit();
    if (autoQuery) {
      queryData();
    }
  }

  @override
  Future<LoadingState<List<HotVideoItemModel>?>> customGetData() =>
      VideoHttp.relatedVideoList(bvid: bvid);
}
