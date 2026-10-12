import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pili_aurora/services/messaging/session.dart';

final messagingSessionProvider =
    NotifierProvider<MessagingSessionNotifier, MessagingSession>(
      MessagingSessionNotifier.new,
    );

class MessagingSessionNotifier extends Notifier<MessagingSession> {
  @override
  MessagingSession build() {
    final messages = Messaging.instance;
    final session = messages.session;
    void changed() => state = messages.current.value;
    messages.current.addListener(changed);
    ref.onDispose(() => messages.current.removeListener(changed));
    return session;
  }
}

/// 将业务快照转成同步订阅，所有权仍由业务句柄或账号 Session 管理。
NotifierProvider<SnapshotNotifier<T>, T> snapshotProvider<T>(
  ValueListenable<T> Function(Ref ref) source,
) => NotifierProvider<SnapshotNotifier<T>, T>(
  () => SnapshotNotifier(source),
  isAutoDispose: true,
);

class SnapshotNotifier<T> extends Notifier<T> {
  SnapshotNotifier(this.source);
  final ValueListenable<T> Function(Ref ref) source;
  @override
  T build() {
    final listenable = source(ref);
    void changed() => state = listenable.value;
    listenable.addListener(changed);
    ref.onDispose(() => listenable.removeListener(changed));
    return listenable.value;
  }
}
