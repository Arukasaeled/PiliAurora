import 'package:pili_aurora/common/widgets/dialog/dialog.dart';
import 'package:pili_aurora/common/skeleton/msg_feed_top.dart';
import 'package:pili_aurora/common/sliver_single_child_delegate.dart';
import 'package:pili_aurora/common/widgets/flutter/refresh_indicator.dart';
import 'package:pili_aurora/common/widgets/pendant_avatar.dart';
import 'package:pili_aurora/common/widgets/loading_widget/http_error.dart';
import 'package:pili_aurora/common/widgets/scaffold/simple_scaffold.dart';
import 'package:pili_aurora/common/widgets/view_sliver_safe_area.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/remote/follow/list.dart';
import 'package:pili_aurora/pages/fan/controller.dart';
import 'package:pili_aurora/pages/follow_type/view.dart';
import 'package:pili_aurora/pages/follow_type/widgets/item.dart';
import 'package:pili_aurora/pages/share/view.dart' show UserModel;
import 'package:pili_aurora/utils/date_utils.dart';
import 'package:pili_aurora/utils/parse_int.dart';
import 'package:pili_aurora/utils/platform_utils.dart';
import 'package:pili_aurora/utils/utils.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class FansPage extends StatefulWidget {
  const FansPage({
    super.key,
    this.showName = true,
    this.onSelect,
  });

  final bool showName;
  final ValueChanged<UserModel>? onSelect;

  @override
  State<FansPage> createState() => _FansPageState();

  static void toFansPage({dynamic mid, String? name}) {
    if (mid == null) {
      return;
    }
    Get.toNamed(
      '/fan',
      arguments: {
        'mid': safeToInt(mid),
        'name': name,
      },
    );
  }
}

class _FansPageState extends FollowTypePageState<FansPage> {
  @override
  late final FansController controller;
  late final bool newFans = Get.arguments?['newFans'] == true;
  late final flag = widget.onSelect == null && controller.isOwner;
  final Set<int> _followingMids = {};

  @override
  void initState() {
    super.initState();
    controller = Get.put(
      FansController(widget.showName, newFans: newFans),
      tag: Get.arguments?['mid']?.toString() ?? Utils.generateRandomString(8),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!newFans) return super.build(context);
    return SimpleScaffold(
      appBar: AppBar(title: const Text('新增粉丝')),
      body: refreshIndicator(
        onRefresh: controller.onRefresh,
        child: CustomScrollView(
          controller: controller.scrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            ViewSliverSafeArea(
              sliver: Obx(() => _buildNewFans(controller.loadingState.value)),
            ),
          ],
        ),
      ),
    );
  }

  @override
  PreferredSizeWidget? get appBar => widget.showName
      ? AppBar(
          title: controller.isOwner
              ? const Text('我的粉丝')
              : Obx(() {
                  final name = controller.name.value;
                  if (name != null) return Text('$name的粉丝');
                  return const SizedBox.shrink();
                }),
        )
      : null;

  Widget _buildNewFans(LoadingState<List<FollowItemModel>?> state) =>
      switch (state) {
        Loading() => const SliverPrototypeExtentList(
          prototypeItem: MsgFeedTopSkeleton(),
          delegate: SliverSingleChildDelegate(
            count: 12,
            child: MsgFeedTopSkeleton(),
          ),
        ),
        Success(:final response) =>
          response != null && response.isNotEmpty
              ? SliverList.builder(
                  itemCount: response.length,
                  itemBuilder: (context, index) {
                    if (index == response.length - 1) controller.onLoadMore();
                    final item = response[index];
                    return _NewFanItem(
                      item: item,
                      isFollowing: item.attribute == 2 || item.attribute == 6,
                      isBusy: _followingMids.contains(item.mid),
                      onTap: () => Get.toNamed('/member?mid=${item.mid}'),
                      onFollowBack:
                          flag &&
                              (item.attribute == 0 ||
                                  item.attribute == 2 ||
                                  item.attribute == 6)
                          ? () => _followBack(item)
                          : null,
                    );
                  },
                )
              : const SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(child: Text('暂无粉丝')),
                ),
        Error(:final errMsg) => HttpError(
          errMsg: errMsg,
          onReload: controller.onReload,
        ),
      };

  Future<void> _followBack(FollowItemModel item) async {
    if (!_followingMids.add(item.mid)) return;
    setState(() {});
    try {
      await controller.onFollowBack(item);
    } finally {
      if (mounted) setState(() => _followingMids.remove(item.mid));
    }
  }

  @override
  Widget buildItem(int index, FollowItemModel item) {
    void onRemove() => showConfirmDialog(
      context: context,
      title: Text('确定移除 ${item.uname} ？'),
      onConfirm: () => controller.onRemoveFan(index, item.mid),
    );

    return FollowTypeItem(
      item: item,
      onTap: () {
        if (widget.onSelect != null) {
          widget.onSelect!(
            UserModel(
              mid: item.mid,
              name: item.uname!,
              avatar: item.face!,
              selected: true,
            ),
          );
          return;
        }
        Get.toNamed('/member?mid=${item.mid}');
      },
      onLongPress: flag ? onRemove : null,
      onSecondaryTap: flag && !PlatformUtils.isMobile ? onRemove : null,
    );
  }
}

class _NewFanItem extends StatelessWidget {
  const _NewFanItem({
    required this.item,
    required this.isFollowing,
    required this.isBusy,
    required this.onTap,
    required this.onFollowBack,
  });

  final FollowItemModel item;
  final bool isFollowing;
  final bool isBusy;
  final VoidCallback onTap;
  final VoidCallback? onFollowBack;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final time = DateFormatUtils.dateFormat(item.mtime);
    return SizedBox(
      height: 76,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              PendantAvatar(
                size: 46,
                badgeSize: 14,
                item.face,
                officialType: item.officialVerify?.type,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.uname ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 14),
                    ),
                    Text(
                      time.isEmpty ? '关注了我' : '关注了我 · $time',
                      style: TextStyle(
                        color: colorScheme.outline,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              if (onFollowBack != null)
                FilledButton.tonal(
                  onPressed: isBusy ? null : onFollowBack,
                  style: FilledButton.styleFrom(
                    visualDensity: .compact,
                    tapTargetSize: .shrinkWrap,
                    padding: const .symmetric(horizontal: 16),
                  ),
                  child: Text(
                    isBusy
                        ? '处理中'
                        : isFollowing
                        ? '取消关注'
                        : '回关',
                  ),
                )
              else if (isFollowing)
                Text(
                  item.attribute == 6 ? '已互关' : '已关注',
                  style: TextStyle(color: colorScheme.outline, fontSize: 12),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
