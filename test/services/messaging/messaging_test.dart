import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pili_aurora/services/messaging/providers.dart';
import 'package:pili_aurora/services/messaging/feed_notifier.dart';
import 'package:pili_aurora/models/remote/msg/msg_like/item.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/common/msg/msg_unread_type.dart';
import 'package:pili_aurora/services/messaging/conversation.dart';
import 'package:pili_aurora/services/messaging/feed.dart';
import 'package:pili_aurora/services/messaging/message_models.dart';
import 'package:pili_aurora/services/messaging/overview.dart';
import 'package:pili_aurora/services/messaging/session.dart';
import 'package:pili_aurora/services/messaging/session_adapter.dart';
import 'package:pili_aurora/services/messaging/session_models.dart';
import 'package:pili_aurora/services/messaging/session_providers.dart';
import 'package:pili_aurora/services/messaging/sessions.dart';
import 'package:pili_aurora/utils/accounts/account.dart';

import 'messaging_fixtures.dart';

class TestSessionNotifier extends MessagingSessionNotifier {
  TestSessionNotifier(this.session);
  final MessagingSession session;
  @override
  MessagingSession build() => session;

  void replace(MessagingSession session) => state = session;
}

class FakeSessionAdapter extends SessionAdapter {
  final requests = <Completer<LoadingState<SessionPageResult>>>[];

  @override
  Future<LoadingState<SessionPageResult>> loadPage({
    required Account account,
    required SessionFolder folder,
    SessionPageCursor? cursor,
  }) {
    final request = Completer<LoadingState<SessionPageResult>>();
    requests.add(request);
    return request.future;
  }

  @override
  Future<LoadingState<void>> markRead({
    required Account account,
    required int talkerId,
  }) async => const Success(null);

  @override
  Future<LoadingState<void>> remove({
    required Account account,
    required int talkerId,
  }) async => const Success(null);
}

SessionEntry sessionEntry(int id) => SessionEntry(
  key: SessionKey(kind: SessionKeyKind.private, primary: id),
  target: PrivateSessionTarget(id),
  name: '$id',
  summary: '',
  timestampMicros: 1,
  unread: const SessionUnread(style: SessionUnreadStyle.number, number: 3),
  isPinned: false,
  isMuted: false,
  avatar: const SessionAvatar(url: ''),
  isLive: false,
);

LoadingState<SessionPageResult> sessionPage(List<int> ids) => Success(
  SessionPageResult(
    entries: ids.map(sessionEntry),
    cursor: null,
    hasMore: false,
  ),
);

final testFeedProvider = NotifierProvider<TestFeedNotifier, FeedSnapshot<int>>(
  TestFeedNotifier.new,
);

class TestFeedNotifier extends FeedNotifier<int> {
  @override
  FeedHandle<int> createHandle(MessagingSession session) => FeedHandle(
    session: session,
    idOf: (item) => item,
    request: (account, cursor) async =>
        Success(FeedPage(items: const [1], isEnd: true)),
  );
}

void main() {
  test('会话已读同步到所有列表，旧刷新不会覆盖操作结果', () async {
    final session = sessionFixture();
    final adapter = FakeSessionAdapter();
    final sessions = Sessions(session, adapter: adapter);
    final home = sessions.list(SessionFolder.home);
    final secondary = sessions.list(SessionFolder.unfollowed);
    final first = home.loadIfNeeded();
    adapter.requests[0].complete(sessionPage([1, 1, 2]));
    await first;
    final second = secondary.loadIfNeeded();
    adapter.requests[1].complete(sessionPage([1]));
    await second;
    expect(home.state.value.entries.map((e) => e.key.primary), [1, 2]);
    final refresh = home.refresh();
    await sessions.markRead(sessionEntry(1).key);
    adapter.requests[2].complete(sessionPage([1, 2]));
    await refresh;
    expect(home.state.value.entries.first.unread.isUnread, isFalse);
    expect(secondary.state.value.entries.single.unread.isUnread, isFalse);
    sessions.dispose();
    session.dispose();
  });

  test('删除会话后在途列表结果不能恢复已删除项', () async {
    final session = sessionFixture();
    final adapter = FakeSessionAdapter();
    final sessions = Sessions(session, adapter: adapter);
    final home = sessions.list(SessionFolder.home);
    final initial = home.loadIfNeeded();
    adapter.requests[0].complete(sessionPage([1, 2]));
    await initial;
    final refresh = home.refresh();
    await sessions.remove(sessionEntry(1).key);
    adapter.requests[1].complete(sessionPage([1, 2]));
    await refresh;
    expect(home.state.value.entries.map((e) => e.key.primary), [2]);
    sessions.dispose();
    session.dispose();
  });

  test('账号切换重建会话订阅，旧账号响应不进入新列表', () async {
    final oldSession = sessionFixture();
    final newSession = sessionFixture();
    final adapters = {
      oldSession: FakeSessionAdapter(),
      newSession: FakeSessionAdapter(),
    };
    final container = ProviderContainer(
      overrides: [
        messagingSessionProvider.overrideWith(
          () => TestSessionNotifier(oldSession),
        ),
        sessionsProvider.overrideWith((ref) {
          final session = ref.watch(messagingSessionProvider);
          return session.resource(
            Sessions,
            () => Sessions(session, adapter: adapters[session]!),
            (sessions) => sessions.dispose(),
          );
        }),
      ],
    );
    final provider = sessionListSnapshotProvider(SessionFolder.home);
    final subscription = container.listen(provider, (_, next) {});
    oldSession.dispose();
    (container.read(messagingSessionProvider.notifier) as TestSessionNotifier)
        .replace(newSession);
    container.read(provider);
    adapters[newSession]!.requests.single.complete(sessionPage([2]));
    await settle();
    adapters[oldSession]!.requests.single.complete(sessionPage([1]));
    await settle();
    expect(container.read(provider).entries.single.key.primary, 2);
    subscription.close();
    container.dispose();
    newSession.dispose();
  });

  test('Riverpod 快照桥接同步更新，释放后取消监听', () {
    final values = ValueNotifier(1);
    final provider = snapshotProvider<int>((ref) => values);
    final container = ProviderContainer();
    final subscription = container.listen(provider, (_, next) {});
    expect(container.read(provider), 1);
    values.value = 2;
    expect(container.read(provider), 2);
    subscription.close();
    container.dispose();
    values
      ..value = 3
      ..dispose();
  });

  test('Feed Notifier 首次创建可安全加载并发布状态', () async {
    final session = sessionFixture();
    final container = ProviderContainer(
      overrides: [
        messagingSessionProvider.overrideWith(
          () => TestSessionNotifier(session),
        ),
      ],
    );
    final subscription = container.listen(testFeedProvider, (_, next) {});
    await settle();
    expect(container.read(testFeedProvider).loadingState.data, [1]);
    subscription.close();
    container.dispose();
    session.dispose();
  });

  test('点赞刷新重新开放分页，并保留 latest 与 total 分组', () async {
    final session = sessionFixture();
    int calls = 0;
    final feed = LikeFeedHandle(
      session: session,
      request: (account, cursor) async {
        calls++;
        return Success(
          LikeFeedPage(
            latest: [MsgLikeItem(id: 1)],
            total: [MsgLikeItem(id: calls + 1)],
            isEnd: calls == 1,
            cursor: const FeedCursor(id: 2),
          ),
        );
      },
      delete: (account, id) async => const Success(null),
      setNoticeRequest: (account, id, state) async => const Success(null),
    );
    await feed.refresh();
    expect(feed.canLoadMore, isFalse);
    await feed.refresh();
    expect(feed.canLoadMore, isTrue);
    await feed.loadMore();
    final groups = feed.state.value.loadingState.data;
    expect(groups.latest.single.id, 1);
    expect(groups.total.map((m) => m.id), [3, 4]);
    feed.dispose();
    session.dispose();
  });

  test('未读合并重复刷新，阅读后旧结果失效', () async {
    final session = sessionFixture();
    final requests = <Completer<UnreadQueryResult>>[];
    final overview = UnreadOverview(
      session,
      query: () {
        final request = Completer<UnreadQueryResult>();
        requests.add(request);
        return request.future;
      },
    );
    final first = overview.refresh();
    final repeated = overview.refresh();
    expect(identical(first, repeated), isTrue);
    await settle();
    overview.invalidate();
    await settle();
    requests[1].complete(const UnreadQueryResult({MsgUnReadType.reply: 0}));
    await settle();
    requests[0].complete(const UnreadQueryResult({MsgUnReadType.reply: 9}));
    await first;
    expect(overview.state.value.counts[MsgUnReadType.reply], 0);
    overview.dispose();
    session.dispose();
  });

  test('查询失败保留旧数值，缺失分类保持未知', () async {
    final session = sessionFixture();
    int count = 0;
    final overview = UnreadOverview(
      session,
      query: () async => count++ == 0
          ? const UnreadQueryResult({MsgUnReadType.reply: 4})
          : const UnreadQueryResult({}, errors: {MsgUnReadType.reply: '失败'}),
    );
    await overview.refresh();
    await overview.refresh();
    expect(overview.state.value.counts[MsgUnReadType.reply], 4);
    expect(overview.state.value.counts[MsgUnReadType.pm], isNull);
    expect(overview.state.value.errors[MsgUnReadType.reply], '失败');
    overview.dispose();
    session.dispose();
  });

  test('账号释放后在途响应返回失效', () async {
    final session = sessionFixture();
    final response = Completer<LoadingState<int>>();
    final result = session.run((account) => response.future);
    session.dispose();
    response.complete(const Success(3));
    expect((await result as Error).code, messagingInactiveCode);
  });

  group('聊天', () {
    late MessagingSession session;
    late FakeConversationAdapter adapter;
    late Conversation chat;

    setUp(() {
      session = sessionFixture();
      adapter = FakeConversationAdapter();
      chat = Conversation(
        session: session,
        target: const ConversationTarget(talkerId: 456),
        adapter: adapter,
      );
    });
    tearDown(() {
      chat.dispose();
      session.dispose();
    });
    test('发送成功后的刷新应查询发送后的记录', () async {
      final initial = chat.open();
      expect((await chat.sendText('new message')).isSuccess, isTrue);
      final afterSend = chat.refresh(retryFailedAcknowledgement: false);
      expect(adapter.latestRequests.length, 2, reason: '发送前的查询不能保证包含已发送的新消息');
      adapter.latestRequests.first.complete(Success(page([10])));
      adapter.latestRequests.last.complete(Success(page([11, 10])));
      await initial;
      await afterSend;
      expect(chat.snapshot.messages.first.sequence, 11);
    });

    test('历史分页应保留最新页使用的表情映射', () async {
      final initial = chat.open();
      adapter.latestRequests.single.complete(
        Success(
          page(
            [10],
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
          page(
            [9],
            hasOlder: false,
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

    test('发送失败和网络未知均释放锁，允许下一次发送', () async {
      adapter.sendRequest = () async => const Error('失败');
      expect((await chat.sendText('first')).status, OperationStatus.failure);
      expect(chat.snapshot.isSending, isFalse);
      adapter.sendRequest = () async => throw DioException(
        requestOptions: RequestOptions(),
        type: DioExceptionType.receiveTimeout,
      );
      expect((await chat.sendText('second')).status, OperationStatus.unknown);
      expect(chat.snapshot.isSending, isFalse);
      adapter.latestRequests.single.complete(Success(page([3])));
      await settle();
      adapter.sendRequest = () async => const Success(null);
      expect((await chat.sendText('third')).isSuccess, isTrue);
    });

    test('刷新使旧历史页失效，消息按稳定 ID 去重', () async {
      final initial = chat.open();
      adapter.latestRequests[0].complete(Success(page([10, 9])));
      await initial;
      final older = chat.loadOlder();
      final refresh = chat.refresh();
      adapter.latestRequests[1].complete(Success(page([11, 10])));
      await refresh;
      adapter.olderRequests.single.complete(Success(page([9, 8])));
      await older;
      expect(chat.snapshot.messages.map((m) => m.sequence), [11, 10, 9]);
    });

    test('历史加载不 ACK，渲染水位单调且手动刷新可重试失败 ACK', () async {
      final initial = chat.open();
      adapter.latestRequests.single.complete(Success(page([10, 9])));
      await initial;
      expect(adapter.acknowledgements, isEmpty);
      adapter.ackResult = const Error('失败');
      chat.markRendered(message(10));
      await settle();
      chat.markRendered(message(9));
      await settle();
      expect(adapter.acknowledgements, [10]);
      adapter.ackResult = const Success(null);
      final refresh = chat.refresh();
      adapter.latestRequests[1].complete(Success(page([10, 9])));
      await refresh;
      await settle();
      expect(adapter.acknowledgements, [10, 10]);
      expect(chat.snapshot.acknowledgedSequence, 10);
    });

    test('撤回遇到在途刷新仍按 ID 保留撤回状态', () async {
      final initial = chat.open();
      adapter.latestRequests.single.complete(Success(page([10, 9])));
      await initial;
      final refresh = chat.refresh();
      await chat.recall(message(9));
      adapter.latestRequests[1].complete(Success(page([11, 10, 9])));
      await refresh;
      expect(
        chat.snapshot.messages.singleWhere((m) => m.id == '9').recalled,
        isTrue,
      );
    });
  });

  test('聊天缓存不会驱逐在用会话，释放后回收空闲会话', () {
    final session = sessionFixture();
    final cache = ConversationCache(
      session: session,
      adapter: FakeConversationAdapter(),
      maximumEntries: 1,
    );
    final first = cache.acquire(const ConversationTarget(talkerId: 1));
    final second = cache.acquire(const ConversationTarget(talkerId: 2));
    final same = cache.acquire(const ConversationTarget(talkerId: 1));
    expect(identical(first.conversation, same.conversation), isTrue);
    same.release();
    first.release();
    final recreated = cache.acquire(const ConversationTarget(talkerId: 1));
    expect(identical(first.conversation, recreated.conversation), isFalse);
    second.release();
    recreated.release();
    cache.dispose();
    session.dispose();
  });

  test('结构化内容递归不可变且不共享输入集合', () {
    final nested = <String, Object?>{
      'items': <Object?>['one'],
    };
    final content = StructuredMessageContent(MessageContentKind.tip, nested);
    (nested['items'] as List).add('two');
    expect(content.payload['items'], ['one']);
    expect(
      () => (content.payload['items'] as List).add('three'),
      throwsUnsupportedError,
    );
  });

  test('Feed 刷新废弃旧分页，删除使用稳定 ID', () async {
    final session = sessionFixture();
    final requests = <Completer<LoadingState<FeedPage<int>>>>[];
    final feed = FeedHandle<int>(
      session: session,
      idOf: (id) => id,
      request: (account, cursor) {
        final request = Completer<LoadingState<FeedPage<int>>>();
        requests.add(request);
        return request.future;
      },
      delete: (account, id) async => const Success(null),
    );
    final initial = feed.refresh();
    requests[0].complete(
      Success(FeedPage(items: const [1, 2], cursor: const FeedCursor(id: 2))),
    );
    await initial;
    final older = feed.loadMore();
    final refresh = feed.refresh();
    requests[2].complete(
      Success(FeedPage(items: const [3, 2], cursor: const FeedCursor(id: 2))),
    );
    await refresh;
    requests[1].complete(Success(FeedPage(items: const [2, 1])));
    await older;
    await feed.remove(2);
    expect(feed.state.value.loadingState.data, [3]);
    feed.dispose();
    session.dispose();
  });
}
