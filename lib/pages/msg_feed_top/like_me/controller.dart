import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/services/messaging/feed.dart';
import 'package:pili_aurora/services/messaging/feed_adapters.dart';
import 'package:pili_aurora/services/messaging/providers.dart';

final likeMeFeedProvider =
    NotifierProvider<LikeMeFeedNotifier, LikeFeedSnapshot>(
      LikeMeFeedNotifier.new,
      isAutoDispose: true,
    );

class LikeMeFeedNotifier extends Notifier<LikeFeedSnapshot> {
  late LikeFeedHandle _handle;

  @override
  LikeFeedSnapshot build() {
    final session = ref.watch(messagingSessionProvider);
    final handle = LikeFeedHandle(
      session: session,
      request: MessagingFeedAdapters.like,
      delete: MessagingFeedAdapters.deleteLike,
      setNoticeRequest: MessagingFeedAdapters.setLikeNotice,
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

  Future<void> refresh() => _handle.refresh();
  Future<void> loadMore() => _handle.loadMore();

  Future<LoadingState<void>> remove(Object id, {required bool latest}) =>
      _handle.remove(id, latest: latest);

  Future<LoadingState<void>> setNotice(Object id, bool isNotice) =>
      _handle.setNotice(id, isNotice);
}
