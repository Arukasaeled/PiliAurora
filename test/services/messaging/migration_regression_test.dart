import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/http/api.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/remote/msg/msg_sys/data.dart';
import 'package:pili_aurora/services/messaging/conversation.dart';
import 'package:pili_aurora/services/messaging/feed.dart';
import 'package:pili_aurora/services/messaging/feed_adapters.dart';
import 'package:pili_aurora/services/messaging/message_models.dart';
import 'package:pili_aurora/services/messaging/session.dart';
import 'package:pili_aurora/utils/accounts/account.dart';

import 'messaging_test.dart' as helpers;

void main() {
  test('发送成功后的刷新应查询发送后的记录', () async {
    final session = helpers.scope();
    final adapter = helpers.FakeConversationAdapter();
    final chat = Conversation(
      session: session,
      target: const ConversationTarget(talkerId: 456),
      adapter: adapter,
    );
    addTearDown(chat.dispose);
    addTearDown(session.dispose);
    final initial = chat.open();
    expect((await chat.sendText('new message')).isSuccess, isTrue);
    final afterSend = chat.refresh(retryFailedAcknowledgement: false);
    final queryCount = adapter.latestRequests.length;
    adapter.latestRequests.first.complete(Success(helpers.page([10])));
    if (queryCount > 1) {
      adapter.latestRequests.last.complete(Success(helpers.page([11, 10])));
    }
    await initial;
    await afterSend;
    expect(queryCount, 2, reason: '发送前的查询不能保证包含已发送的新消息');
    expect(chat.snapshot.messages.first.sequence, 11);
  });

  test('历史分页应保留最新页使用的表情映射', () async {
    final session = helpers.scope();
    final adapter = helpers.FakeConversationAdapter();
    final chat = Conversation(
      session: session,
      target: const ConversationTarget(talkerId: 456),
      adapter: adapter,
    );
    addTearDown(chat.dispose);
    addTearDown(session.dispose);
    final initial = chat.open();
    adapter.latestRequests.single.complete(
      Success(
        ConversationPage(
          messages: [helpers.message(10)],
          hasOlder: true,
          cursor: 10,
          emotions: const [
            EmotionSticker(text: '[new]', url: 'new.png', size: 22),
          ],
        ),
      ),
    );
    await initial;
    final older = chat.loadOlder();
    adapter.olderRequests.single.complete(
      Success(
        ConversationPage(
          messages: [helpers.message(9)],
          hasOlder: false,
          cursor: 9,
          emotions: const [
            EmotionSticker(text: '[old]', url: 'old.png', size: 22),
          ],
        ),
      ),
    );
    await older;
    expect(chat.snapshot.messages.length, 2);
    expect(
      chat.snapshot.emotions.map((item) => item.text),
      containsAll(['[new]', '[old]']),
    );
  });

  test('系统消息已读确认超时应保留读取成功的数据', () async {
    final session = MessagingSession(
      account: LoginAccount(
        BiliCookieJar.fromJson({
          'DedeUserID': '123',
          'bili_jct': 'test-fixture',
        }),
        null,
        null,
      ),
      key: (mid: 123, generation: 1),
    );
    addTearDown(session.dispose);
    Request.dio = Dio(BaseOptions(baseUrl: 'https://example.invalid'));
    var readDelivered = false;
    var acknowledgementAttempts = 0;
    var unreadChanges = 0;
    final unreadConfirmed = Completer<void>();
    final subscription = session.changes.listen((change) {
      if (change.kind == MessagingChangeKind.unread) {
        unreadChanges++;
        unreadConfirmed.complete();
      }
    });
    addTearDown(subscription.cancel);
    final acknowledgement = Completer<void>();
    final acknowledgementStarted = Completer<void>();
    Request.dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.path == Api.msgSysNotify) {
            readDelivered = true;
            handler.resolve(
              Response(
                requestOptions: options,
                data: {
                  'code': 0,
                  'data': [
                    {'id': 1, 'cursor': 1, 'title': 'test', 'content': 'test'},
                  ],
                },
              ),
            );
          } else {
            expect(options.path, Api.msgSysUpdateCursor);
            acknowledgementAttempts++;
            if (acknowledgementAttempts == 1) {
              acknowledgementStarted.complete();
              acknowledgement.future.then(
                (_) => handler.reject(
                  DioException(
                    requestOptions: options,
                    type: DioExceptionType.receiveTimeout,
                  ),
                ),
              );
            } else {
              handler.resolve(
                Response(requestOptions: options, data: {'code': 0}),
              );
            }
          }
        },
      ),
    );
    final feed = FeedHandle<MsgSysItem>(
      session: session,
      request: MessagingFeedAdapters.system,
      idOf: (item) => item.id,
      acknowledge: MessagingFeedAdapters.acknowledgeSystem,
      notifyUnreadOnRefresh: true,
    );
    addTearDown(feed.dispose);
    await feed.refresh();
    await acknowledgementStarted.future.timeout(const Duration(seconds: 1));
    expect(readDelivered, isTrue);
    expect(acknowledgementAttempts, 1);
    expect(feed.state.value.loadingState.dataOrNull?.single.id, 1);
    acknowledgement.complete();
    await helpers.settle();
    expect(feed.state.value.loadingState.dataOrNull?.single.id, 1);
    expect(unreadChanges, 0);
    await feed.refresh();
    await unreadConfirmed.future.timeout(const Duration(seconds: 1));
    expect(acknowledgementAttempts, 2);
    expect(unreadChanges, 1);
  });
}
