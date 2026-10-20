import 'dart:async';

import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/painting.dart';
import 'package:pili_aurora/pages/danmaku/window_renderer.dart';
import 'package:pili_aurora/pages/danmaku/window_coordinator.dart';
import 'package:pili_aurora/grpc/bilibili/community/service/dm/v1.pb.dart';
import 'package:pili_aurora/pages/danmaku/danmaku_model.dart';
import 'package:pili_aurora/pages/danmaku/echo_source.dart';
import 'package:pili_aurora/pages/danmaku/timeline_range.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('echo without server id enters while remote coverage is missing', () {
    final origin = _Source()..state = DanmakuCoverageState.missing;
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
    addTearDown(() {
      coordinator.dispose();
      renderer.dispose();
      source.dispose();
    });
    source.add(DanmakuContentItem('local', selfSend: true), 0);
    coordinator.prepareFrame(renderer, 0);
    renderer.present(0, allowUnprepared: true);
    expect(renderer.interaction.snapshot.single.text, 'local');
    expect(renderer.interaction.snapshot.single.selfSend, isTrue);
  });

  test(
    'send echo stays stable after server arrival and removal invalidates',
    () async {
      final origin = _Source();
      final source = DanmakuEchoSource(origin);
      final changes = <DanmakuSourceChange>[];
      final subscription = source.changes.listen(changes.add);
      final content = DanmakuContentItem<DanmakuExtra>(
        'sent',
        selfSend: true,
        extra: VideoDanmaku(id: 7, mid: 'self'),
      );
      source
        ..add(content, 1000000)
        ..add(content, 1000000);
      final before = source.readRange(0, 2000000).entries.single.element;
      origin.elements.add(
        DanmakuElem(id: Int64(7), idStr: '7', progress: 1100, content: 'sent'),
      );
      final after = source.readRange(0, 2000000).entries.single.element;
      expect(identical(before, after), isTrue);
      expect(source.contentFor(after), same(content));
      source.remove(7);
      expect(source.readRange(0, 2000000).entries, isEmpty);
      expect(changes.map((e) => e.kind), [
        DanmakuSourceChangeKind.ready,
        DanmakuSourceChangeKind.invalidated,
      ]);
      source.dispose();
      await subscription.cancel();
    },
  );
}

class _Source implements DanmakuTimelineSource {
  final elements = <DanmakuElem>[];
  DanmakuCoverageState state = DanmakuCoverageState.loaded;
  @override
  Stream<DanmakuSourceChange> get changes => const Stream.empty();
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
    entries: elements.map(DanmakuTimelineEntry.new),
    coverage: [
      DanmakuRangeCoverage(startUs, endUs, state),
    ],
  );
}
