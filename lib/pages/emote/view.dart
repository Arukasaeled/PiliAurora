import 'package:pili_aurora/common/widgets/button/icon_button.dart';
import 'package:pili_aurora/common/widgets/emote_tooltip.dart';
import 'package:pili_aurora/common/widgets/image/network_img_layer.dart';
import 'package:pili_aurora/common/widgets/loading_widget/loading_widget.dart';
import 'package:pili_aurora/common/widgets/scroll_physics.dart'
    show tabBarView, platformClampingPhysics;
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/common/image_type.dart';
import 'package:pili_aurora/models/remote/emote/emote.dart';
import 'package:pili_aurora/models/remote/emote/package.dart';
import 'package:pili_aurora/pages/emote/controller.dart';
import 'package:pili_aurora/utils/extension/theme_ext.dart';
import 'package:pili_aurora/utils/theme_utils.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class EmotePanel extends StatefulWidget {
  final Function(Emote emote, double? width, double? height) onChoose;

  const EmotePanel({super.key, required this.onChoose});

  @override
  State<EmotePanel> createState() => _EmotePanelState();
}

class _EmotePanelState extends State<EmotePanel>
    with AutomaticKeepAliveClientMixin {
  final EmotePanelController _emotePanelController = Get.put(
    EmotePanelController(),
  );

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final ThemeData theme = Theme.of(context);
    return Obx(
      () => _buildBody(theme, _emotePanelController.loadingState.value),
    );
  }

  Widget _buildBody(
    ThemeData theme,
    LoadingState<List<Package>?> loadingState,
  ) {
    return switch (loadingState) {
      Loading() => m3eLoading,
      Success(:final response) =>
        response != null && response.isNotEmpty
            ? Column(
                children: [
                  Expanded(
                    child: tabBarView(
                      controller: _emotePanelController.tabController,
                      children: [
                        Obx(() {
                          final recent = _emotePanelController.recentEmotes
                              .toList();
                          return recent.isEmpty
                              ? const Center(child: Text('暂无历史表情'))
                              : _buildEmoteGrid(theme, recent, 60);
                        }),
                        ...response.map((package) {
                          final emotes = package.emote;
                          if (emotes == null || emotes.isEmpty) {
                            return const SizedBox.shrink();
                          }
                          final small = emotes.first.meta?.size == 1;
                          final isTextEmote = package.type == 4;
                          return _buildEmoteGrid(
                            theme,
                            emotes
                                .map(
                                  (emote) => RecentEmote(
                                    emote,
                                    isTextEmote
                                        ? null
                                        : small
                                        ? 24
                                        : 42,
                                  ),
                                )
                                .toList(),
                            small ? 40 : 60,
                            isTextPackage: isTextEmote,
                          );
                        }),
                      ],
                    ),
                  ),
                  Divider(
                    height: 1,
                    color: theme.dividerColor.withValues(alpha: 0.1),
                  ),
                  Row(
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        child: iconButton(
                          iconSize: 20,
                          iconColor: theme.colorScheme.onSurfaceVariant
                              .withValues(alpha: 0.8),
                          onPressed: () => Get.toNamed(
                            '/webview',
                            parameters: {
                              'url':
                                  'https://www.bilibili.com/h5/mall/emoji-package/home?navhide=1&${ThemeUtils.themeUrl(theme.isDark)}',
                            },
                          ),
                          icon: const Icon(Icons.settings),
                        ),
                      ),
                      Expanded(
                        child: TabBar(
                          controller: _emotePanelController.tabController,
                          padding: const EdgeInsets.only(right: 60),
                          dividerColor: Colors.transparent,
                          dividerHeight: 0,
                          isScrollable: true,
                          tabAlignment: TabAlignment.start,
                          tabs: [
                            const Tab(
                              icon: Tooltip(
                                message: '历史表情',
                                child: Icon(Icons.history, size: 24),
                              ),
                            ),
                            ...response.map(
                              (e) => Padding(
                                padding: const EdgeInsets.all(8),
                                child: NetworkImgLayer(
                                  width: 24,
                                  height: 24,
                                  type: ImageType.emote,
                                  src: e.url,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: MediaQuery.viewPaddingOf(context).bottom),
                ],
              )
            : _errorWidget(),
      Error(:final errMsg) => _errorWidget(errMsg),
    };
  }

  Widget _buildEmoteGrid(
    ThemeData theme,
    List<RecentEmote> entries,
    double size, {
    bool isTextPackage = false,
  }) => GridView.builder(
    physics: platformClampingPhysics,
    padding: const EdgeInsets.only(left: 12, right: 12, bottom: 12),
    gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
      maxCrossAxisExtent: isTextPackage ? 100 : size,
      crossAxisSpacing: 8,
      mainAxisSpacing: 8,
      mainAxisExtent: size,
    ),
    itemCount: entries.length,
    itemBuilder: (context, index) {
      final entry = entries[index];
      final item = entry.emote;
      final isTextEmote = entry.width == null;
      Widget child = Padding(
        padding: const EdgeInsets.all(6),
        child: isTextEmote
            ? Center(
                child: Text(
                  item.text ?? '',
                  overflow: TextOverflow.clip,
                  maxLines: 1,
                ),
              )
            : NetworkImgLayer(
                src: item.url,
                width: size,
                height: size,
                type: ImageType.emote,
                fit: BoxFit.contain,
              ),
      );
      if (!isTextEmote) {
        child = emoteTooltipBuilder(
          enable: true,
          size: 70,
          colorScheme: theme.colorScheme,
          url: item.url,
          emote: item.text,
          triggerMode: kTriggerMode,
          child: child,
        );
      }
      return Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: const BorderRadius.all(Radius.circular(6)),
          onTap: () {
            widget.onChoose(item, entry.width, null);
            _emotePanelController.recordEmote(item, entry.width);
          },
          child: child,
        ),
      );
    },
  );

  Widget _errorWidget([String? errMsg]) => Center(
    child: TextButton.icon(
      onPressed: _emotePanelController.onReload,
      icon: const Icon(Icons.refresh),
      label: Text(errMsg ?? '没有数据'),
    ),
  );
}
