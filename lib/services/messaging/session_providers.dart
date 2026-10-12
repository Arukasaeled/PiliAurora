import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pili_aurora/services/messaging/providers.dart'
    show messagingSessionProvider, snapshotProvider, SnapshotNotifier;

import 'package:pili_aurora/services/messaging/session_models.dart';
import 'package:pili_aurora/services/messaging/sessions.dart';

final sessionsProvider = Provider<Sessions>((ref) {
  final scope = ref.watch(messagingSessionProvider);
  return sessionsFor(scope);
});

final sessionListHandleProvider =
    Provider.family<SessionListHandle, SessionFolder>(
      (ref, folder) => ref.watch(sessionsProvider).list(folder),
    );

final Map<
  SessionFolder,
  NotifierProvider<SnapshotNotifier<SessionListSnapshot>, SessionListSnapshot>
>
_sessionSnapshots = {};

NotifierProvider<SnapshotNotifier<SessionListSnapshot>, SessionListSnapshot>
sessionListSnapshotProvider(SessionFolder folder) =>
    _sessionSnapshots.putIfAbsent(
      folder,
      () => snapshotProvider<SessionListSnapshot>((ref) {
        final handle = ref.watch(sessionListHandleProvider(folder));
        unawaited(handle.loadIfNeeded());
        return handle.state;
      }),
    );
