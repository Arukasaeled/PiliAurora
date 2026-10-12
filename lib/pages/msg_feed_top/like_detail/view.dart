import 'package:pili_aurora/common/skeleton/msg_feed_top.dart';
import 'package:pili_aurora/common/sliver_single_child_delegate.dart';
import 'package:pili_aurora/common/widgets/flutter/refresh_indicator.dart';
import 'package:pili_aurora/common/widgets/image/network_img_layer.dart';
import 'package:pili_aurora/common/widgets/loading_widget/http_error.dart';
import 'package:pili_aurora/common/widgets/scaffold/simple_scaffold.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/common/image_type.dart';
import 'package:pili_aurora/models/remote/msg/msg_like_detail/card.dart';
import 'package:pili_aurora/models/remote/msg/msg_like_detail/item.dart';
import 'package:pili_aurora/pages/msg_feed_top/like_detail/controller.dart';
import 'package:pili_aurora/utils/app_scheme.dart';
import 'package:pili_aurora/utils/date_utils.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class LikeDetailPage extends ConsumerStatefulWidget {
  const LikeDetailPage({super.key});

  @override
  ConsumerState<LikeDetailPage> createState() => _LikeDetailPageState();
}

class _LikeDetailPageState extends ConsumerState<LikeDetailPage> {
  late final LikeDetailArgs _args;

  @override
  void initState() {
    super.initState();
    final arguments = Get.arguments as Map;
    _args = LikeDetailArgs(
      cardId: arguments['id'] as String,
      uri: arguments['uri'] as String?,
      counts: arguments['counts'] as int,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final feed = ref.watch(likeDetailFeedProvider(_args));
    final controller = ref.read(likeDetailFeedProvider(_args).notifier);
    return SimpleScaffold(
      appBar: AppBar(title: const Text('点赞详情')),
      body: refreshIndicator(
        onRefresh: controller.refresh,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverPadding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.viewPaddingOf(context).bottom + 100,
              ),
              sliver: _buildBody(theme, feed.loadingState, controller),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(
    ThemeData theme,
    LoadingState<List<MsgLikeDetailItem>?> loadingState,
    LikeDetailFeedNotifier controller,
  ) {
    switch (loadingState) {
      case Loading():
        return const SliverPrototypeExtentList(
          prototypeItem: MsgFeedTopSkeleton(),
          delegate: SliverSingleChildDelegate(
            count: 12,
            child: MsgFeedTopSkeleton(),
          ),
        );
      case Success(:final response):
        final divider = Divider(
          indent: 72,
          endIndent: 20,
          height: 6,
          color: Colors.grey.withValues(alpha: 0.1),
        );
        return SliverMainAxisGroup(
          slivers: [
            if (controller.card != null) ...[
              _buildCard(controller.card!),
              SliverToBoxAdapter(
                child: Divider(
                  height: 1,
                  color: Colors.grey.withValues(alpha: 0.1),
                ),
              ),
            ],
            SliverList.separated(
              itemCount: response!.length,
              itemBuilder: (context, index) {
                if (index == response.length - 1) {
                  controller.loadMore();
                }
                return _buildItem(theme, response[index]);
              },
              separatorBuilder: (context, index) => divider,
            ),
          ],
        );
      case Error(:final errMsg):
        return HttpError(
          errMsg: errMsg,
          onReload: controller.refresh,
        );
    }
  }

  Widget _buildCard(MsgLikeDetailCard card) {
    return SliverToBoxAdapter(
      child: ListTile(
        onTap: () {
          if (_args.uri != null) {
            PiliScheme.routePushFromUrl(_args.uri!);
          }
        },
        title: Text('${card.business}: ${card.title}'),
      ),
    );
  }

  Widget _buildItem(ThemeData theme, MsgLikeDetailItem item) {
    return ListTile(
      onTap: () => Get.toNamed('/member?mid=${item.user!.mid}'),
      leading: NetworkImgLayer(
        width: 45,
        height: 45,
        type: ImageType.avatar,
        src: item.user!.avatar,
      ),
      title: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: "${item.user!.nickname}",
              style: theme.textTheme.titleSmall!.copyWith(
                height: 1.5,
                color: theme.colorScheme.primary,
              ),
            ),
            TextSpan(
              text: " 赞了我",
              style: TextStyle(
                fontSize: 13,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        DateFormatUtils.dateFormat(item.likeTime),
        style: theme.textTheme.bodyMedium!.copyWith(
          fontSize: 13,
          color: theme.colorScheme.outline,
        ),
      ),
    );
  }
}
