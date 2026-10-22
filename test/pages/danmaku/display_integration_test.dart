import 'dart:async';
import 'dart:typed_data';

import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive.dart';
import 'package:pili_aurora/pages/danmaku/danmaku_model.dart';
import 'package:pili_aurora/pages/danmaku/display_binding.dart';
import 'package:pili_aurora/pages/danmaku/echo_source.dart';
import 'package:pili_aurora/pages/danmaku/live_queue.dart';
import 'package:pili_aurora/pages/danmaku/timeline_range.dart';
import 'package:pili_aurora/pages/danmaku/window_coordinator.dart';
import 'package:pili_aurora/pages/danmaku/window_renderer.dart';
import 'package:pili_aurora/pages/danmaku/window_screen.dart';
import 'package:pili_aurora/pages/danmaku/view.dart';
import 'package:pili_aurora/pages/live_room/controller.dart';
import 'package:pili_aurora/pages/live_room/view.dart' as live;
import 'package:pili_aurora/plugin/pl_player/controller.dart';
import 'package:pili_aurora/plugin/pl_player/models/play_status.dart';
import 'package:pili_aurora/plugin/pl_player/playback/media_clock.dart';
import 'package:pili_aurora/utils/storage.dart';

Widget host(Widget child) => Directionality(
  textDirection: TextDirection.ltr,
  child: MediaQuery(data: const MediaQueryData(), child: child),
);

void main() {
  setUpAll(() async {
    GStorage.setting = await Hive.openBox<dynamic>(
      'audit_danmaku',
      bytes: Uint8List(0),
    );
  });
  tearDownAll(() => GStorage.setting.close());

  for (final anchorUs in [1000000, 1000500]) {
    testWidgets('paused send echo at native anchor $anchorUs us', (
      tester,
    ) async {
      final origin = Origin();
      final source = DanmakuEchoSource(origin);
      final renderer = DanmakuWindowRenderer<DanmakuExtra>(
        option: const DanmakuOption(),
        size: const Size(640, 360),
      );
      final coordinator = DanmakuWindowCoordinator<DanmakuExtra>(
        source: source,
        renderer: renderer,
        contentOf: source.contentFor,
      );
      final clock = Clock(anchorUs);
      await tester.pumpWidget(
        host(
          DanmakuWindowScreen<DanmakuExtra>(
            renderer: renderer,
            clock: clock,
            size: const Size(640, 360),
            monotonicUs: () => 0,
            frameTimeUs: () => 0,
            prepareFrame: coordinator.prepareFrame,
            needsPreparation: () => coordinator.needsPreparation,
            nextPreparationUs: () => coordinator.nextPreparationUs,
            inputChanges: coordinator.updates,
          ),
        ),
      );
      await tester.pump();
      final content = DanmakuContentItem<DanmakuExtra>(
        'sent',
        selfSend: true,
        extra: VideoDanmaku(id: 7, mid: 'self'),
      );
      source.add(content, anchorUs);
      await tester.pump();
      final texts = renderer.interaction.snapshot
          .map((item) => item.text)
          .toList();
      await tester.pumpWidget(const SizedBox.shrink());
      coordinator.dispose();
      renderer.dispose();
      source.dispose();
      await origin.events.close();
      await clock.events.close();
      expect(texts, contains('sent'));
    });
  }

  testWidgets('production echo retains the paused window microseconds', (
    tester,
  ) async {
    final player = Player()..live = false;
    await tester.pumpWidget(
      host(
        PlDanmaku(
          cid: 1,
          playerController: player,
          isFullScreen: false,
          isFileSource: true,
          size: const Size(640, 360),
        ),
      ),
    );
    await tester.pump();
    player.danmakuDisplay!.echo!(
      DanmakuContentItem<DanmakuExtra>(
        'sent',
        selfSend: true,
        extra: VideoDanmaku(id: 7, mid: 'self'),
      ),
      1000000,
    );
    await tester.pump();
    expect(player.danmakuDisplay!.interaction().snapshot.single.text, 'sent');
    await tester.pumpWidget(const SizedBox.shrink());
    await player.clock.events.close();
    player.videoDisplaySyncActive.dispose();
  });

  testWidgets('hidden live page cannot reclaim active display binding', (
    tester,
  ) async {
    final player = Player();
    final firstRoom = Room();
    final secondRoom = Room();
    Widget page(Room room, String key, bool enabled) => TickerMode(
      enabled: enabled,
      child: live.LiveDanmaku(
        key: ValueKey(key),
        liveRoomController: room,
        plPlayerController: player,
        isFullScreen: false,
        size: const Size(640, 360),
      ),
    );
    Widget pages(bool firstVisible) => host(
      Stack(
        children: [
          page(firstRoom, 'first', firstVisible),
          page(secondRoom, 'second', !firstVisible),
        ],
      ),
    );
    await tester.pumpWidget(pages(false));
    await tester.pump();
    // 模拟返回第一间直播，后一页面仍在退出动画或被保留。
    await tester.pumpWidget(pages(true));
    player.notifyDanmakuOptionsChanged();
    await tester.pump();
    firstRoom.events.add(
      LiveDanmakuMessage<DanmakuExtra>(
        identity: 'visible-message',
        receivedAtUs: liveDanmakuNowUs(),
        text: 'visible',
      ),
    );
    await tester.pump();
    final visibleCount = player.bindings.last.interaction().snapshot.length;
    final boundCount = player.danmakuDisplay!.interaction().snapshot.length;
    final usesFirst = identical(player.danmakuDisplay, player.bindings.last);
    await tester.pumpWidget(const SizedBox.shrink());
    await firstRoom.events.close();
    await secondRoom.events.close();
    player.videoDisplaySyncActive.dispose();
    expect(visibleCount, 1);
    expect(boundCount, 1);
    expect(usesFirst, isTrue);
  });

  test('a captured list handle stays invalid after presentation resumes', () {
    final renderer = DanmakuWindowRenderer<void>(
      option: const DanmakuOption(),
      size: const Size(640, 360),
    );
    renderer.prepare(
      [
        DanmakuWindowContent('one', 0, DanmakuContentItem<void>('one')),
      ],
      generation: renderer.generation,
      preparedUntilUs: 2000000,
    );
    renderer.present(500000);
    final captured = renderer.interaction;
    expect(captured.snapshot, hasLength(1));
    renderer
      ..suspendPresentation()
      ..present(600000);
    expect(renderer.interaction.snapshot, hasLength(1));
    expect(captured.snapshot, isEmpty);
    renderer.dispose();
  });
}

class Origin implements DanmakuTimelineSource {
  final events = StreamController<DanmakuSourceChange>.broadcast(sync: true);
  @override
  Stream<DanmakuSourceChange> get changes => events.stream;
  @override
  Future<void> ensureRange(int startUs, int endUs) async {}
  @override
  DanmakuTimelineRange readRange(
    int startUs,
    int endUs, {
    int? maxEntriesPerBucket,
  }) => DanmakuTimelineRange(
    startUs: startUs,
    endUs: endUs,
    revision: 0,
    entries: const [],
    coverage: [
      DanmakuRangeCoverage(startUs, endUs, DanmakuCoverageState.loaded),
    ],
  );
}

class Clock implements PlaybackMediaClock {
  Clock(this.position);
  final int position;
  final events = StreamController<PlaybackMediaAnchor?>.broadcast(sync: true);
  @override
  PlaybackMediaAnchor get currentMediaAnchor => PlaybackMediaAnchor(
    positionUs: position,
    observedAtUs: 0,
    effectiveRate: 1,
    advancing: false,
    ready: true,
    continuity: 1,
    validForUs: 500000,
  );
  @override
  Stream<PlaybackMediaAnchor?> get mediaAnchors => events.stream;
}

class Player implements PlPlayerController {
  bool live = true;
  final clock = Clock(1000500);
  @override
  bool get mergeDanmaku => false;
  @override
  int get positionInMilliseconds => 1000;
  @override
  PlaybackMediaClock get mediaClock => clock;
  @override
  final enableShowDanmaku = true.obs;
  @override
  final enableShowLiveDanmaku = true.obs;
  @override
  final danmakuOpacity = 1.0.obs;
  @override
  final ValueNotifier<bool> videoDisplaySyncActive = ValueNotifier<bool>(false);
  @override
  bool get showDanmaku => true;
  @override
  bool get isLive => live;
  @override
  PlayerStatus get playerStatus =>
      live ? PlayerStatus.playing : PlayerStatus.paused;
  final listeners = <VoidCallback>{};
  final bindings = <DanmakuDisplayBinding>[];
  DanmakuDisplayBinding? binding;
  @override
  DanmakuDisplayBinding? get danmakuDisplay => binding;
  @override
  set danmakuDisplay(DanmakuDisplayBinding? value) {
    binding = value;
    if (value != null && !bindings.contains(value)) bindings.add(value);
  }

  @override
  void addDanmakuOptionsListener(VoidCallback listener) =>
      listeners.add(listener);
  @override
  void removeDanmakuOptionsListener(VoidCallback listener) =>
      listeners.remove(listener);
  @override
  void notifyDanmakuOptionsChanged() {
    for (final listener in listeners.toList()) {
      listener();
    }
  }

  @override
  void addStatusLister(dynamic listener) {}
  @override
  void removeStatusLister(dynamic listener) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class Room implements LiveRoomController {
  final events = StreamController<LiveDanmakuMessage<DanmakuExtra>>.broadcast(
    sync: true,
  );
  @override
  Stream<LiveDanmakuMessage<DanmakuExtra>> get liveDanmakuMessages =>
      events.stream;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
