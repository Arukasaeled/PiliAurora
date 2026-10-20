import 'dart:ui' as ui;

import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/pages/danmaku/window_renderer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    final loader = FontLoader('DanmakuDigits')
      ..addFont(rootBundle.load('assets/fonts/digital_id_num.ttf'));
    await loader.load();
  });

  test('不同字体和 DPI 的上下文交错布局与栅格时互不覆盖', () async {
    const first = DanmakuTextRenderer(fontFamily: 'Ahem');
    const second = DanmakuTextRenderer(
      fontFamily: 'DanmakuDigits',
      devicePixelRatio: 2,
    );
    final content = DanmakuContentItem<void>('123456', selfSend: true);
    final firstLayout = first.generateParagraph(
      content: content,
      fontSize: 24,
      fontWeight: 4,
    );
    final secondLayout = second.generateParagraph(
      content: content,
      fontSize: 24,
      fontWeight: 4,
    );
    expect(
      firstLayout.maxIntrinsicWidth,
      isNot(secondLayout.maxIntrinsicWidth),
    );
    firstLayout.dispose();
    secondLayout.dispose();
    ui.Image render(DanmakuTextRenderer renderer) {
      final paragraph = renderer.generateParagraph(
        content: content,
        fontSize: 24,
        fontWeight: 4,
      );
      try {
        return renderer.recordDanmakuImage(
          contentParagraph: paragraph,
          content: content,
          fontSize: 24,
          fontWeight: 4,
          strokeWidth: 2,
        );
      } finally {
        paragraph.dispose();
      }
    }

    final a = render(first);
    final b = render(second);
    final again = render(first);
    addTearDown(() {
      a.dispose();
      b.dispose();
      again.dispose();
    });
    expect(b.height, isNot(a.height));
    expect((again.width, again.height), (a.width, a.height));
    final pixels = await a.toByteData(format: ui.ImageByteFormat.rawRgba);
    final repeated = await again.toByteData(format: ui.ImageByteFormat.rawRgba);
    expect(
      repeated!.buffer.asUint8List(),
      orderedEquals(pixels!.buffer.asUint8List()),
    );
  });

  test('共享高级内容的图层分别持有栅格边界', () {
    final a = DanmakuWindowRenderer<void>(
      option: const DanmakuOption(),
      size: const Size(400, 120),
      fontFamily: 'Ahem',
    );
    final b = DanmakuWindowRenderer<void>(
      option: const DanmakuOption(),
      size: const Size(400, 120),
      fontFamily: 'DanmakuDigits',
      devicePixelRatio: 2,
    );
    addTearDown(() {
      a.dispose();
      b.dispose();
    });
    final content = SpecialDanmakuContentItem<void>(
      '123456',
      duration: 1000,
      fontSize: 24,
      color: const Color(0xFFFFFFFF),
      translateXTween: ConstantTween<double>(0),
      translateYTween: ConstantTween<double>(0),
    );
    void present(DanmakuWindowRenderer<void> renderer) {
      expect(
        renderer.prepare(
          [DanmakuWindowContent('special', 0, content)],
          generation: renderer.generation,
          preparedUntilUs: 2000000,
        ),
        isTrue,
      );
      renderer.present(500000);
    }

    present(a);
    final original = a.interaction.snapshot.single.bounds;
    present(b);
    final other = b.interaction.snapshot.single.bounds;
    expect(a.interaction.snapshot.single.bounds, original);
    expect(other.width, isNot(original.width));
    a.requestConfiguration(
      option: a.rasters.option,
      size: const Size(400, 120),
      devicePixelRatio: 1,
      fontFamily: 'DanmakuDigits',
    );
    expect(a.prepareConfiguration(), isTrue);
    a.present(500000, allowUnprepared: true);
    expect(
      a.interaction.snapshot.single.bounds.width,
      closeTo(other.width, .001),
    );
    expect(b.interaction.snapshot.single.bounds, other);
    final first = a.interaction.snapshot.single.bounds;
    expect(a.activeBytes, first.width.ceil() * first.height.ceil() * 4);
    expect(
      b.activeBytes,
      (other.width * 2).ceil() * (other.height * 2).ceil() * 4,
    );
  });

  testWidgets('并存图层使用各自 DPI，密度变化重新栅格且保留表情资源', (tester) async {
    final controllers = <int, DanmakuController<void>>{};
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawColor(const Color(0xFFFF0000), ui.BlendMode.src);
    final picture = recorder.endRecording();
    final emote = picture.toImageSync(8, 8);
    picture.dispose();
    Widget layer(int id, double ratio) => MediaQuery(
      data: MediaQueryData(devicePixelRatio: ratio),
      child: SizedBox(
        width: 300,
        height: 120,
        child: DanmakuScreen<void>(
          key: ValueKey(id),
          size: const Size(300, 120),
          option: const DanmakuOption(fontSize: 20),
          createdController: (controller) => controllers[id] = controller,
        ),
      ),
    );
    Future<void> mount(double ratio) => tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Row(children: [layer(1, 1), layer(2, ratio)]),
      ),
    );
    await mount(2);
    controllers[1]!.addDanmaku(DanmakuContentItem<void>('same'));
    controllers[2]!.addDanmaku(DanmakuContentItem<void>('same'));
    await tester.pump();
    final a = controllers[1]!.scrollDanmaku.first.single;
    final b = controllers[2]!.scrollDanmaku.first.single;
    expect(a.width, b.width);
    expect(a.image!.width, a.width.ceil());
    expect(b.image!.width, (b.width * 2).ceil());
    controllers[2]!.addDanmaku(
      DanmakuContentItem<void>(
        '[e]',
        inlineImages: [
          DanmakuInlineImage(
            placeholder: '[e]',
            image: emote,
            width: 8,
            height: 8,
          ),
        ],
      ),
    );
    await tester.pump();
    controllers[2]!.pause();
    await mount(1);
    await tester.pump();
    expect(b.image!.width, b.width.ceil());
    expect(emote.debugDisposed, isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(emote.debugDisposed, isTrue);
  });
}
