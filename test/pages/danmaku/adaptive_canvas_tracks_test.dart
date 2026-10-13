import 'dart:math' as math;

import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

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
