import 'dart:ui' as ui;

import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/animation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/pages/danmaku/window_renderer.dart';
import '../../../tool/experiments/danmaku/baseline/windows_renderer.dart';

const _size = Size(320, 120);
const _option = DanmakuOption(fontSize: 20, duration: 2, safeArea: false);
DanmakuContentItem<void> _text(String text) =>
    DanmakuContentItem(text, color: const Color(0xffffffff));

Future<List<int>> _pixels(
  DanmakuWindowRenderer<void> renderer, {
  double opacity = 1,
}) => _draw((canvas) => renderer.paint(canvas, _size, opacity: opacity));

Future<List<int>> _draw(void Function(Canvas) paint) async {
  final recorder = ui.PictureRecorder();
  paint(Canvas(recorder));
  final picture = recorder.endRecording();
  final image = await picture.toImage(320, 120);
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  final result = data!.buffer.asUint8List().toList();
  image.dispose();
  picture.dispose();
  return result;
}

SpecialDanmakuContentItem<void> _special({
  int duration = 2000,
  double fontSize = 20,
}) => SpecialDanmakuContentItem<void>(
  'special',
  duration: duration,
  color: const Color(0xffffffff),
  fontSize: fontSize,
  alphaTween: Tween<double>(begin: .2, end: .8),
  translateXTween: Tween<double>(begin: .1, end: .6),
  translateYTween: ConstantTween<double>(.25),
  rotateZ: .2,
  translationStartDelay: 400,
  translationDuration: 1000,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final ratio in [1.0, 2.0]) {
    test(
      'special script pixels match existing renderer at DPR $ratio',
      () async {
        final old = WindowsDanmakuRenderer<void>(
          option: _option,
          size: _size,
          devicePixelRatio: ratio,
        );
        final next = DanmakuWindowRenderer<void>(
          option: _option,
          size: _size,
          devicePixelRatio: ratio,
        );
        addTearDown(old.dispose);
        addTearDown(next.dispose);
        old
          ..add(_special())
          ..advance(const Duration(milliseconds: 500));
        next
          ..prepare(
            [DanmakuWindowContent('special', 1000000, _special())],
            generation: next.generation,
            preparedUntilUs: 4000000,
          )
          ..present(1500000);
        expect(next.activeSpecialCount, 1);
        expect(
          await _pixels(next),
          await _draw((canvas) => old.paint(canvas, _size)),
        );
        final bytes = next.activeBytes;
        next.present(1500000);
        expect(next.activeBytes, bytes);
        next.present(3000000);
        expect(next.activeBytes, 0);
      },
    );
  }

  test('special quota follows exact lifetimes and future entries do not occupy slots', () {
    final renderer = DanmakuWindowRenderer<void>(option: _option, size: _size);
    addTearDown(renderer.dispose);
    renderer
      ..prepare(
        [
          for (var index = 0; index < 33; index++)
            DanmakuWindowContent(index, 0, _special(duration: 10000)),
          DanmakuWindowContent('future', 10000000, _special(duration: 10000)),
        ],
        generation: renderer.generation,
        preparedUntilUs: 20000000,
      )
      ..present(9994000);
    expect(renderer.activeSpecialCount, 32);
    renderer.present(9999000);
    expect(renderer.activeSpecialCount, 32);
    renderer.present(10000000);
    expect(renderer.activeSpecialCount, 1);
    renderer.present(20000000);
    expect(renderer.activeBytes, 0);
  });

  test('special resource budget and invalid script measurements reject without active references', () {
    final renderer = DanmakuWindowRenderer<void>(
      option: _option,
      size: _size,
      maxActiveBytes: 1,
    );
    addTearDown(renderer.dispose);
    renderer
      ..prepare(
        [
          DanmakuWindowContent(
            'invalid',
            0,
            _special(fontSize: double.infinity),
          ),
          DanmakuWindowContent('budget', 0, _special()),
        ],
        generation: renderer.generation,
        preparedUntilUs: 3000000,
      )
      ..present(500000);
    expect(renderer.activeSpecialCount, 0);
    expect(renderer.activeBytes, 0);
  });

  for (final ratio in [1.0, 2.0]) {
    test('window pixels match the existing renderer at DPR $ratio', () async {
      final current = WindowsDanmakuRenderer<void>(
        option: _option,
        size: _size,
        devicePixelRatio: ratio,
      );
      final next = DanmakuWindowRenderer<void>(
        option: _option,
        size: _size,
        devicePixelRatio: ratio,
      );
      addTearDown(current.dispose);
      addTearDown(next.dispose);
      current
        ..add(_text('same pixels'))
        ..advance(const Duration(milliseconds: 500));
      next
        ..prepare(
          [DanmakuWindowContent('a', 0, _text('same pixels'))],
          generation: next.generation,
          preparedUntilUs: 3000000,
        )
        ..present(500000);
      expect(
        await _pixels(next),
        await _draw((canvas) => current.paint(canvas, _size)),
      );
    });
  }

  test(
    'prepare measures ahead; media-time presentation and hit geometry agree',
    () async {
      final renderer = DanmakuWindowRenderer<void>(
        option: _option,
        size: _size,
      );
      addTearDown(renderer.dispose);
      final content = _text('window item');
      expect(
        renderer.prepare(
          [
            DanmakuWindowContent('first', 0, content),
            DanmakuWindowContent('future', 1000000, _text('future')),
          ],
          generation: renderer.generation,
          preparedUntilUs: 4000000,
        ),
        isTrue,
      );
      expect(renderer.activeCount, 0);
      expect(renderer.rasters.rasterizations, 0);
      final layout = renderer.rasters.get(content)!;
      renderer.present(500000);
      final x = 320 - (320 + layout.width) / 2000 * 500;
      final hit = renderer.hitTest(
        Offset(x + layout.width / 2, layout.height / 2),
      );
      expect(hit!.identity, 'first');
      expect(hit.bounds.left, closeTo(x, 0.001));
      final before = await _pixels(renderer);
      expect(before.any((byte) => byte != 0), isTrue);
      final rasterizations = renderer.rasters.rasterizations;
      renderer.present(500000);
      expect(await _pixels(renderer), before);
      expect(renderer.rasters.rasterizations, rasterizations);
    },
  );

  test(
    'expiry releases active clones; cached backseek restores identical pixels',
    () async {
      final renderer = DanmakuWindowRenderer<void>(
        option: _option,
        size: _size,
      );
      addTearDown(renderer.dispose);
      renderer
        ..prepare(
          [DanmakuWindowContent('a', 0, _text('cached'))],
          generation: renderer.generation,
          preparedUntilUs: 4000000,
        )
        ..present(600000);
      final expected = await _pixels(renderer);
      expect(renderer.activeBytes, greaterThan(0));
      final images = renderer.rasters.rasterizations;
      renderer.present(3000000);
      expect(renderer.activeCount, 0);
      expect(renderer.activeBytes, 0);
      renderer.present(600000);
      expect(await _pixels(renderer), expected);
      expect(renderer.rasters.rasterizations, images);
      renderer.trimBefore(1000000);
      expect(renderer.present(600000), isFalse);
      expect(renderer.activeBytes, 0);
    },
  );

  test(
    'active raster budget and reset generation prevent invalid presentation',
    () {
      final renderer = DanmakuWindowRenderer<void>(
        option: _option,
        size: _size,
        maxActiveBytes: 1,
      );
      addTearDown(renderer.dispose);
      final generation = renderer.generation;
      renderer
        ..prepare(
          [DanmakuWindowContent('a', 0, _text('budget'))],
          generation: generation,
          preparedUntilUs: 4000000,
        )
        ..present(100000);
      expect(renderer.activeBytes, 0);
      expect(renderer.rasters.rasterizations, 0);
      renderer.reset(800000);
      expect(
        renderer.prepare(
          [DanmakuWindowContent('stale', 900000, _text('stale'))],
          generation: generation,
          preparedUntilUs: 4000000,
        ),
        isFalse,
      );
      expect(renderer.validFromUs, 800000);
      expect(renderer.validUntilUs, 800000);
      expect(renderer.hitTest(Offset.zero), isNull);
    },
  );

  test('group opacity is applied once to the visible raster frame', () async {
    final renderer = DanmakuWindowRenderer<void>(option: _option, size: _size);
    addTearDown(renderer.dispose);
    renderer
      ..prepare(
        [DanmakuWindowContent('a', 0, _text('opacity'))],
        generation: renderer.generation,
        preparedUntilUs: 3000000,
      )
      ..present(500000);
    final full = await _pixels(renderer);
    final half = await _pixels(renderer, opacity: 0.5);
    var fullAlpha = 0;
    var halfAlpha = 0;
    for (var i = 3; i < full.length; i += 4) {
      if (full[i] > fullAlpha) fullAlpha = full[i];
      if (half[i] > halfAlpha) halfAlpha = half[i];
    }
    expect(fullAlpha, greaterThan(0));
    expect(halfAlpha, closeTo(fullAlpha / 2, 1));
  });
}
