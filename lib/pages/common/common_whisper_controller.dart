import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/services/messaging/session_models.dart';
import 'package:pili_aurora/services/messaging/sessions.dart';

abstract class CommonWhisperController {
  const CommonWhisperController({
    required this.sessions,
    required this.folder,
  });

  final Sessions sessions;
  final SessionFolder folder;

  bool get isActive => sessions.scope.isActive;

  Future<LoadingState<void>> onRefresh() => sessions.list(folder).refresh();

  Future<LoadingState<void>> onLoadMore() => sessions.list(folder).loadMore();

  Future<LoadingState<void>> onReload() => onRefresh();

  Future<LoadingState<void>> onRemove(SessionKey key) => sessions.remove(key);

  Future<LoadingState<void>> onSetTop(
    SessionKey key, {
    required bool isPinned,
  }) => sessions.setPinned(key, isPinned: isPinned);

  Future<LoadingState<void>> onSetMute(
    SessionKey key, {
    required bool isMuted,
  }) => sessions.setMuted(key, isMuted: isMuted);

  Future<LoadingState<void>> onMarkRead(SessionKey key) =>
      sessions.markRead(key);

  Future<LoadingState<void>> onClearUnread() => sessions.clearUnread(folder);

  Future<LoadingState<void>> onDeleteList() => sessions.deleteList(folder);
}
