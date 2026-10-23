import 'package:pili_aurora/models/common/msg/msg_unread_type.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pili_aurora/models/remote/msg/msg_at/item.dart';
import 'package:pili_aurora/services/messaging/feed.dart';
import 'package:pili_aurora/services/messaging/feed_adapters.dart';
import 'package:pili_aurora/services/messaging/feed_notifier.dart';
import 'package:pili_aurora/services/messaging/session.dart';

final atMeFeedProvider =
    NotifierProvider<AtMeFeedNotifier, FeedSnapshot<MsgAtItem>>(
      AtMeFeedNotifier.new,
      isAutoDispose: true,
    );

class AtMeFeedNotifier extends FeedNotifier<MsgAtItem> {
  @override
  FeedHandle<MsgAtItem> createHandle(MessagingSession session) => FeedHandle(
    session: session,
    request: MessagingFeedAdapters.at,
    idOf: (item) => item.id,
    delete: MessagingFeedAdapters.deleteAt,
    notifyUnreadOnRefresh: true,
    readType: MsgUnReadType.at,
  );
}
