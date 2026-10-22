import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:canvas_danmaku/text_renderer.dart' as canvas;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/pages/danmaku/raster_cache.dart';
import 'package:pili_aurora/pages/danmaku/window_renderer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'scaled layout and stroke share dimensions and cache entries stay separate',
    () {
      const option = DanmakuOption(fontSize: 20, strokeWidth: 1);
      final cache = DanmakuRasterCache(option: option, devicePixelRatio: 1);
      addTearDown(cache.clear);
      final normal = DanmakuContentItem<void>('合并弹幕', count: 49);
      final large = DanmakuContentItem<void>(
        '合并弹幕',
        count: 49,
        fontSizeScale: 2,
      );
      final smallRaster = cache.get(normal, rasterize: true)!;
      final largeRaster = cache.get(large, rasterize: true)!;
      expect(cache.length, 2);
      expect(largeRaster.height, greaterThan(smallRaster.height * 1.8));
      expect(largeRaster.width, greaterThan(smallRaster.width * 1.8));
      expect(largeRaster.image!.height, largeRaster.height.ceil());
      expect(cache.get(normal), same(smallRaster));

      final paragraph = (const canvas.DanmakuTextRenderer()).generateParagraph(
        content: large,
        fontSize: 20,
        fontWeight: option.fontWeight,
      );
      final image = (const canvas.DanmakuTextRenderer()).recordDanmakuImage(
        contentParagraph: paragraph,
        content: large,
        fontSize: 20,
        fontWeight: option.fontWeight,
        strokeWidth: 1,
      );
      expect(image.height, largeRaster.image!.height);
      expect(image.width, largeRaster.image!.width);
      paragraph.dispose();
      image.dispose();
    },
  );

  test(
    'reserved track height separates maximally enlarged scrolling items',
    () {
      const option = DanmakuOption(fontSize: 20, lineHeight: 2.4);
      final renderer = DanmakuWindowRenderer<void>(
        option: option,
        size: const Size(800, 300),
        devicePixelRatio: 1,
      );
      addTearDown(renderer.dispose);
      final first = DanmakuContentItem<void>(
        '哈哈哈哈',
        count: 49,
        fontSizeScale: 2,
      );
      final second = DanmakuContentItem<void>(
        '精彩精彩',
        count: 49,
        fontSizeScale: 2,
      );
      expect(
        renderer.prepare(
          [
            DanmakuWindowContent('first', 0, first),
            DanmakuWindowContent('second', 0, second),
          ],
          generation: renderer.generation,
          preparedUntilUs: 10000000,
        ),
        isTrue,
      );
      renderer.present(500000);
      final visible = renderer.interaction.snapshot;
      expect(visible, hasLength(2));
      expect(
        visible.last.bounds.top,
        greaterThanOrEqualTo(visible.first.bounds.bottom),
      );
      final painter = TextPainter(
        text: const TextSpan(
          text: '弹幕',
          style: TextStyle(fontSize: 20, height: 2.4),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      expect(
        visible.first.bounds.height,
        lessThanOrEqualTo(painter.height),
      );
      expect(renderer.canPaintDirectly, isTrue);
      painter.dispose();
    },
  );
}
