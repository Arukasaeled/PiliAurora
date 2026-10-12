import 'package:pili_aurora/common/widgets/dialog/dialog.dart';
import 'package:pili_aurora/grpc/bilibili/app/im/v1.pb.dart' show IMSettingType;
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/pages/common/common_whisper_controller.dart';
import 'package:pili_aurora/pages/contact/view.dart';
import 'package:pili_aurora/pages/whisper_settings/view.dart';
import 'package:pili_aurora/services/messaging/session_models.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:material_ui/material_ui.dart';

extension SessionMenuActionExt on SessionMenuAction {
  Icon get icon => switch (this) {
    SessionMenuAction.messageSettings => const Icon(Icons.settings, size: 20),
    SessionMenuAction.readAll => const Icon(
      Icons.cleaning_services,
      size: 20,
    ),
    SessionMenuAction.clearList => const Icon(
      Icons.delete_forever_outlined,
      size: 20,
    ),
    SessionMenuAction.upHelper => const Icon(Icons.live_tv, size: 20),
    SessionMenuAction.contacts => const Icon(
      Icons.account_box_outlined,
      size: 20,
    ),
    SessionMenuAction.fansGroupHelper => const Icon(
      Icons.notifications_none,
      size: 20,
    ),
    SessionMenuAction.other => const Icon(MdiIcons.circleMedium, size: 20),
  };

  void action({
    required BuildContext context,
    required CommonWhisperController controller,
    required SessionMenuItem item,
  }) {
    switch (this) {
      case SessionMenuAction.readAll:
        showConfirmDialog(
          context: context,
          title: const Text('一键已读'),
          content: const Text('是否清除全部新消息提醒？'),
          onConfirm: () => _complete(
            context,
            controller,
            controller.onClearUnread(),
            success: '已标记为已读',
          ),
        );
      case SessionMenuAction.clearList:
        showConfirmDialog(
          context: context,
          title: const Text('清空列表'),
          content: const Text('清空后所有消息将被删除，无法恢复'),
          onConfirm: () => _complete(
            context,
            controller,
            controller.onDeleteList(),
            success: '列表已清空',
          ),
        );
      case SessionMenuAction.messageSettings:
        Get.to(
          const WhisperSettingsPage(
            imSettingType: IMSettingType.SETTING_TYPE_NEED_ALL,
          ),
        );
      case SessionMenuAction.upHelper:
        final id = RegExp(r'/(\d{3,})').firstMatch(item.url)?.group(1);
        if (id != null) {
          final talkerId = int.tryParse(id);
          if (talkerId == null) return;
          Get.toNamed(
            '/whisperDetail',
            arguments: {
              'talkerId': talkerId,
              'name': item.title,
              'face': switch (talkerId) {
                844424930131966 => 'https://message.biliimg.com/bfs/im/489a63efadfb202366c2f88853d2217b5ddc7a13.png',
                844424930131964 => 'https://i0.hdslb.com/bfs/im_new/58eda511672db078466e7ab8db22a95c1503684976.png',
                _ => item.iconUrl,
              },
            },
          );
        }
      case SessionMenuAction.contacts:
        Get.to(const ContactPage(isFromSelect: false));
      case SessionMenuAction.fansGroupHelper:
        SmartDialog.showToast('TODO: ${item.title}');
      case SessionMenuAction.other:
        SmartDialog.showToast('TODO: ${item.title}');
    }
  }

  Future<void> _complete(
    BuildContext context,
    CommonWhisperController controller,
    Future<LoadingState<void>> result, {
    required String success,
  }) async {
    final response = await result;
    if (!context.mounted || !controller.isActive) return;
    if (response.isSuccess) {
      SmartDialog.showToast(success);
    } else {
      await response.toast();
    }
  }
}
