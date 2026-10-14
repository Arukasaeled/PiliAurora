import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:canvas_danmaku/special_danmaku_painter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

const _size = Size(800, 360);

Future<DanmakuController<void>> _mount(WidgetTester tester) async {
  late DanmakuController<void> controller;
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: MediaQuery(
        data: const MediaQueryData(size: _size),
        child: Center(
          child: SizedBox.fromSize(
            size: _size,
            child: DanmakuScreen<void>(
              option: const DanmakuOption(
                fontSize: 20,
                duration: 8,
                massiveMode: true,
              ),
              size: _size,
              createdController: (value) => controller = value,
            ),
          ),
        ),
      ),
    ),
  );
  return controller;
}

void main() {
  testWidgets('缓存后的普通弹幕连续绘制不重建 widget', (tester) async {
    final controller = await _mount(tester);
    for (var i = 0; i < 120; i++) {
      expect(controller.addDanmaku(DanmakuContentItem<void>('弹幕 $i')), isTrue);
    }
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    final item = controller.scrollDanmaku.first.first;
    final startX = item.xPosition;
    final image = item.image;
    var rebuilds = 0;
    var emptyLayerRepaints = 0;
    final emptyPainter = tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((widget) => widget.painter)
        .whereType<SpecialDanmakuPainter>()
        .single;
    void onEmptyRepaint() => emptyLayerRepaints++;
    emptyPainter.addListener(onEmptyRepaint);
    final previous = debugOnRebuildDirtyWidget;
    debugOnRebuildDirtyWidget = (_, _) => rebuilds++;
    try {
      for (var frame = 0; frame < 120; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
    } finally {
      debugOnRebuildDirtyWidget = previous;
    }
    expect(item.xPosition, lessThan(startX));
    expect(item.image, same(image));
    expect(rebuilds, 0);
    expect(emptyLayerRepaints, 0);
    emptyPainter.removeListener(onEmptyRepaint);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('点击仅悬停选中的弹幕，其他弹幕继续移动并复用图片', (tester) async {
    final controller = await _mount(tester);
    controller.addDanmaku(DanmakuContentItem<void>('selected'));
    controller.addDanmaku(DanmakuContentItem<void>('moving'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    final selected = controller.scrollDanmaku[0].single;
    final moving = controller.scrollDanmaku[1].single;
    final hit = controller.findSingleDanmaku(Offset(selected.xPosition + 1, 1));
    expect(hit?.$2, same(selected));
    selected.suspend = true;
    final selectedX = selected.xPosition;
    final movingX = moving.xPosition;
    final selectedImage = selected.image;
    final movingImage = moving.image;
    await tester.pump(const Duration(milliseconds: 200));
    expect(selected.xPosition, selectedX);
    expect(moving.xPosition, lessThan(movingX));
    expect(selected.image, same(selectedImage));
    expect(moving.image, same(movingImage));
    expect(
      controller.findSingleDanmaku(Offset(selected.xPosition + 1, 1))?.$2,
      same(selected),
    );
    selected.suspend = false;
    await tester.pump(const Duration(milliseconds: 100));
    final expectedDistance = (_size.width + selected.width) / 8000 * 100;
    expect(selectedX - selected.xPosition, closeTo(expectedDistance, .01));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('更改速度、暂停恢复和清空后，重绘使用当前状态', (tester) async {
    final controller = await _mount(tester);
    controller.addDanmaku(DanmakuContentItem<void>('speed'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final item = controller.scrollDanmaku.first.single;
    final initialX = item.xPosition;
    controller.updateOption(controller.option.copyWith(duration: 4));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      initialX - item.xPosition,
      closeTo((_size.width + item.width) / 4000 * 100, .01),
    );
    controller.pause();
    final pausedX = item.xPosition;
    await tester.pump(const Duration(seconds: 1));
    expect(item.xPosition, pausedX);
    controller.resume();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(item.xPosition, lessThan(pausedX));
    controller.pause();
    controller.clear();
    await tester.pump();
    expect(controller.scrollDanmaku.every((track) => track.isEmpty), isTrue);
    expect(controller.findSingleDanmaku(Offset(pausedX + 1, 1)), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('高级弹幕复用绘制委托时仍推进时间并按期清理', (tester) async {
    final controller = await _mount(tester);
    controller.addDanmaku(
      SpecialDanmakuContentItem<void>(
        'special',
        duration: 500,
        color: const Color(0xFFFFFFFF),
        fontSize: 20,
        translateXTween: Tween(begin: .1, end: .5),
        translateYTween: ConstantTween(.1),
        alphaTween: Tween(begin: .3, end: 1),
      ),
    );
    final item = controller.specialDanmaku.single;
    final image = item.image;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(item.drawTick, isNotNull);
    expect(item.expired, isFalse);
    expect(item.image, same(image));
    for (var i = 0; i < 24; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(controller.specialDanmaku, isEmpty);
    expect(item.image, isNull);
    expect(tester.binding.hasScheduledFrame, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
