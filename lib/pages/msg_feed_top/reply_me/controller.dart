import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pili_aurora/models/remote/msg/msg_reply/item.dart';
import 'package:pili_aurora/services/messaging/feed.dart';
import 'package:pili_aurora/services/messaging/feed_adapters.dart';
import 'package:pili_aurora/services/messaging/feed_notifier.dart';
import 'package:pili_aurora/services/messaging/session.dart';

final replyMeFeedProvider =
    NotifierProvider<ReplyMeFeedNotifier, FeedSnapshot<MsgReplyItem>>(
      ReplyMeFeedNotifier.new,
      isAutoDispose: true,
    );

class ReplyMeFeedNotifier extends FeedNotifier<MsgReplyItem> {
  @override
  FeedHandle<MsgReplyItem> createHandle(MessagingSession session) => FeedHandle(
    session: session,
    request: MessagingFeedAdapters.reply,
    idOf: (item) => item.id,
    delete: MessagingFeedAdapters.deleteReply,
    notifyUnreadOnRefresh: true,
  );
}
