import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('移动端弹幕屏幕在 TickerMode 静音后停止请求帧', (tester) async {
    late DanmakuController<void> controller;
    Widget screen(bool enabled) => Directionality(
      textDirection: TextDirection.ltr,
      child: MediaQuery(
        data: const MediaQueryData(),
        child: TickerMode(
          enabled: enabled,
          child: DanmakuScreen<void>(
            option: const DanmakuOption(),
            size: const Size(800, 600),
            frameRate: 30,
            createdController: (value) => controller = value,
          ),
        ),
      ),
    );
    await tester.pumpWidget(screen(true));
    controller.addDanmaku(DanmakuContentItem<void>('moving'));
    await tester.pump();
    await tester.pumpWidget(screen(false));
    await tester.pump(const Duration(seconds: 1));
    expect(tester.binding.hasScheduledFrame, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  for (final fps in [30, 60, 90, 120]) {
    testWidgets('$fps FPS 减少帧请求并保持实际经过时间', (tester) async {
      final ticks = <Duration>[];
      final ticker = FrameRateTicker(ticks.add, frameRate: fps)..start();
      await tester.pump();
      expect(ticks, [Duration.zero]);
      expect(tester.binding.hasScheduledFrame, isFalse);
      for (var i = 0; i < 120; i++) {
        await tester.pump(const Duration(microseconds: 8334));
      }
      expect(ticks.length - 1, closeTo(fps, 1));
      expect(ticks.last.inMilliseconds, closeTo(1000, 34));
      ticker.dispose();
      await tester.pump(const Duration(seconds: 1));
      expect(tester.binding.hasScheduledFrame, isFalse);
    });
  }

  testWidgets('暂停、静音和档位切换会取消等待中的帧请求', (tester) async {
    final ticks = <Duration>[];
    final ticker = FrameRateTicker(ticks.add, frameRate: 30)..start();
    await tester.pump();
    ticker.stop();
    await tester.pump(const Duration(seconds: 1));
    expect(ticks.length, 1);
    expect(tester.binding.hasScheduledFrame, isFalse);

    ticker.start();
    await tester.pump();
    ticker.muted = true;
    await tester.pump(const Duration(seconds: 1));
    expect(ticks.length, 2);
    expect(tester.binding.hasScheduledFrame, isFalse);
    ticker.frameRate = 60;
    expect(ticker.muted, isTrue);
    ticker.muted = false;
    await tester.pump();
    expect(ticks.length, 3);
    ticker.dispose();
  });

  testWidgets('跟随屏幕逐帧更新', (tester) async {
    final ticks = <Duration>[];
    final ticker = FrameRateTicker(ticks.add)..start();
    await tester.pump();
    for (var i = 0; i < 120; i++) {
      await tester.pump(const Duration(microseconds: 8334));
    }
    expect(ticks.length, 121);
    ticker.dispose();
  });
}
