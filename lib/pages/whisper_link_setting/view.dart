import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pili_aurora/common/widgets/dialog/dialog.dart';
import 'package:pili_aurora/common/widgets/dialog/report_member.dart';
import 'package:pili_aurora/common/widgets/pendant_avatar.dart';
import 'package:pili_aurora/common/widgets/scaffold/simple_scaffold.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/remote/msg/im_user_infos/datum.dart';
import 'package:pili_aurora/models/remote/msg/msg_dnd/uid_setting.dart';
import 'package:pili_aurora/pages/whisper_link_setting/controller.dart';
import 'package:pili_aurora/services/messaging/settings.dart';
import 'package:pili_aurora/utils/extension/theme_ext.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class WhisperLinkSettingPage extends ConsumerStatefulWidget {
  const WhisperLinkSettingPage({
    super.key,
    required this.talkerUid,
  });

  final int talkerUid;

  @override
  ConsumerState<WhisperLinkSettingPage> createState() =>
      _WhisperLinkSettingPageState();
}

class _WhisperLinkSettingPageState
    extends ConsumerState<WhisperLinkSettingPage> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final snapshot = ref.watch(whisperLinkSettingsProvider(widget.talkerUid));
    final controller = ref.read(
      whisperLinkSettingsProvider(widget.talkerUid).notifier,
    );
    final divider = Divider(
      height: 12,
      thickness: 12,
      color: theme.colorScheme.outline.withValues(alpha: 0.1),
    );
    final divider2 = Divider(
      height: 1,
      indent: 16,
      color: theme.colorScheme.outline.withValues(alpha: 0.1),
    );
    return SimpleScaffold(
      appBar: AppBar(title: const Text('聊天设置')),
      body: ListView(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewPaddingOf(context).bottom + 100,
        ),
        children: [
          divider,
          _buildUserInfo(theme, divider, snapshot.userState, controller),
          _buildSessionSs(
            theme,
            divider,
            divider2,
            snapshot,
            controller,
          ),
          if (snapshot.sessionSs case Success(:final response))
            _buildBlockItem(
              response.followStatus == 128,
              controller,
            )
          else
            const SizedBox.shrink(),
          divider2,
          ListTile(
            dense: true,
            onTap: () => showMemberReportDialog(
              context,
              name: snapshot.userState.dataOrNull?.firstOrNull?.name,
              mid: widget.talkerUid,
            ),
            title: const Text('举报', style: TextStyle(fontSize: 14)),
            trailing: Icon(
              Icons.keyboard_arrow_right,
              color: theme.colorScheme.outline,
            ),
          ),
          divider,
        ],
      ),
    );
  }

  Widget _buildBlockItem(
    bool isBlocked,
    WhisperLinkSettingsNotifier controller,
  ) {
    return ListTile(
      dense: true,
      onTap: () => _setBlock(controller, isBlocked),
      title: const Text('加入黑名单', style: TextStyle(fontSize: 14)),
      trailing: Transform.scale(
        alignment: Alignment.centerRight,
        scale: 0.8,
        child: Switch(
          value: isBlocked,
          onChanged: (value) => _setBlock(controller, isBlocked),
        ),
      ),
    );
  }

  Widget _buildUserInfo(
    ThemeData theme,
    Widget divider,
    LoadingState<List<ImUserInfosData>?> loadingState,
    WhisperLinkSettingsNotifier controller,
  ) {
    return switch (loadingState) {
      Loading() => const SizedBox.shrink(),
      Success(:final response) =>
        response != null && response.isNotEmpty
            ? Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Builder(
                    builder: (context) {
                      final ImUserInfosData item = response.first;
                      return ListTile(
                        onTap: () => Get.toNamed('/member?mid=${item.mid}'),
                        leading: PendantAvatar(
                          item.face,
                          size: 42,
                          badgeSize: 14,
                          vipStatus: item.vip?.status,
                          pendantImage: item.pendant?.image,
                          officialType: item.official?.type,
                        ),
                        title: Text(
                          item.name!,
                          style: TextStyle(
                            fontSize: 14,
                            color:
                                item.vip?.status != null &&
                                    item.vip!.status > 0 &&
                                    item.vip?.type == 2
                                ? theme.colorScheme.vipColor
                                : null,
                          ),
                        ),
                        subtitle: Text(
                          'UID: ${item.mid}${item.sign?.isNotEmpty == true ? '\n${item.sign}' : ''}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            color: theme.colorScheme.outline,
                          ),
                        ),
                        trailing: Icon(
                          size: 22,
                          Icons.keyboard_arrow_right,
                          color: theme.colorScheme.outline,
                        ),
                      );
                    },
                  ),
                  divider,
                ],
              )
            : const SizedBox.shrink(),
      Error(:final errMsg) => _errWidget(errMsg, controller.getUserInfo),
    };
  }

  Widget _buildSessionSs(
    ThemeData theme,
    Widget divider,
    Widget divider2,
    ConversationSettingsSnapshot snapshot,
    WhisperLinkSettingsNotifier controller,
  ) {
    return switch (snapshot.sessionSs) {
      Loading() => const SizedBox.shrink(),
      Success(:final response) => Builder(
        builder: (context) {
          final subtitleStyle = TextStyle(
            fontSize: 13,
            color: theme.colorScheme.outline,
          );
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (response.showPushSetting == 1)
                ListTile(
                  dense: true,
                  onTap: () => _setPush(
                    controller,
                    response.pushSetting == 0,
                  ),
                  title: const Text('接收消息推送', style: TextStyle(fontSize: 14)),
                  subtitle: Text(
                    '若关闭此开关，你将不再收到该账号的图文消息与稿件推送，但通知类消息不受影响',
                    style: subtitleStyle,
                  ),
                  trailing: Transform.scale(
                    alignment: Alignment.centerRight,
                    scale: 0.8,
                    child: Switch(
                      value: response.pushSetting == 0,
                      onChanged: (value) => _setPush(
                        controller,
                        response.pushSetting == 0,
                      ),
                    ),
                  ),
                ),
              divider2,
              ListTile(
                dense: true,
                onTap: () => _setPin(controller),
                title: const Text('置顶聊天', style: TextStyle(fontSize: 14)),
                trailing: Transform.scale(
                  alignment: Alignment.centerRight,
                  scale: 0.8,
                  child: Switch(
                    value: snapshot.isPinned,
                    onChanged: (value) => _setPin(controller),
                  ),
                ),
              ),
              divider2,
              _buildMuteItem(snapshot.msgDnd, controller),
              divider,
            ],
          );
        },
      ),
      Error(:final errMsg) => _errWidget(errMsg, controller.getSessionSs),
    };
  }

  Widget _buildMuteItem(
    LoadingState<List<UidSetting>?> loadingState,
    WhisperLinkSettingsNotifier controller,
  ) {
    return switch (loadingState) {
      Loading() => const SizedBox.shrink(),
      Success(:final response) =>
        response != null && response.isNotEmpty
            ? ListTile(
                dense: true,
                onTap: () => _setMute(controller, response.first.setting == 1),
                title: const Text('消息免打扰', style: TextStyle(fontSize: 14)),
                trailing: Transform.scale(
                  alignment: Alignment.centerRight,
                  scale: 0.8,
                  child: Switch(
                    value: response.first.setting == 1,
                    onChanged: (value) =>
                        _setMute(controller, response.first.setting == 1),
                  ),
                ),
              )
            : const SizedBox.shrink(),
      Error(:final errMsg) => _errWidget(errMsg, controller.getMsgDnd),
    };
  }

  Future<void> _setPush(
    WhisperLinkSettingsNotifier controller,
    bool receivesPush,
  ) async {
    Future<void> update() async {
      final result = await controller.setPush(receivesPush);
      if (!result.isSuccess) result.toast();
    }

    if (receivesPush) {
      showConfirmDialog(
        context: context,
        title: const Text('确认关闭内容推送吗？'),
        content: const Text(
          '若关闭此开关，你将不再收到该账号的图文消息与稿件推送，但通知类消息不受影响',
        ),
        onConfirm: update,
      );
    } else {
      await update();
    }
  }

  Future<void> _setPin(WhisperLinkSettingsNotifier controller) async {
    final result = await controller.setPin();
    if (!result.isSuccess) result.toast();
  }

  Future<void> _setMute(
    WhisperLinkSettingsNotifier controller,
    bool isMuted,
  ) async {
    final result = await controller.setMute(isMuted);
    if (!result.isSuccess) result.toast();
  }

  Future<void> _setBlock(
    WhisperLinkSettingsNotifier controller,
    bool isBlocked,
  ) async {
    Future<void> update() async {
      final result = await controller.setBlock(isBlocked);
      if (!result.isSuccess) result.toast();
    }

    if (isBlocked) {
      await update();
    } else {
      showConfirmDialog(
        context: context,
        title: const Text('确认拉黑该用户'),
        content: const Text(
          '加入黑名单后，将自动解除关注关系和对该用户的合集订阅关系，禁止该用户与我互动或查看我的空间',
        ),
        onConfirm: update,
      );
    }
  }

  Widget _errWidget(String? errMsg, Future<void> Function() onTap) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Text(
          errMsg ?? '',
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}
