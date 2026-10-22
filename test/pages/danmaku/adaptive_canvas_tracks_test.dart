import 'dart:math' as math;

import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../tool/experiments/danmaku/baseline/windows_renderer.dart';

const _size = Size(800, 360);
const _fontSize = 20.0;

Widget _host(Widget child) => Directionality(
  textDirection: TextDirection.ltr,
  child: MediaQuery(
    data: const MediaQueryData(size: _size),
    child: Center(
      child: SizedBox.fromSize(size: _size, child: child),
    ),
  ),
);

Widget _screen({
  required DanmakuOption option,
  required ValueChanged<DanmakuController<void>> onCreated,
}) => _host(
  DanmakuScreen<void>(
    option: option,
    size: _size,
    createdController: onCreated,
  ),
);

double _baseTrackHeight(double lineHeight) {
  final configuredPainter = TextPainter(
    text: TextSpan(
      text: '弹幕',
      style: TextStyle(fontSize: _fontSize, height: lineHeight),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  final configuredHeight = configuredPainter.height;
  configuredPainter.dispose();
  final normalPainter = TextPainter(
    text: const TextSpan(
      text: '弹幕',
      style: TextStyle(fontSize: _fontSize),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  final normalHeight = normalPainter.height + 1.5;
  normalPainter.dispose();
  return math.max(configuredHeight, normalHeight);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('同尺寸同内容在 Canvas 与 Windows 得到一致普通排轨结果', (tester) async {
    const option = DanmakuOption(fontSize: _fontSize, lineHeight: 1);
    late DanmakuController<void> canvas;
    await tester.pumpWidget(
      _screen(option: option, onCreated: (value) => canvas = value),
    );
    final windows = WindowsDanmakuRenderer<void>(option: option, size: _size);
    addTearDown(windows.dispose);
    (bool, int) locate(DanmakuController<void> controller, String text) {
      final fixed = controller.staticDanmaku.indexWhere(
        (item) => item?.content.text == text,
      );
      if (fixed >= 0) return (false, fixed);
      return (
        true,
        controller.scrollDanmaku.indexWhere(
          (items) => items.any((item) => item.content.text == text),
        ),
      );
    }

    final inputs = [
      ('scroll', DanmakuItemType.scroll, 1.0),
      ('fixed', DanmakuItemType.top, 1.0),
      ('expanded scroll', DanmakuItemType.scroll, 2.0),
      ('expanded bottom', DanmakuItemType.bottom, 2.0),
      ('another expanded', DanmakuItemType.scroll, 3.0),
      ('expanded top', DanmakuItemType.top, 2.0),
    ];
    for (final (text, type, scale) in inputs) {
      DanmakuContentItem<void> content() =>
          DanmakuContentItem<void>(text, type: type, fontSizeScale: scale);
      expect(
        canvas.addDanmaku(content()),
        windows.add(content()),
        reason: text,
      );
      expect(
        locate(canvas, text),
        locate(windows.controller, text),
        reason: text,
      );
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('两端命中查询采用相同放大边界并在清空后失效', (tester) async {
    const option = DanmakuOption(fontSize: _fontSize, lineHeight: 1);
    late DanmakuController<void> canvas;
    await tester.pumpWidget(
      _screen(option: option, onCreated: (value) => canvas = value),
    );
    final windows = WindowsDanmakuRenderer<void>(option: option, size: _size);
    addTearDown(windows.dispose);
    for (final controller in [canvas, windows.controller]) {
      expect(
        controller.addDanmaku(
          DanmakuContentItem<void>(
            'expanded',
            type: DanmakuItemType.top,
            fontSizeScale: 2,
          ),
        ),
        isTrue,
      );
      final item = controller.staticDanmaku.first!;
      final inside = Offset(item.xPosition + item.width / 2, item.height - 1);
      expect(controller.findSingleDanmaku(inside)?.$2, same(item));
      expect(controller.findDanmaku(inside).map((entry) => entry.$2), [item]);
      expect(
        controller.findSingleDanmaku(Offset(item.xPosition - 1, 1)),
        isNull,
      );
      item.expired = true;
      expect(controller.findSingleDanmaku(inside), isNull);
      controller.clear();
      expect(controller.findDanmaku(inside), isEmpty);
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('两端海量模式共用活动额度，清空后释放名额', (tester) async {
    const option = DanmakuOption(fontSize: _fontSize, massiveMode: true);
    late DanmakuController<void> canvas;
    await tester.pumpWidget(
      _screen(option: option, onCreated: (value) => canvas = value),
    );
    final windows = WindowsDanmakuRenderer<void>(option: option, size: _size);
    addTearDown(windows.dispose);
    for (final controller in [canvas, windows.controller]) {
      for (var index = 0; index < DanmakuDisplayLimits.maxActive; index++) {
        expect(controller.addDanmaku(DanmakuContentItem<void>('x')), isTrue);
      }
      expect(controller.activeCount, DanmakuDisplayLimits.maxActive);
      expect(
        controller.addDanmaku(DanmakuContentItem<void>('overflow')),
        isFalse,
      );
      controller.clear();
      expect(controller.activeCount, 0);
      expect(controller.addDanmaku(DanmakuContentItem<void>('next')), isTrue);
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('固定项有效期结束后可立即复用轨道并释放旧图片', (tester) async {
    late DanmakuController<void> controller;
    await tester.pumpWidget(
      _screen(
        option: const DanmakuOption(fontSize: _fontSize, staticDuration: .05),
        onCreated: (value) => controller = value,
      ),
    );
    controller.addDanmaku(
      DanmakuContentItem<void>('old', type: DanmakuItemType.top),
    );
    await tester.pump();
    final old = controller.staticDanmaku.first!;
    final image = old.image!;
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      controller.addDanmaku(
        DanmakuContentItem<void>('replacement', type: DanmakuItemType.top),
      ),
      isTrue,
    );
    expect(controller.staticDanmaku.first!.content.text, 'replacement');
    expect(image.debugDisposed, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('enlarged scrolling items reserve rows and remain hittable', (
    tester,
  ) async {
    late DanmakuController<void> controller;
    await tester.pumpWidget(
      _screen(
        option: const DanmakuOption(fontSize: _fontSize, lineHeight: 3),
        onCreated: (value) => controller = value,
      ),
    );

    controller.addDanmaku(DanmakuContentItem<void>('old row'));
    controller.updateOption(controller.option.copyWith(lineHeight: 1));
    expect(controller.scrollDanmaku.every((track) => track.isEmpty), isTrue);

    final first = DanmakuContentItem<void>('large one', fontSizeScale: 2);
    final second = DanmakuContentItem<void>('large two', fontSizeScale: 2);
    final fixed = DanmakuContentItem<void>(
      'fixed below scrolling',
      type: DanmakuItemType.top,
    );
    expect(controller.addDanmaku(first), isTrue);
    expect(controller.addDanmaku(second), isTrue);
    expect(controller.addDanmaku(fixed), isTrue);

    final firstTrack = controller.scrollDanmaku.indexWhere(
      (track) => track.any((item) => identical(item.content, first)),
    );
    final secondTrack = controller.scrollDanmaku.indexWhere(
      (track) => track.any((item) => identical(item.content, second)),
    );
    final firstItem = controller.scrollDanmaku[firstTrack].single;
    final span = (firstItem.height / _baseTrackHeight(1)).ceil();
    final fixedTrack = controller.staticDanmaku.indexWhere(
      (item) => identical(item?.content, fixed),
    );
    final fixedItem = controller.staticDanmaku[fixedTrack]!;
    expect(span, greaterThan(1));
    expect(fixedItem.height, lessThanOrEqualTo(_baseTrackHeight(1)));
    expect(secondTrack, greaterThanOrEqualTo(firstTrack + span));
    expect(fixedTrack, greaterThanOrEqualTo(secondTrack + span));

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final hit = controller.findSingleDanmaku(
      Offset(firstItem.xPosition + 1, _baseTrackHeight(1) + 1),
    );
    expect(hit?.$2, same(firstItem));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('enlarged fixed items reserve rows at both edges', (
    tester,
  ) async {
    late DanmakuController<void> controller;
    await tester.pumpWidget(
      _screen(
        option: const DanmakuOption(fontSize: _fontSize, lineHeight: 1),
        onCreated: (value) => controller = value,
      ),
    );

    final top = DanmakuContentItem<void>(
      'large top',
      type: DanmakuItemType.top,
      fontSizeScale: 2,
    );
    final next = DanmakuContentItem<void>(
      'next top',
      type: DanmakuItemType.top,
    );
    final bottom = DanmakuContentItem<void>(
      'large bottom',
      type: DanmakuItemType.bottom,
      fontSizeScale: 2,
    );
    final scrolling = DanmakuContentItem<void>(
      'large scrolling',
      fontSizeScale: 2,
    );
    expect(controller.addDanmaku(top), isTrue);
    expect(controller.addDanmaku(next), isTrue);
    expect(controller.addDanmaku(bottom), isTrue);
    expect(controller.addDanmaku(scrolling), isTrue);

    final topTrack = controller.staticDanmaku.indexWhere(
      (item) => identical(item?.content, top),
    );
    final nextTrack = controller.staticDanmaku.indexWhere(
      (item) => identical(item?.content, next),
    );
    final bottomTrack = controller.staticDanmaku.indexWhere(
      (item) => identical(item?.content, bottom),
    );
    final scrollingTrack = controller.scrollDanmaku.indexWhere(
      (track) => track.any((item) => identical(item.content, scrolling)),
    );
    final topItem = controller.staticDanmaku[topTrack]!;
    final span = (topItem.height / _baseTrackHeight(1)).ceil();
    expect(span, greaterThan(1));
    expect(topTrack, 0);
    expect(nextTrack, greaterThanOrEqualTo(topTrack + span));
    expect(bottomTrack, controller.trackCount - span);
    expect(scrollingTrack, greaterThanOrEqualTo(nextTrack + 1));

    await tester.pump();
    final bottomItem = controller.staticDanmaku[bottomTrack]!;
    final lowerPart =
        bottomTrack * _baseTrackHeight(1) + _baseTrackHeight(1) + 1;
    final hit = controller.findSingleDanmaku(
      Offset(bottomItem.xPosition + bottomItem.width / 2, lowerPart),
    );
    expect(hit?.$2, same(bottomItem));
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
