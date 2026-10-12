import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pili_aurora/models/remote/msg/msg_like_detail/card.dart';
import 'package:pili_aurora/models/remote/msg/msg_like_detail/item.dart';
import 'package:pili_aurora/services/messaging/feed.dart';
import 'package:pili_aurora/services/messaging/feed_adapters.dart';
import 'package:pili_aurora/services/messaging/providers.dart';

@immutable
class LikeDetailArgs {
  const LikeDetailArgs({
    required this.cardId,
    required this.uri,
    required this.counts,
  });

  final String cardId;
  final String? uri;
  final int counts;

  @override
  bool operator ==(Object other) =>
      other is LikeDetailArgs &&
      other.cardId == cardId &&
      other.uri == uri &&
      other.counts == counts;

  @override
  int get hashCode => Object.hash(cardId, uri, counts);
}

final likeDetailFeedProvider =
    NotifierProvider.family<
      LikeDetailFeedNotifier,
      FeedSnapshot<MsgLikeDetailItem>,
      LikeDetailArgs
    >(LikeDetailFeedNotifier.new, isAutoDispose: true);

class LikeDetailFeedNotifier extends Notifier<FeedSnapshot<MsgLikeDetailItem>> {
  LikeDetailFeedNotifier(this.args);

  final LikeDetailArgs args;
  late FeedHandle<MsgLikeDetailItem> _handle;

  MsgLikeDetailCard? get card => state.metadata as MsgLikeDetailCard?;

  @override
  FeedSnapshot<MsgLikeDetailItem> build() {
    final session = ref.watch(messagingSessionProvider);
    final handle = FeedHandle<MsgLikeDetailItem>(
      session: session,
      request: (account, cursor) => MessagingFeedAdapters.likeDetail(
        account,
        cursor,
        cardId: args.cardId,
      ),
      idOf: (item) {
        final mid = item.user?.mid;
        return mid == null ? null : '$mid:${item.likeTime ?? 0}';
      },
      maxItems: args.counts,
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
  Future<void> onReload() => refresh();
}
