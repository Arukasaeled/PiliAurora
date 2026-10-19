import 'dart:async';
import 'dart:typed_data';

import 'package:pili_aurora/services/danmaku/work_quota.dart';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:pili_aurora/grpc/bilibili/community/service/dm/v1.pb.dart';
import 'package:pili_aurora/grpc/grpc_req.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/models/user/danmaku_rule.dart';
import 'package:pili_aurora/pages/danmaku/controller.dart';
import 'package:pili_aurora/pages/danmaku/timeline_range.dart';
import 'package:pili_aurora/plugin/pl_player/controller.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';

class _Player implements PlPlayerController {
  _Player({this.mergeDanmaku = true});

  @override
  bool mergeDanmaku;
  @override
  RuleFilter filters = RuleFilter(['屏蔽'], [], {});

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

DanmakuElem _dm(String text, int time) =>
    DanmakuElem(content: text, progress: time, mode: 1);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    GStorage.setting = _SettingsBox();
    GStorage.video = _SettingsBox();
    GStorage.localCache = _SettingsBox();
    Request();
    Request.dio.interceptors.clear();
    Request.dio.httpClientAdapter.close(force: true);
  });
  tearDownAll(() => Request.dio.close(force: true));

  test('多个来源响应在同一预留内串行处理直到缓存提交', () async {
    final adapter = _DmAdapter();
    Request.dio.httpClientAdapter = adapter;
    final first = _HoldingController();
    final second = _HoldingController();
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    final firstRequest = first.queryDanmaku(0);
    await first.entered.future;
    final secondRequest = second.queryDanmaku(0);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(second.entered.isCompleted, isFalse);
    first.resume.complete();
    await firstRequest;
    await second.entered.future;
    expect(first.readRange(0, 1000000).isLoaded, isTrue);
    second.resume.complete();
    await secondRequest;
    expect(second.readRange(0, 1000000).isLoaded, isTrue);
  });

  test('等待队列满时保留来源需求，容量恢复后处理最新规则', () async {
    final quota = DanmakuWorkQuota.instance;
    final gate = Completer<void>();
    final running = quota.run(1, () => gate.future);
    final waiting = List.generate(
      quota.maxWaitingTasks,
      (_) => quota.run(1, () {}, waitingBytes: 1),
    );
    final player = _Player(mergeDanmaku: false);
    final controller = PlDanmakuController(1, player, false);
    addTearDown(controller.dispose);
    await controller.handleDanmaku([_dm('屏蔽内容', 100)], segmentIndex: 0);
    expect(controller.readRange(0, 1000000).isLoaded, isFalse);
    player.filters = RuleFilter.empty();
    await controller.refreshRules();
    final ready = controller.changes.firstWhere(
      (e) => e.kind == DanmakuSourceChangeKind.ready,
    );
    gate.complete();
    await running;
    await Future.wait(waiting);
    await ready.timeout(const Duration(seconds: 5));
    expect(controller.peekBufferedDanmaku(0, 1000).single.content, '屏蔽内容');
  });

  test('规则失效先清空缓存，再从原始输入恢复被屏蔽内容', () async {
    final player = _Player();
    final controller = PlDanmakuController(1, player, false);
    addTearDown(controller.dispose);
    final raw = [_dm('屏蔽内容', 100), _dm('保留', 200)];
    await controller.handleDanmaku(raw, segmentIndex: 0);
    expect(controller.peekBufferedDanmaku(0, 1000).map((e) => e.content), [
      '保留',
    ]);
    final events = <DanmakuSourceChange>[];
    final subscription = controller.changes.listen((event) {
      events.add(event);
      if (event.kind == DanmakuSourceChangeKind.invalidated) {
        expect(controller.peekBufferedDanmaku(0, 1000), isEmpty);
        expect(
          controller.readRange(0, 1000000).coverage.single.state,
          DanmakuCoverageState.invalidated,
        );
      }
    });
    addTearDown(subscription.cancel);
    player.filters = RuleFilter.empty();
    final pending = controller.refreshRules();
    expect(events.single.kind, DanmakuSourceChangeKind.invalidated);
    await pending;
    expect(events.map((event) => event.kind), [
      DanmakuSourceChangeKind.invalidated,
      DanmakuSourceChangeKind.ready,
    ]);
    expect(events.last.ruleRevision, events.first.ruleRevision);
    expect(
      controller.readRange(0, 1000000).ruleRevision,
      events.last.ruleRevision,
    );
    expect(controller.peekBufferedDanmaku(0, 1000).map((e) => e.content), [
      '屏蔽内容',
      '保留',
    ]);
    expect(raw.every((element) => element.count == 0), isTrue);
  });

  test('连续规则变化撤销旧合并结果，最新修订单独发布就绪', () async {
    final player = _Player();
    final controller = PlDanmakuController(1, player, false);
    addTearDown(controller.dispose);
    final events = <DanmakuSourceChange>[];
    final subscription = controller.changes.listen(events.add);
    addTearDown(subscription.cancel);
    final old = controller.handleDanmaku([
      _dm('内容', 100),
      _dm('内容', 101),
    ], segmentIndex: 0);
    final first = controller.refreshRules();
    player.filters = RuleFilter(['内容'], [], {});
    final latest = controller.refreshRules();
    await Future.wait([old, first, latest]);
    final ready = events.where(
      (event) => event.kind == DanmakuSourceChangeKind.ready,
    );
    expect(ready, hasLength(1));
    expect(ready.single.ruleRevision, 2);
    expect(controller.peekBufferedDanmaku(0, 1000), isEmpty);
    expect(controller.readRange(0, 1000000).isLoaded, isTrue);
  });

  test('重算途中卸载后不发布就绪也不回写缓存', () async {
    final controller = PlDanmakuController(1, _Player(), false);
    await controller.handleDanmaku([_dm('重复', 100)], segmentIndex: 0);
    final events = <DanmakuSourceChange>[];
    final subscription = controller.changes.listen(events.add);
    final pending = controller.refreshRules();
    controller.dispose();
    await pending;
    expect(events.map((event) => event.kind), [
      DanmakuSourceChangeKind.invalidated,
    ]);
    expect(controller.peekBufferedDanmaku(0, 1000), isEmpty);
    await subscription.cancel();
  });

  test('本地来源重算恢复原始条目并可取消合并', () async {
    final player = _Player();
    final controller = PlDanmakuController(1, player, true);
    addTearDown(controller.dispose);
    await controller.handleDanmaku([_dm('重复', 100), _dm('重复', 101)]);
    expect(controller.peekBufferedDanmaku(0, 1000).single.count, 2);
    player.mergeDanmaku = false;
    await controller.refreshRules();
    expect(controller.peekBufferedDanmaku(0, 1000), hasLength(2));
  });

  test(
    'segment stays pending until processing finishes, then uses cached data',
    () async {
      final adapter = _DmAdapter();
      Request.dio.httpClientAdapter = adapter;
      final controller = _HoldingController();
      addTearDown(controller.dispose);
      final pending = controller.queryDanmaku(0);
      await controller.entered.future;
      await controller.queryDanmaku(0);
      expect(adapter.calls, 1);
      controller.resume.complete();
      await pending;
      await controller.queryDanmaku(0);
      expect(adapter.calls, 1);
      expect(controller.peekBufferedDanmaku(0, 1000).single.count, 2);
    },
  );

  test(
    'background processing filters before merging and caches only its segment',
    () async {
      final controller = PlDanmakuController(1, _Player(), false);
      addTearDown(controller.dispose);
      await controller.handleDanmaku([
        _dm('相同的内容', 100),
        _dm('相同的内容', 101),
        _dm('相同的内容屏蔽', 102),
        _dm('其他内容', 200),
        _dm('下一段', 360000),
      ], segmentIndex: 0);
      final cached = controller.peekBufferedDanmaku(0, 360000).toList();
      expect(cached.map((e) => e.content), ['相同的内容', '其他内容']);
      expect(cached.map((e) => e.count), [2, 1]);
    },
  );

  test('dispose during background merge prevents late cache writes', () async {
    final controller = PlDanmakuController(1, _Player(), false);
    final pending = controller.handleDanmaku([
      _dm('重复', 100),
      _dm('重复', 101),
    ], segmentIndex: 0);
    controller.dispose();
    await pending;
    expect(controller.peekBufferedDanmaku(0, 1000), isEmpty);
  });

  test(
    'background processing merges rating pool duplicates into cache',
    () async {
      final controller = PlDanmakuController(1, _Player(), false);
      addTearDown(controller.dispose);
      await controller.handleDanmaku([
        _dm('5', 26600)..pool = 3,
        _dm('5', 27082)..pool = 3,
        _dm('1', 42600)..pool = 3,
        _dm('5', 42600)..pool = 3,
        _dm('1', 42796)..pool = 3,
      ], segmentIndex: 0);
      final cached = controller.peekBufferedDanmaku(26000, 43000).toList();
      expect(cached.map((e) => e.content), ['5', '1']);
      expect(cached.map((e) => e.count), [3, 2]);
    },
  );

  test(
    'disabled merging retains individual messages and bucket limits',
    () async {
      final controller = PlDanmakuController(
        1,
        _Player(mergeDanmaku: false),
        false,
      );
      addTearDown(controller.dispose);
      await controller.handleDanmaku(
        List.generate(20, (i) => _dm('重复', 100 + i)),
        segmentIndex: 0,
      );
      final cached = controller.peekBufferedDanmaku(100, 200).toList();
      expect(cached, hasLength(8));
      // 未开启合并时保持 protobuf 原始计数，不进行额外处理。
      expect(cached.every((e) => e.count == 0), isTrue);
    },
  );

  test(
    'local file merging retains messages across online segment boundaries',
    () async {
      final controller = PlDanmakuController(1, _Player(), true);
      addTearDown(controller.dispose);
      await controller.handleDanmaku([
        _dm('跨段重复', 359900),
        _dm('跨段重复', 360100),
      ]);
      final cached = controller.peekBufferedDanmaku(359000, 361000).toList();
      expect(cached, hasLength(1));
      expect(cached.single.count, 2);
    },
  );
}

class _SettingsBox implements Box<dynamic> {
  @override
  dynamic get(dynamic key, {dynamic defaultValue}) =>
      key == LocalCacheKey.buvid ? 'danmaku-controller-test' : defaultValue;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _HoldingController extends PlDanmakuController {
  _HoldingController() : super(1, _Player(), false);

  final entered = Completer<void>();
  final resume = Completer<void>();

  @override
  Future<void> handleDanmaku(
    List<DanmakuElem> elems, {
    int? segmentIndex,
    DanmakuWorkLease? lease,
  }) async {
    entered.complete();
    await resume.future;
    await super.handleDanmaku(elems, segmentIndex: segmentIndex, lease: lease);
  }
}

class _DmAdapter implements HttpClientAdapter {
  int calls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    final reply = DmSegMobileReply(elems: [_dm('重复', 100), _dm('重复', 101)]);
    return ResponseBody.fromBytes(
      GrpcReq.compressProtobuf(reply.writeToBuffer()),
      200,
      headers: {
        'grpc-status': ['0'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
