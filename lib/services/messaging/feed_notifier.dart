import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/services/messaging/feed.dart';
import 'package:pili_aurora/services/messaging/providers.dart';
import 'package:pili_aurora/services/messaging/session.dart';

abstract class FeedNotifier<T> extends Notifier<FeedSnapshot<T>> {
  FeedHandle<T> createHandle(MessagingSession session);

  late FeedHandle<T> _handle;

  @override
  FeedSnapshot<T> build() {
    final session = ref.watch(messagingSessionProvider);
    final handle = createHandle(session);
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

  Future<void> refresh() => _handle.refresh();
  Future<void> loadMore() => _handle.loadMore();
  Future<LoadingState<void>> remove(Object id) => _handle.remove(id);
}
