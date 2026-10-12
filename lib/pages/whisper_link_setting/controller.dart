import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/services/messaging/providers.dart';
import 'package:pili_aurora/services/messaging/settings.dart';

final whisperLinkSettingsProvider =
    NotifierProvider.family<
      WhisperLinkSettingsNotifier,
      ConversationSettingsSnapshot,
      int
    >(WhisperLinkSettingsNotifier.new, isAutoDispose: true);

class WhisperLinkSettingsNotifier
    extends Notifier<ConversationSettingsSnapshot> {
  WhisperLinkSettingsNotifier(this.talkerUid);

  final int talkerUid;
  late ConversationSettingsHandle _handle;

  @override
  ConversationSettingsSnapshot build() {
    final session = ref.watch(messagingSessionProvider);
    final handle = ConversationSettingsHandle(
      session: session,
      talkerUid: talkerUid,
    );
    _handle = handle;
    void changed() => state = handle.state.value;
    handle.state.addListener(changed);
    ref.onDispose(() {
      handle.state.removeListener(changed);
      handle.dispose();
    });
    unawaited(handle.refresh());
    return handle.state.value;
  }

  Future<void> getUserInfo() => _handle.getUserInfo();
  Future<void> getSessionSs() => _handle.getSessionSs();
  Future<void> getMsgDnd() => _handle.getMsgDnd();

  Future<LoadingState<void>> setPush(bool receivesPush) =>
      _handle.setPush(receivesPush);
  Future<LoadingState<void>> setPin() => _handle.setPinned();
  Future<LoadingState<void>> setMute(bool isMuted) => _handle.setMuted(isMuted);
  Future<LoadingState<void>> setBlock(bool isBlocked) =>
      _handle.setBlocked(isBlocked);
}
