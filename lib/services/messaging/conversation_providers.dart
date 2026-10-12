import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pili_aurora/services/messaging/conversation.dart';
import 'package:pili_aurora/services/messaging/conversation_adapter.dart';
import 'package:pili_aurora/services/messaging/message_models.dart';
import 'package:pili_aurora/services/messaging/providers.dart';

final Object _conversationCacheKey = Object();

final conversationProvider = Provider.family<Conversation, ConversationTarget>(
  (ref, target) {
    final session = ref.watch(messagingSessionProvider);
    final cache = session.resource(
      _conversationCacheKey,
      () => ConversationCache(
        session: session,
        adapter: const GrpcConversationAdapter(),
      ),
      (cache) => cache.dispose(),
    );
    final lease = cache.acquire(target);
    ref.onDispose(lease.release);
    return lease.conversation;
  },
  isAutoDispose: true,
);

/// 详情页只订阅目标会话时间线；账号切换会重建此 provider 并释放旧缓存租约。
final conversationSnapshotProvider =
    StreamProvider.family<ConversationSnapshot, ConversationTarget>(
      (ref, target) {
        final conversation = ref.watch(conversationProvider(target));
        unawaited(conversation.open());
        return conversation.snapshots;
      },
      isAutoDispose: true,
    );
