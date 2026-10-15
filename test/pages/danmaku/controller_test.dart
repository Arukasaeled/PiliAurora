import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:pili_aurora/grpc/bilibili/community/service/dm/v1.pb.dart';
import 'package:pili_aurora/grpc/grpc_req.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/models/user/danmaku_rule.dart';
import 'package:pili_aurora/pages/danmaku/controller.dart';
import 'package:pili_aurora/plugin/pl_player/controller.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';

class _Player implements PlPlayerController {
  _Player({this.mergeDanmaku = true});

  @override
  final bool mergeDanmaku;
  @override
  final RuleFilter filters = RuleFilter(['屏蔽'], [], {});

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
  }) async {
    entered.complete();
    await resume.future;
    await super.handleDanmaku(elems, segmentIndex: segmentIndex);
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
