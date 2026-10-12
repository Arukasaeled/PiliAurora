import 'package:flutter/foundation.dart' show immutable;

enum SessionFolder {
  home,
  unknown,
  unfollowed,
  stranger,
  dustbin,
  group,
  huahuo,
  ai,
  customer,
}

enum SessionKeyKind { private, group, fold, system, customer, unknown }

enum SessionKind {
  unknown(0),
  private(1),
  group(2),
  groupFold(3),
  unfollowed(4),
  stranger(5),
  dustbin(6),
  customerFold(7),
  system(8),
  aiFold(9),
  customerAccount(10);

  const SessionKind(this.code);

  final int code;

  static SessionKind fromCode(int code) => SessionKind.values.firstWhere(
    (kind) => kind.code == code,
    orElse: () => SessionKind.unknown,
  );
}

@immutable
class SessionKey {
  const SessionKey({
    required this.kind,
    required this.primary,
    this.secondary = 0,
  });

  final SessionKeyKind kind;
  final int primary;
  final int secondary;

  @override
  bool operator ==(Object other) =>
      other is SessionKey &&
      other.kind == kind &&
      other.primary == primary &&
      other.secondary == secondary;

  @override
  int get hashCode => Object.hash(kind, primary, secondary);
}

sealed class SessionTarget {
  const SessionTarget();
}

@immutable
final class PrivateSessionTarget extends SessionTarget {
  const PrivateSessionTarget(this.talkerId);

  final int talkerId;
}

@immutable
final class GroupSessionTarget extends SessionTarget {
  const GroupSessionTarget(this.groupId);

  final int groupId;
}

@immutable
final class FoldSessionTarget extends SessionTarget {
  const FoldSessionTarget({required this.typeCode, this.folder});

  final int typeCode;
  final SessionFolder? folder;

  SessionKind get kind => SessionKind.fromCode(typeCode);
}

@immutable
final class SystemSessionTarget extends SessionTarget {
  const SystemSessionTarget(this.typeCode);

  final int typeCode;

  SessionKind get kind => SessionKind.fromCode(typeCode);
}

@immutable
final class CustomerSessionTarget extends SessionTarget {
  const CustomerSessionTarget({required this.shopId, required this.shopType});

  final int shopId;
  final int shopType;
}

@immutable
class SessionAvatar {
  const SessionAvatar({
    required this.url,
    this.pendantUrl,
    this.officialType,
    this.mid,
    this.vipStatus,
    this.vipType,
  });

  final String url;
  final String? pendantUrl;
  final int? officialType;
  final int? mid;
  final int? vipStatus;
  final int? vipType;
}

enum SessionUnreadStyle { none, dot, number, unknown }

@immutable
class SessionUnread {
  const SessionUnread({
    this.style = SessionUnreadStyle.none,
    this.number = 0,
    this.numberLabel = '',
  });

  final SessionUnreadStyle style;
  final int number;
  final String numberLabel;

  bool get isUnread => style != SessionUnreadStyle.none;

  const SessionUnread.cleared()
    : style = SessionUnreadStyle.none,
      number = 0,
      numberLabel = '';
}

@immutable
class SessionEntry {
  const SessionEntry({
    required this.key,
    required this.target,
    required this.name,
    required this.summary,
    required this.timestampMicros,
    required this.unread,
    required this.isPinned,
    required this.isMuted,
    required this.avatar,
    required this.isLive,
    this.userLabel,
    this.sequenceNumber = 0,
  });

  final SessionKey key;
  final SessionTarget target;
  final String name;
  final String summary;
  final int? timestampMicros;
  final SessionUnread unread;
  final bool isPinned;
  final bool isMuted;
  final SessionAvatar avatar;
  final bool isLive;
  final String? userLabel;
  final int sequenceNumber;

  SessionEntry copyWith({
    String? name,
    String? summary,
    int? timestampMicros,
    SessionUnread? unread,
    bool? isPinned,
    bool? isMuted,
    SessionAvatar? avatar,
    bool? isLive,
    String? userLabel,
    int? sequenceNumber,
  }) => SessionEntry(
    key: key,
    target: target,
    name: name ?? this.name,
    summary: summary ?? this.summary,
    timestampMicros: timestampMicros ?? this.timestampMicros,
    unread: unread ?? this.unread,
    isPinned: isPinned ?? this.isPinned,
    isMuted: isMuted ?? this.isMuted,
    avatar: avatar ?? this.avatar,
    isLive: isLive ?? this.isLive,
    userLabel: userLabel ?? this.userLabel,
    sequenceNumber: sequenceNumber ?? this.sequenceNumber,
  );

  SessionEntry clearUnread() => copyWith(unread: const SessionUnread.cleared());
}

enum SessionMenuAction {
  messageSettings,
  readAll,
  clearList,
  upHelper,
  contacts,
  fansGroupHelper,
  other,
}

@immutable
class SessionMenuItem {
  const SessionMenuItem({
    required this.title,
    required this.iconUrl,
    required this.url,
    required this.action,
    this.hasRedDot = false,
  });

  final String title;
  final String iconUrl;
  final String url;
  final SessionMenuAction action;
  final bool hasRedDot;
}

enum SessionListPhase { idle, loading, refreshing, loadingMore, ready, failed }

@immutable
class SessionListSnapshot {
  SessionListSnapshot({
    required Iterable<SessionEntry> entries,
    required this.phase,
    required this.hasMore,
    required this.generation,
    this.error,
    Iterable<SessionMenuItem> menuItems = const [],
    Iterable<SessionMenuItem> outsideItems = const [],
  }) : entries = List.unmodifiable(entries),
       menuItems = List.unmodifiable(menuItems),
       outsideItems = List.unmodifiable(outsideItems);

  final List<SessionEntry> entries;
  final SessionListPhase phase;
  final bool hasMore;
  final int generation;
  final String? error;
  final List<SessionMenuItem> menuItems;
  final List<SessionMenuItem> outsideItems;

  bool get isInitialLoading =>
      phase == SessionListPhase.loading && entries.isEmpty;
}
