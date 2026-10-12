import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/services/messaging/providers.dart';
import 'package:pili_aurora/services/messaging/settings.dart';

final whisperBlockProvider =
    NotifierProvider<WhisperBlockNotifier, KeywordBlockSnapshot>(
      WhisperBlockNotifier.new,
      isAutoDispose: true,
    );

class WhisperBlockNotifier extends Notifier<KeywordBlockSnapshot> {
  late KeywordBlockHandle _handle;

  @override
  KeywordBlockSnapshot build() {
    final session = ref.watch(messagingSessionProvider);
    final handle = KeywordBlockHandle(session: session);
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
  Future<LoadingState<void>> onAdd(String keyword) => _handle.add(keyword);
  Future<LoadingState<void>> onRemove(String keyword) =>
      _handle.remove(keyword);
}
