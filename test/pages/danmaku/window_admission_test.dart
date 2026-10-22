import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/pages/danmaku/window_renderer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('hidden selection releases immediately while unchanged geometry and cache survive', () {
    final renderer = DanmakuWindowRenderer<void>(
      option: const DanmakuOption(fontSize: 20, duration: 4, safeArea: false),
      size: const Size(320, 120),
    );
    addTearDown(renderer.dispose);
    renderer
      ..prepare(
        [
          DanmakuWindowContent('scroll', 0, DanmakuContentItem('scroll')),
          DanmakuWindowContent(
            'top',
            0,
            DanmakuContentItem('top', type: DanmakuItemType.top),
          ),
          DanmakuWindowContent('future', 3000000, DanmakuContentItem('future')),
        ],
        generation: renderer.generation,
        preparedUntilUs: 5000000,
      )
      ..present(500000);
    final handle = renderer.interaction..select('scroll');
    final oldBounds = handle.snapshot
        .firstWhere((s) => s.identity == 'top')
        .bounds;
    final images = renderer.rasters.rasterizations;
    renderer.updateAdmission(
      mediaUs: 500000,
      hideTop: false,
      hideBottom: false,
      hideScroll: true,
      hideSpecial: false,
      massiveMode: false,
      static2Scroll: false,
    );
    expect(handle.snapshot.single.identity, 'top');
    expect(handle.snapshot.single.bounds, oldBounds);
    expect(handle.snapshot.single.selected, isFalse);
    expect(handle.select('scroll'), isFalse);
    expect(renderer.rasters.rasterizations, images);
    expect(renderer.validFromUs, 500000);
    expect(renderer.hasPrepared('future'), isFalse);
    renderer.updateAdmission(
      mediaUs: 500000,
      hideTop: false,
      hideBottom: false,
      hideScroll: false,
      hideSpecial: false,
      massiveMode: false,
      static2Scroll: false,
    );
    expect(handle.snapshot.single.identity, 'top');
    renderer.prepare(
      [
        DanmakuWindowContent('new', 1000000, DanmakuContentItem('scroll')),
      ],
      generation: renderer.generation,
      preparedUntilUs: 2000000,
    );
    renderer.present(1000000);
    expect(handle.snapshot.length, 2);
    expect(renderer.rasters.rasterizations, images);
  });

  test('massive admission changes withdraw future rejection and leave active selection intact', () {
    final renderer = DanmakuWindowRenderer<void>(
      option: const DanmakuOption(fontSize: 20, duration: 4, safeArea: false),
      size: const Size(320, 35),
    );
    addTearDown(renderer.dispose);
    renderer
      ..prepare(
        [
          DanmakuWindowContent('a', 0, DanmakuContentItem('a')),
          DanmakuWindowContent('b', 500000, DanmakuContentItem('b')),
        ],
        generation: renderer.generation,
        preparedUntilUs: 2000000,
      )
      ..present(100000);
    final handle = renderer.interaction..select('a');
    renderer.prepare(
      [
        DanmakuWindowContent('b', 500000, DanmakuContentItem('b')),
      ],
      generation: renderer.generation,
      preparedUntilUs: 2000000,
    );
    renderer.updateAdmission(
      mediaUs: 100000,
      hideTop: false,
      hideBottom: false,
      hideScroll: false,
      hideSpecial: false,
      massiveMode: true,
      static2Scroll: false,
    );
    expect(handle.snapshot.single.selected, isTrue);
    expect(renderer.hasPrepared('b'), isFalse);
    renderer.prepare(
      [
        DanmakuWindowContent('b', 500000, DanmakuContentItem('b')),
      ],
      generation: renderer.generation,
      preparedUntilUs: 2000000,
    );
    renderer.present(500000);
    expect(handle.snapshot.length, 2);
    final generation = renderer.generation;
    renderer.updateAdmission(
      mediaUs: 500000,
      hideTop: false,
      hideBottom: false,
      hideScroll: false,
      hideSpecial: false,
      massiveMode: true,
      static2Scroll: false,
    );
    expect(renderer.generation, generation);
  });
}
