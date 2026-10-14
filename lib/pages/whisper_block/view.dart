import 'package:pili_aurora/common/assets.dart';
import 'package:pili_aurora/common/widgets/dialog/dialog.dart';
import 'package:pili_aurora/common/widgets/loading_widget/loading_widget.dart';
import 'package:pili_aurora/common/widgets/scaffold/simple_scaffold.dart';
import 'package:pili_aurora/common/widgets/view_insets_safe_area.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/pages/search/widgets/search_text.dart';
import 'package:pili_aurora/pages/whisper_block/controller.dart';
import 'package:pili_aurora/services/messaging/settings.dart';
import 'package:flutter/services.dart' show LengthLimitingTextInputFormatter;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/svg.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class WhisperBlockPage extends ConsumerStatefulWidget {
  const WhisperBlockPage({
    super.key,
  });

  @override
  ConsumerState<WhisperBlockPage> createState() => _WhisperBlockPageState();
}

class _WhisperBlockPageState extends ConsumerState<WhisperBlockPage> {
  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final snapshot = ref.watch(whisperBlockProvider);
    final controller = ref.read(whisperBlockProvider.notifier);
    return SimpleScaffold(
      appBar: AppBar(title: const Text('消息屏蔽词')),
      body: _buildBody(theme, snapshot, controller),
    );
  }

  Widget _buildBody(
    ThemeData theme,
    KeywordBlockSnapshot snapshot,
    WhisperBlockNotifier controller,
  ) {
    final loadingState = snapshot.loadingState;
    return switch (loadingState) {
      Loading() => m3eLoading,
      Success(:final response) =>
        response != null && response.isNotEmpty
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          '点击屏蔽词即可删除',
                          style: TextStyle(
                            fontSize: 13,
                            color: theme.colorScheme.outline,
                          ),
                        ),
                        if (snapshot.listLimit != null)
                          Text(
                            '${snapshot.count}/${snapshot.listLimit}',
                            style: TextStyle(
                              fontSize: 13,
                              color: theme.colorScheme.outline,
                            ),
                          ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(12),
                      child: Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: response
                            .map(
                              (e) => SearchText(
                                text: e.keyword,
                                onTap: (keyword) {
                                  showConfirmDialog(
                                    context: context,
                                    title: const Text('删除屏蔽词？'),
                                    content: const Text('该屏蔽词将不再生效'),
                                    onConfirm: () async {
                                      final result = await controller.onRemove(
                                        e.keyword,
                                      );
                                      if (result.isSuccess) {
                                        SmartDialog.showToast('删除成功');
                                      } else {
                                        result.toast();
                                      }
                                    },
                                  );
                                },
                              ),
                            )
                            .toList(),
                      ),
                    ),
                  ),
                  Padding(
                    padding: EdgeInsets.only(
                      left: 25,
                      right: 25,
                      bottom: MediaQuery.viewPaddingOf(context).bottom + 10,
                    ),
                    child: FilledButton.tonal(
                      onPressed: () => _onAdd(controller, snapshot.charLimit),
                      child: const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [Icon(Icons.add, size: 22), Text('添加消息屏蔽词')],
                      ),
                    ),
                  ),
                ],
              )
            : Align(
                alignment: const Alignment(0, -0.5),
                child: Column(
                  spacing: 6,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SvgPicture.asset(
                      Assets.themed(Assets.error, Theme.of(context).brightness),
                      height: 156,
                    ),
                    const Text(
                      '还未添加屏蔽词',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Text('添加后，将不再接受包含屏蔽词的消息'),
                    FilledButton.tonal(
                      onPressed: () => _onAdd(controller, snapshot.charLimit),
                      style: FilledButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.add, size: 22),
                          Text('添加'),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
      Error(:final errMsg) => scrollErrorWidget(
        errMsg: errMsg,
        onReload: controller.onReload,
      ),
    };
  }

  void _onAdd(WhisperBlockNotifier controller, int? charLimit) {
    String keyword = '';
    showModalBottomSheet(
      context: context,
      enableDrag: false,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (context) {
        final theme = Theme.of(context);
        return Padding(
          padding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 12) +
              EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom),
          child: ViewInsetsSafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      '添加消息屏蔽词',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    GestureDetector(
                      onTap: Get.back,
                      behavior: HitTestBehavior.opaque,
                      child: Icon(
                        Icons.clear,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextFormField(
                  autofocus: true,
                  maxLength: charLimit,
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: '请输入',
                    visualDensity: .standard,
                    hintStyle: const TextStyle(fontSize: 14),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    border: const OutlineInputBorder(
                      borderSide: BorderSide.none,
                      borderRadius: BorderRadius.all(Radius.circular(25)),
                    ),
                    filled: true,
                    fillColor: theme.colorScheme.onInverseSurface,
                  ),
                  onChanged: (value) => keyword = value,
                  inputFormatters: [LengthLimitingTextInputFormatter(20)],
                ),
                const SizedBox(height: 12),
                FilledButton.tonal(
                  onPressed: () async {
                    if (keyword.isNotEmpty) {
                      final result = await controller.onAdd(keyword);
                      if (result.isSuccess) {
                        Get.back();
                        SmartDialog.showToast('添加成功');
                      } else {
                        result.toast();
                      }
                    }
                  },
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [Icon(Icons.add, size: 22), Text('添加消息屏蔽词')],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
