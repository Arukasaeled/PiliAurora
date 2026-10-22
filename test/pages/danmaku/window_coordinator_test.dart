import 'dart:async';

import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/grpc/bilibili/community/service/dm/v1.pb.dart';
import 'package:pili_aurora/pages/danmaku/cache.dart';
import 'package:pili_aurora/pages/danmaku/timeline_range.dart';
import 'package:pili_aurora/pages/danmaku/window_coordinator.dart';
import 'package:pili_aurora/pages/danmaku/window_renderer.dart';
import 'package:pili_aurora/pages/danmaku/window_screen.dart';
import 'package:pili_aurora/plugin/pl_player/playback/media_clock.dart';

class _Source implements DanmakuTimelineSource {
  final cache = DanmakuCache();
  final events = StreamController<DanmakuSourceChange>.broadcast(sync: true);
  final requests = <(int, int)>[];
  int revision = 0;
  @override
  Stream<DanmakuSourceChange> get changes => events.stream;
  @override
  DanmakuTimelineRange readRange(
    int startUs,
    int endUs, {
    int? maxEntriesPerBucket,
  }) => cache.readRange(
    startUs,
    endUs,
    ruleRevision: revision,
    maxEntriesPerBucket: maxEntriesPerBucket,
  );
  @override
  Future<void> ensureRange(int startUs, int endUs) async {
    requests.add((startUs, endUs));
  }

  void load(List<DanmakuElem> elements) {
    cache.addFileElements(elements);
    events.add(
      DanmakuSourceChange(
        kind: DanmakuSourceChangeKind.ready,
        ruleRevision: revision,
      ),
    );
  }

  void invalidate() {
    revision++;
    cache.clear();
    events.add(
      DanmakuSourceChange(
        kind: DanmakuSourceChangeKind.invalidated,
        ruleRevision: revision,
      ),
    );
  }
}

class _Clock implements PlaybackMediaClock {
  _Clock({this.advancing = true});
  final bool advancing;
  @override
  PlaybackMediaAnchor get currentMediaAnchor => PlaybackMediaAnchor(
    positionUs: 0,
    observedAtUs: 0,
    effectiveRate: 1,
    advancing: advancing,
    ready: true,
    continuity: 0,
    validForUs: 10000000,
  );
  final events = StreamController<PlaybackMediaAnchor?>.broadcast();
  @override
  Stream<PlaybackMediaAnchor?> get mediaAnchors => events.stream;
}

DanmakuElem _dm(String text, int milliseconds) =>
    DanmakuElem(content: text, progress: milliseconds);
DanmakuWindowRenderer<void> _renderer() => DanmakuWindowRenderer(
  option: const DanmakuOption(
    duration: 8,
    fontSize: 16,
    safeArea: false,
    massiveMode: true,
  ),
  size: const Size(500, 200),
);
DanmakuContentItem<void> _content(DanmakuElem element) => DanmakuContentItem(
  element.content,
  color: const Color(0xffffffff),
  selfSend: true,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('local invalidation preserves unrelated active items and ignores stale ready', () {
    final source = _Source()..load([_dm('keep', 0), _dm('remove', 100)]);
    final renderer = _renderer();
    final coordinator = DanmakuWindowCoordinator(
      source: source,
      renderer: renderer,
      contentOf: _content,
    );
    addTearDown(renderer.dispose);
    addTearDown(coordinator.dispose);
    addTearDown(source.events.close);
    coordinator.prepareFrame(renderer, 0);
    renderer.present(150000, allowUnprepared: true);
    expect(renderer.activeCount, 2);
    source.events.add(
      const DanmakuSourceChange(
        kind: DanmakuSourceChangeKind.invalidated,
        ruleRevision: 2,
        startUs: 100000,
        endUs: 200000,
      ),
    );
    expect(renderer.activeCount, 1);
    coordinator.prepareFrame(renderer, 150000);
    renderer.present(150000, allowUnprepared: true);
    expect(renderer.activeCount, 1);
    source.events.add(
      const DanmakuSourceChange(
        kind: DanmakuSourceChangeKind.ready,
        ruleRevision: 1,
        startUs: 100000,
        endUs: 200000,
      ),
    );
    coordinator.prepareFrame(renderer, 150000);
    renderer.present(150000, allowUnprepared: true);
    expect(renderer.activeCount, 1);
    source.events.add(
      const DanmakuSourceChange(
        kind: DanmakuSourceChangeKind.ready,
        ruleRevision: 2,
        startUs: 100000,
        endUs: 200000,
      ),
    );
    coordinator.prepareFrame(renderer, 150000);
    renderer.present(150000, allowUnprepared: true);
    // 已经越过当前生效下界的旧条目不会重新投放。
    expect(renderer.activeCount, 1);
  });

  test('equal timestamps prepare incrementally without claiming a complete frontier', () {
    final source = _Source()
      ..load([for (var i = 0; i < 6; i++) _dm('item$i', 0)]);
    final renderer = _renderer();
    final coordinator = DanmakuWindowCoordinator(
      source: source,
      renderer: renderer,
      contentOf: _content,
      preparePerFrame: 2,
    );
    addTearDown(renderer.dispose);
    addTearDown(coordinator.dispose);
    addTearDown(source.events.close);
    coordinator.prepareFrame(renderer, 0);
    expect(renderer.validUntilUs, 0);
    expect(renderer.present(0), isFalse);
    expect(renderer.present(0, allowUnprepared: true), isTrue);
    expect(renderer.activeCount, 2);
    coordinator.prepareFrame(renderer, 16000);
    renderer.present(16000, allowUnprepared: true);
    expect(renderer.activeCount, 4);
    coordinator.prepareFrame(renderer, 32000);
    renderer.present(32000, allowUnprepared: true);
    expect(renderer.activeCount, 6);
    expect(renderer.validUntilUs, greaterThan(0));
  });

  test('missing coverage waits, ready input fills it and invalidation clears immediately', () async {
    final source = _Source();
    final renderer = _renderer();
    final coordinator = DanmakuWindowCoordinator(
      source: source,
      renderer: renderer,
      contentOf: _content,
    );
    addTearDown(renderer.dispose);
    addTearDown(coordinator.dispose);
    addTearDown(source.events.close);
    coordinator.prepareFrame(renderer, 0);
    await Future<void>.delayed(Duration.zero);
    expect(source.requests, [(0, 2000000)]);
    expect(renderer.validUntilUs, 0);
    source.load([_dm('loaded', 0)]);
    coordinator.prepareFrame(renderer, 100000);
    renderer.present(100000, allowUnprepared: true);
    expect(renderer.activeCount, 1);
    source.invalidate();
    expect(renderer.activeCount, 0);
    expect(renderer.validFromUs, 100000);
    source.load([_dm('new rules', 100)]);
    coordinator.prepareFrame(renderer, 100000);
    renderer.present(100000, allowUnprepared: true);
    expect(renderer.activeCount, 1);
  });

  test(
    'refill reaches its target then stops reads until inner threshold',
    () {
      final source = _Source()..load([]);
      final renderer = _renderer();
      final coordinator = DanmakuWindowCoordinator(
        source: source,
        renderer: renderer,
        contentOf: _content,
      );
      addTearDown(renderer.dispose);
      addTearDown(coordinator.dispose);
      addTearDown(source.events.close);
      for (var i = 0; i < 6; i++) {
        coordinator.prepareFrame(renderer, 0);
      }
      expect(renderer.validUntilUs, 2000000);
      final requests = source.requests.length;
      coordinator.prepareFrame(renderer, 1000000);
      expect(source.requests.length, requests);
      expect(renderer.validUntilUs, 2000000);
      coordinator.prepareFrame(renderer, 1600000);
      expect(renderer.validUntilUs, greaterThan(2000000));
    },
  );

  test(
    'observed rate scales real-time lookahead without resetting trajectories',
    () {
      final source = _Source()..load([]);
      final renderer = _renderer();
      final coordinator = DanmakuWindowCoordinator(
        source: source,
        renderer: renderer,
        contentOf: _content,
      );
      addTearDown(renderer.dispose);
      addTearDown(coordinator.dispose);
      addTearDown(source.events.close);
      final generation = renderer.generation;
      for (var i = 0; i < 12; i++) {
        coordinator.prepareFrame(renderer, 0, effectiveRate: 2);
      }
      expect(renderer.validUntilUs, 4000000);
      expect(coordinator.needsPreparation, isFalse);
      coordinator.prepareFrame(renderer, 3000000, effectiveRate: 2);
      expect(coordinator.needsPreparation, isFalse);
      coordinator.prepareFrame(renderer, 3100000, effectiveRate: 2);
      expect(coordinator.needsPreparation, isTrue);
      for (var i = 0; i < 12; i++) {
        coordinator.prepareFrame(renderer, 3100000, effectiveRate: 2);
      }
      expect(renderer.validUntilUs, 7100000);
      coordinator.prepareFrame(renderer, 3100000, effectiveRate: .5);
      expect(coordinator.needsPreparation, isFalse);
      expect(renderer.validUntilUs, 7100000);
      expect(renderer.generation, generation);
    },
  );

  test('repeated ready signals preserve fixed bucket sampling', () {
    final source = _Source()
      ..load([for (var i = 0; i < 200; i++) _dm('sample$i', 0)]);
    final renderer = _renderer();
    var converted = 0;
    final coordinator = DanmakuWindowCoordinator(
      source: source,
      renderer: renderer,
      preparePerFrame: 120,
      contentOf: (element) {
        converted++;
        return _content(element);
      },
    );
    addTearDown(renderer.dispose);
    addTearDown(coordinator.dispose);
    addTearDown(source.events.close);
    coordinator.prepareFrame(renderer, 0);
    expect(converted, 120);
    source.events.add(
      const DanmakuSourceChange(
        kind: DanmakuSourceChangeKind.ready,
        ruleRevision: 0,
      ),
    );
    coordinator.prepareFrame(renderer, 16000);
    expect(converted, 120);
  });

  test('special candidates keep the per-bucket cap across ready replays', () {
    final source = _Source()
      ..load([for (var i = 0; i < 6; i++) _dm('script$i', 0)..mode = 7]);
    final renderer = _renderer();
    var converted = 0;
    final coordinator = DanmakuWindowCoordinator(
      source: source,
      renderer: renderer,
      preparePerFrame: 120,
      contentOf: (element) {
        converted++;
        return SpecialDanmakuContentItem<void>(
          element.content,
          duration: 1000,
          color: const Color(0xffffffff),
          fontSize: 16,
          translateXTween: ConstantTween<double>(.25),
          translateYTween: ConstantTween<double>(.25),
        );
      },
    );
    addTearDown(renderer.dispose);
    addTearDown(coordinator.dispose);
    addTearDown(source.events.close);
    coordinator.prepareFrame(renderer, 0);
    renderer.present(0, allowUnprepared: true);
    expect(converted, 4);
    expect(renderer.activeSpecialCount, 4);
    source.events.add(
      const DanmakuSourceChange(
        kind: DanmakuSourceChangeKind.ready,
        ruleRevision: 0,
      ),
    );
    coordinator.prepareFrame(renderer, 16000);
    expect(converted, 4);
  });

  testWidgets(
    'paused source ready completes bounded preparation and stops scheduling',
    (tester) async {
      final source = _Source();
      final renderer = _renderer();
      final coordinator = DanmakuWindowCoordinator(
        source: source,
        renderer: renderer,
        contentOf: _content,
      );
      addTearDown(renderer.dispose);
      addTearDown(coordinator.dispose);
      addTearDown(source.events.close);
      final clock = _Clock(advancing: false);
      addTearDown(clock.events.close);
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: MediaQuery(
            data: const MediaQueryData(size: Size(500, 200)),
            child: Center(
              child: SizedBox(
                width: 500,
                height: 200,
                child: DanmakuWindowScreen<void>(
                  renderer: renderer,
                  clock: clock,
                  size: const Size(500, 200),
                  inputChanges: coordinator.updates,
                  monotonicUs: () => 0,
                  frameTimeUs: () => 0,
                  prepareFrame: coordinator.prepareFrame,
                  needsPreparation: () => coordinator.needsPreparation,
                ),
              ),
            ),
          ),
        ),
      );
      expect(renderer.activeCount, 0);
      expect(coordinator.needsPreparation, isFalse);
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.hasRunningAnimations, isFalse);
      source.load([for (var i = 0; i < 6; i++) _dm('arrived$i', 0)]);
      expect(renderer.activeCount, 4);
      expect(coordinator.needsPreparation, isTrue);
      await tester.pumpAndSettle(const Duration(milliseconds: 16));
      expect(renderer.activeCount, 6);
      expect(coordinator.needsPreparation, isFalse);
      expect(tester.hasRunningAnimations, isFalse);
      source.invalidate();
      expect(renderer.activeCount, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
