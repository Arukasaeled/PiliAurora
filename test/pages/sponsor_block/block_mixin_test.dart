import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive.dart';
import 'package:media_kit/media_kit.dart';
import 'package:pili_aurora/models/common/sponsor_block/segment_model.dart';
import 'package:pili_aurora/models/remote/sponsor_block/segment_item.dart';
import 'package:pili_aurora/pages/sponsor_block/block_mixin.dart';
import 'package:pili_aurora/utils/storage.dart';

void main() {
  late Directory directory;
  late _BlockController controller;

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('pili-block-');
    Hive.init(directory.path);
    GStorage.setting = await Hive.openBox('setting');
  });
  tearDownAll(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });
  setUp(() => controller = _BlockController());
  tearDown(() async {
    controller.onClose();
    await controller.player.positions.close();
    await controller.player.playing.close();
  });

  final intro = SegmentItemModel(
    category: 'intro',
    segment: [0, 27967],
    uuid: 'fixture',
    videoDuration: 600000,
  );

  test('片段响应早于原生媒体就绪时等待真实进度，保留 109 秒续播位置', () async {
    controller.player.state.playing = true;
    await controller.handleSBData([intro]);
    expect(controller.seeks, isEmpty);

    controller.player.emitPosition(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(controller.seeks, isEmpty);

    controller.player.state.duration = const Duration(minutes: 10);
    controller.player.emitPosition(const Duration(seconds: 109));
    await Future<void>.delayed(Duration.zero);
    expect(controller.seeks, isEmpty);
  });

  test('媒体就绪后的首次进度位于片段内时执行一次跳过', () async {
    controller.player.state.playing = true;
    await controller.handleSBData([intro]);
    expect(controller.seeks, isEmpty);

    controller.player.state.duration = const Duration(minutes: 10);
    controller.player.emitPosition(const Duration(seconds: 5));
    await Future<void>.delayed(Duration.zero);
    expect(controller.seeks, [const Duration(milliseconds: 27967)]);
    controller.player.emitPosition(const Duration(seconds: 6));
    await Future<void>.delayed(Duration.zero);
    expect(controller.seeks, hasLength(1));
  });

  test('播放中的片段响应立即处理当前位置', () async {
    controller.player.state
      ..playing = true
      ..duration = const Duration(minutes: 10)
      ..position = const Duration(seconds: 5);
    await controller.handleSBData([intro]);
    expect(controller.seeks, [const Duration(milliseconds: 27967)]);
  });

  test('原生时长已知但仍在加载时等待首个可用进度', () async {
    controller.player.state
      ..playing = true
      ..buffering = true
      ..duration = const Duration(minutes: 10);
    await controller.handleSBData([intro]);
    expect(controller.seeks, isEmpty);
    controller.player.state.buffering = false;
    controller.player.emitPosition(const Duration(seconds: 109));
    await Future<void>.delayed(Duration.zero);
    expect(controller.seeks, isEmpty);
  });

  test('重置后旧媒体的 playing 和 position 事件不触发跳过', () async {
    await controller.handleSBData([intro]);
    controller.resetBlock();
    controller.player.state
      ..playing = true
      ..duration = const Duration(minutes: 10);
    controller.player.playing.add(true);
    controller.player.emitPosition(const Duration(seconds: 5));
    await Future<void>.delayed(Duration.zero);
    expect(controller.seeks, isEmpty);
  });
}

class _BlockController extends GetxController with BlockMixin {
  @override
  final blockConfig = _BlockConfig();
  @override
  final _Player player = _Player();
  final seeks = <Duration>[];
  @override
  bool get autoPlay => true;
  @override
  bool get preInitPlayer => false;
  @override
  bool get isUgc => true;
  @override
  int get timeLength => 600000;
  @override
  int get currPosInMilliseconds => player.state.position.inMilliseconds;

  @override
  Future<void> seekTo(Duration duration, {required bool isSeek}) {
    seeks.add(duration);
    return Future.value();
  }

  // 跳转决策沿用真实 mixin；测试替换提示和计数上报的外部副作用。
  @override
  Future<void> onSkip(
    SegmentModel item, {
    bool isSkip = true,
    bool isSeek = true,
  }) => seekTo(Duration(milliseconds: item.segment.$2), isSeek: isSeek);
}

class _BlockConfig with BlockConfigMixin {}

class _Player implements Player {
  @override
  final state = PlayerState();
  final positions = StreamController<Duration>.broadcast();
  final playing = StreamController<bool>.broadcast();
  @override
  late final stream = _Streams(positions.stream, playing.stream);

  void emitPosition(Duration value) {
    state.position = value;
    positions.add(value);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected player operation: ${invocation.memberName}');
}

class _Streams implements PlayerStream {
  _Streams(this.position, this.playing);
  @override
  final Stream<Duration> position;
  @override
  final Stream<bool> playing;
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected stream: ${invocation.memberName}');
}
