import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/services/messaging/conversation.dart';
import 'package:pili_aurora/services/messaging/message_models.dart';
import 'package:pili_aurora/services/messaging/session.dart';
import 'package:pili_aurora/services/messaging/sharing.dart';
import 'package:pili_aurora/services/messaging/sharing_adapter.dart';
import 'package:pili_aurora/utils/accounts/account.dart';

import 'messaging_fixtures.dart';

class FakeSharingAdapter extends SharingAdapter {
  final result = Completer<LoadingState<List<ShareRecipient>>>();
  Account? requestedAccount;

  @override
  Future<LoadingState<List<ShareRecipient>>> recentRecipients(
    Account account,
  ) {
    requestedAccount = account;
    return result.future;
  }
}

void main() {
  late MessagingSession session;
  late FakeConversationAdapter adapter;
  late ConversationCache cache;
  late MessageSharing sharing;

  setUp(() {
    session = sessionFixture();
    adapter = FakeConversationAdapter();
    cache = ConversationCache(session: session, adapter: adapter);
    sharing = MessageSharing(session: session, cache: cache);
  });

  tearDown(() {
    cache.dispose();
    session.dispose();
  });

  test('卡片与附言绑定同一账号，更新已有聊天缓存与会话未读', () async {
    final lease = cache.acquire(const ConversationTarget(talkerId: 456));
    addTearDown(lease.release);
    final changes = <MessagingChange>[];
    final subscription = session.changes.listen(changes.add);
    addTearDown(subscription.cancel);
    final payload = <String, Object?>{'source': 5, 'title': 'original'};
    final sent = sharing.send(
      receiverId: 456,
      content: payload,
      message: 'note',
    );
    payload['title'] = 'changed';
    expect((await sent).isSuccess, isTrue);
    expect(
      adapter.sent.map((item) => item.account),
      everyElement(same(session.account)),
    );
    final card = adapter.sent.first.content as StructuredMessageContent;
    expect(card.kind, MessageContentKind.shareV2);
    expect(card.payload['title'], 'original');
    expect((adapter.sent.last.content as TextMessageContent).text, 'note');
    expect(adapter.latestRequests.length, 1);
    adapter.latestRequests.single.complete(Success(page([11])));
    await settle();
    expect(lease.conversation.snapshot.messages.single.sequence, 11);
    expect(changes.single.kind, MessagingChangeKind.unread);
    expect(changes.single.talkerId, 456);
  });

  test('分享与直接聊天共用发送锁，完成后可再次发送', () async {
    final pending = Completer<LoadingState<void>>();
    adapter.sendRequest = () async =>
        adapter.sent.length == 1 ? pending.future : const Success(null);
    final first = sharing.send(
      receiverId: 456,
      content: {'source': '直播'},
      message: 'note',
    );
    final second = await sharing.send(receiverId: 456, content: {'source': 5});
    expect(second.status, OperationStatus.failure);
    final lease = cache.acquire(const ConversationTarget(talkerId: 456));
    addTearDown(lease.release);
    expect(
      (await lease.conversation.sendText('other')).status,
      OperationStatus.failure,
    );
    pending.complete(const Success(null));
    expect((await first).isSuccess, isTrue);
    expect(adapter.sent.length, 2);
    expect(adapter.sent.first.content.kind, MessageContentKind.commonShareCard);
    expect(lease.conversation.snapshot.isSending, isFalse);
    expect(
      (await sharing.send(receiverId: 456, content: {'source': 5})).isSuccess,
      isTrue,
    );
  });

  test('卡片发送途中切换账号，附言不会继续发送', () async {
    final pending = Completer<LoadingState<void>>();
    adapter.sendRequest = () => pending.future;
    final sent = sharing.send(
      receiverId: 456,
      content: {'source': 5},
      message: 'note',
    );
    session.dispose();
    pending.complete(const Success(null));
    expect((await sent).status, OperationStatus.failure);
    expect(adapter.sent.length, 1);
    expect(adapter.latestRequests, isEmpty);
  });

  test('卡片结果未知时保留 unknown，刷新核对且不发送附言', () async {
    adapter.sendRequest = () async => throw DioException(
      requestOptions: RequestOptions(),
      type: DioExceptionType.sendTimeout,
    );
    final result = await sharing.send(
      receiverId: 456,
      content: {'source': 5},
      message: 'note',
    );
    expect(result.status, OperationStatus.unknown);
    expect(adapter.sent.length, 1);
    expect(adapter.latestRequests.length, 1);
  });

  for (final unknown in [false, true]) {
    test('附言${unknown ? '结果未知' : '失败'}保留卡片已发送信息', () async {
      adapter.sendRequest = () async => adapter.sent.length == 1
          ? const Success(null)
          : Error(
              'note failed',
              code: unknown ? messagingUnknownResultCode : null,
            );
      final result = await sharing.send(
        receiverId: 456,
        content: {'source': 5},
        message: 'note',
      );
      expect(
        result.status,
        unknown ? OperationStatus.unknown : OperationStatus.failure,
      );
      expect(result.message, contains('分享内容已发送'));
      expect(adapter.sent.length, 2);
      expect(adapter.latestRequests.length, 1);
    });
  }

  test('最近收件人查询绑定账号，切换后丢弃旧查询结果', () async {
    final recipients = FakeSharingAdapter();
    sharing = MessageSharing(
      session: session,
      cache: cache,
      adapter: recipients,
    );
    final loading = sharing.recentRecipients();
    expect(recipients.requestedAccount, same(session.account));
    session.dispose();
    recipients.result.complete(
      const Success([
        ShareRecipient(id: 456, name: 'test', avatar: ''),
      ]),
    );
    expect(await loading, isA<Error>());
  });
}
