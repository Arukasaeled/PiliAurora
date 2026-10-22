import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/pages/danmaku/window_renderer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  DanmakuWindowRenderer<void> create({bool fixed = false, bool future = true}) {
    final renderer = DanmakuWindowRenderer<void>(
      option: DanmakuOption(
        fontSize: 20,
        duration: 4,
        staticDuration: 4,
        scrollFixedVelocity: fixed,
        safeArea: false,
      ),
      size: const Size(320, 120),
    );
    addTearDown(renderer.dispose);
    renderer.prepare(
      [
        DanmakuWindowContent('scroll', 0, DanmakuContentItem('scroll')),
        DanmakuWindowContent(
          'static',
          0,
          DanmakuContentItem('static', type: DanmakuItemType.top),
        ),
        if (future)
          DanmakuWindowContent('future', 3000000, DanmakuContentItem('future')),
      ],
      generation: renderer.generation,
      preparedUntilUs: 6000000,
    );
    renderer.present(1000000);
    return renderer;
  }

  test('speed reanchor keeps pixels and resources, withdraws future and old domain', () {
    final renderer = create();
    final handle = renderer.interaction;
    final before = {for (final s in handle.snapshot) s.identity: s.bounds};
    final images = renderer.rasters.rasterizations;
    final generation = renderer.generation;
    renderer.updateTiming(
      mediaUs: 1000000,
      duration: 2,
      staticDuration: 4,
      scrollFixedVelocity: false,
    );
    expect(handle.isValid, isTrue);
    expect(renderer.generation, greaterThan(generation));
    expect(renderer.validFromUs, 1000000);
    expect(renderer.hasPrepared('future'), isFalse);
    for (final s in handle.snapshot) {
      expect(s.bounds, before[s.identity]);
      expect(handle.hitTest(s.bounds.center)?.identity, s.identity);
    }
    renderer.present(1500000, allowUnprepared: true);
    final scroll = handle.snapshot.firstWhere((s) => s.identity == 'scroll');
    final velocity = (320 + scroll.bounds.width) / 2000;
    expect(
      scroll.bounds.left,
      closeTo(before['scroll']!.left - velocity * 500, .001),
    );
    expect(renderer.rasters.rasterizations, images);
    expect(renderer.present(999999), isFalse);
    expect(handle.snapshot, isEmpty);
  });

  test('repeated static duration changes use elapsed lifetime across cuts', () {
    final renderer = create()
      ..updateTiming(
        mediaUs: 1000000,
        duration: 4,
        staticDuration: 6,
        scrollFixedVelocity: false,
      )
      ..updateTiming(
        mediaUs: 3000000,
        duration: 4,
        staticDuration: 3,
        scrollFixedVelocity: false,
      );
    expect(
      renderer.interaction.snapshot.where((s) => s.identity == 'static'),
      isEmpty,
    );
  });

  test(
    'held scroll releases at updated speed and remains fixed during change',
    () {
      final renderer = create(fixed: true);
      final handle = renderer.interaction..select('scroll');
      final before = handle.snapshot
          .firstWhere((s) => s.identity == 'scroll')
          .bounds;
      renderer.updateTiming(
        mediaUs: 2000000,
        duration: 2,
        staticDuration: 4,
        scrollFixedVelocity: true,
      );
      expect(
        handle.snapshot.firstWhere((s) => s.identity == 'scroll').bounds,
        before,
      );
      handle.clearSelection();
      renderer.present(2500000, allowUnprepared: true);
      expect(
        handle.snapshot.firstWhere((s) => s.identity == 'scroll').bounds.left,
        closeTo(before.left - 80, .001),
      );
    },
  );

  test(
    'shortening held static lifetime expires on release; equal timing is inert',
    () {
      final renderer = create(future: false);
      final generation = renderer.generation;
      renderer.updateTiming(
        mediaUs: 1000000,
        duration: 4,
        staticDuration: 4,
        scrollFixedVelocity: false,
      );
      expect(renderer.generation, generation);
      renderer.present(3000000);
      final handle = renderer.interaction..select('static');
      renderer.updateTiming(
        mediaUs: 5000000,
        duration: 4,
        staticDuration: 2,
        scrollFixedVelocity: false,
      );
      expect(handle.snapshot.single.selected, isTrue);
      handle.clearSelection();
      expect(handle.snapshot, isEmpty);
      expect(renderer.activeBytes, 0);
    },
  );
}
