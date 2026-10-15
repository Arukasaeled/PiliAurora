import 'package:pili_aurora/common/widgets/flutter/vertical_tabs.dart';
import 'package:pili_aurora/common/widgets/tab_activity.dart';
import 'package:pili_aurora/models/common/rank_type.dart';
import 'package:pili_aurora/pages/rank/controller.dart';
import 'package:pili_aurora/pages/rank/zone/view.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class RankPage extends StatefulWidget {
  const RankPage({super.key});

  @override
  State<RankPage> createState() => _RankPageState();
}

class _RankPageState extends State<RankPage>
    with AutomaticKeepAliveClientMixin {
  final RankController _rankController = Get.put(RankController());

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    return Row(
      children: [
        _buildTab(theme),
        Expanded(
          child: TabBarView(
            physics: const NeverScrollableScrollPhysics(),
            controller: _rankController.tabController,
            children: [
              for (final (index, item) in RankType.values.indexed)
                TabActivity(
                  controller: _rankController.tabController,
                  index: index,
                  child: ZonePage(
                    rid: item.rid,
                    seasonType: item.seasonType,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildTab(ThemeData theme) {
    return VerticalTabBar(
      dividerWidth: 0,
      isScrollable: true,
      indicatorWeight: 3,
      indicatorSize: .tab,
      controller: _rankController.tabController,
      padding: .only(bottom: MediaQuery.paddingOf(context).bottom + 105),
      tabs: RankType.values.map((e) => VerticalTab(text: e.label)).toList(),
      onTap: (index) {
        if (!_rankController.tabController.indexIsChanging) {
          _rankController.animateToTop();
        } else {
          _rankController
            ..tabIndex.value = index
            ..tabController.animateTo(index);
        }
      },
    );
  }
}
