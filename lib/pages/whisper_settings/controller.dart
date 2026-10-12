import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pili_aurora/grpc/bilibili/app/im/v1.pb.dart'
    show IMSettingType, Setting;
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/services/messaging/providers.dart';
import 'package:pili_aurora/services/messaging/settings.dart';

final whisperSettingsProvider =
    NotifierProvider.family<
      WhisperSettingsNotifier,
      WhisperSettingsSnapshot,
      IMSettingType
    >(WhisperSettingsNotifier.new, isAutoDispose: true);

class WhisperSettingsNotifier extends Notifier<WhisperSettingsSnapshot> {
  WhisperSettingsNotifier(this.type);

  final IMSettingType type;
  late WhisperSettingsHandle _handle;

  @override
  WhisperSettingsSnapshot build() {
    final session = ref.watch(messagingSessionProvider);
    final handle = WhisperSettingsHandle(session: session, type: type);
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

  Future<void> onReload() => _handle.refresh();

  Future<LoadingState<void>> setSetting(int key, Setting setting) =>
      _handle.setSetting(key, setting);

  void mergeSubSettings(int parentKey, Map<int, Setting> settings) =>
      _handle.mergeSubSettings(parentKey, settings);
}
