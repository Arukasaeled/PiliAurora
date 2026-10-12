import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/services/messaging/conversation.dart';
import 'package:pili_aurora/services/messaging/message_models.dart';
import 'package:pili_aurora/services/messaging/session.dart';
import 'package:pili_aurora/services/messaging/sharing_adapter.dart';

MessageSharing sharingFor(MessagingSession session) => session.resource(
  MessageSharing,
  () => MessageSharing(session: session, cache: conversationCacheFor(session)),
  (_) {},
);

/// 分享卡片与附言共用聊天发送锁，两个写请求均绑定发起分享时的账号。
class MessageSharing {
  const MessageSharing({
    required this.session,
    required this.cache,
    this.adapter = const SharingAdapter(),
  });

  final MessagingSession session;
  final ConversationCache cache;
  final SharingAdapter adapter;

  Future<LoadingState<List<ShareRecipient>>> recentRecipients() =>
      session.run(adapter.recentRecipients);

  Future<OperationResult> send({
    required int receiverId,
    required Map<String, Object?> content,
    String? message,
  }) async {
    if (!session.isActive) {
      return const OperationResult.failure('账号已切换或未登录');
    }
    if (receiverId <= 0) return const OperationResult.failure('请选择有效的收件人');
    final lease = cache.acquire(ConversationTarget(talkerId: receiverId));
    try {
      return await lease.conversation.sendShare(content, message: message);
    } finally {
      lease.release();
    }
  }
}
