enum MessageContentKind {
  text,
  image,
  customFace,
  notify,
  pictureCard,
  tip,
  shareV2,
  videoCard,
  articleCard,
  commonShareCard,
  legacyCard,
  unknown,
}

sealed class MessageContent {
  const MessageContent();
  MessageContentKind get kind;
}

final class TextMessageContent extends MessageContent {
  const TextMessageContent(this.text);
  final String text;
  @override
  MessageContentKind get kind => MessageContentKind.text;
}

final class ImageMessageContent extends MessageContent {
  const ImageMessageContent({
    required this.url,
    required this.width,
    required this.height,
    this.imageType = 'jpg',
    this.original = 1,
    this.size = 0,
    this.customFace = false,
  });

  final String url;
  final double width;
  final double height;
  final String imageType;
  final int original;
  final int size;
  final bool customFace;

  @override
  MessageContentKind get kind =>
      customFace ? MessageContentKind.customFace : MessageContentKind.image;
}

/// 卡片结构由服务端控制且会独立演进，因此保留字段形式并在进入界面前校验、冻结。
final class StructuredMessageContent extends MessageContent {
  StructuredMessageContent(this.kind, Map<String, Object?> payload)
    : payload = _freezeMap(payload);

  @override
  final MessageContentKind kind;
  final Map<String, Object?> payload;
}

final class UnknownMessageContent extends MessageContent {
  const UnknownMessageContent({required this.messageType, required this.raw});
  final int messageType;
  final String raw;
  @override
  MessageContentKind get kind => MessageContentKind.unknown;
}

final class EmotionSticker {
  const EmotionSticker({
    required this.text,
    required this.url,
    required this.size,
  });
  final String text;
  final String url;
  final double size;
}

final class Message {
  const Message({
    required this.id,
    required this.messageKey,
    required this.sequence,
    required this.senderId,
    required this.timestamp,
    required this.type,
    required this.source,
    required this.content,
    this.recalled = false,
    this.recallTargetKey,
  });

  final String id;
  final int messageKey;
  final int sequence;
  final int senderId;
  final int timestamp;
  final int type;
  final int source;
  final MessageContent content;
  final bool recalled;

  /// 仅协议撤回事件携带此值；合并时消费，不传给界面组件。
  final int? recallTargetKey;

  Message copyWith({bool? recalled}) => Message(
    id: id,
    messageKey: messageKey,
    sequence: sequence,
    senderId: senderId,
    timestamp: timestamp,
    type: type,
    source: source,
    content: content,
    recalled: recalled ?? this.recalled,
    recallTargetKey: recallTargetKey,
  );
}

Map<String, Object?> _freezeMap(Map<String, Object?> source) =>
    Map<String, Object?>.unmodifiable({
      for (final entry in source.entries) entry.key: _freezeValue(entry.value),
    });

Object? _freezeValue(Object? value) => switch (value) {
  Map map => Map<String, Object?>.unmodifiable({
    for (final entry in map.entries)
      if (entry.key is String) entry.key as String: _freezeValue(entry.value),
  }),
  List list => List<Object?>.unmodifiable(list.map(_freezeValue)),
  _ => value,
};

final class ConversationTarget {
  const ConversationTarget({required this.talkerId, this.sessionType = 1});
  final int talkerId;
  final int sessionType;

  @override
  bool operator ==(Object other) =>
      other is ConversationTarget &&
      other.talkerId == talkerId &&
      other.sessionType == sessionType;

  @override
  int get hashCode => Object.hash(talkerId, sessionType);
}

final class ConversationPage {
  ConversationPage({
    required Iterable<Message> messages,
    required this.hasOlder,
    required this.cursor,
    Iterable<EmotionSticker> emotions = const [],
  }) : messages = List.unmodifiable(messages),
       emotions = List.unmodifiable(emotions);

  final List<Message> messages;
  final bool hasOlder;
  final int? cursor;
  final List<EmotionSticker> emotions;
}

enum ConversationPhase {
  initial,
  loading,
  ready,
  refreshing,
  loadingOlder,
  failed,
}

final class ConversationSnapshot {
  ConversationSnapshot({
    required this.phase,
    required Iterable<Message> messages,
    required this.hasOlder,
    required this.historyCursor,
    required this.highestRenderedSequence,
    required this.acknowledgedSequence,
    required this.error,
    Iterable<EmotionSticker> emotions = const [],
    Iterable<MessageOperation> operations = const [],
    this.isSending = false,
  }) : messages = List.unmodifiable(messages),
       emotions = List.unmodifiable(emotions),
       operations = List.unmodifiable(operations);

  factory ConversationSnapshot.initial() => ConversationSnapshot(
    phase: ConversationPhase.initial,
    messages: const [],
    hasOlder: true,
    historyCursor: null,
    highestRenderedSequence: 0,
    acknowledgedSequence: 0,
    error: null,
  );

  final ConversationPhase phase;
  final List<Message> messages;
  final bool hasOlder;
  final int? historyCursor;
  final int highestRenderedSequence;
  final int acknowledgedSequence;
  final String? error;
  final List<EmotionSticker> emotions;
  final List<MessageOperation> operations;
  final bool isSending;
}

enum OperationStatus { sending, success, failure, unknown }

final class MessageOperation {
  const MessageOperation({
    required this.id,
    required this.status,
    required this.kind,
  });

  final String id;
  final OperationStatus status;
  final String kind;

  MessageOperation copyWith({OperationStatus? status}) => MessageOperation(
    id: id,
    status: status ?? this.status,
    kind: kind,
  );
}

final class OperationResult {
  const OperationResult(
    this.status, {
    this.message,
    this.operationId,
  });
  const OperationResult.success({String? operationId})
    : this(OperationStatus.success, operationId: operationId);
  const OperationResult.failure([String? message, String? operationId])
    : this(OperationStatus.failure, message: message, operationId: operationId);
  const OperationResult.unknown([String? message, String? operationId])
    : this(OperationStatus.unknown, message: message, operationId: operationId);

  final OperationStatus status;
  final String? message;
  final String? operationId;
  bool get isSuccess => status == OperationStatus.success;
}

final class UploadedMessageImage {
  const UploadedMessageImage({
    required this.url,
    required this.width,
    required this.height,
    required this.size,
    required this.imageType,
  });

  final String url;
  final int width;
  final int height;
  final int size;
  final String imageType;
}
