import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:pili_aurora/plugin/pl_player/widgets/player_info_dialog.dart';

Future<void> openDialog(WidgetTester tester, PlayerState state) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) {
          return Scaffold(
            body: TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) =>
                    PlayerInfoDialog(state: state, hwdec: 'no', volume: '0'),
              ),
              child: const Text('打开'),
            ),
          );
        },
      ),
    ),
  );
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('空媒体与静音在窄屏中可查看分类并关闭', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await openDialog(tester, PlayerState());
    expect(find.text('未启用'), findsOneWidget);
    expect(find.text('0 × 0'), findsNothing);
    await tester.tap(find.text('音频'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('0%', skipOffstage: false));
    await tester.pumpAndSettle();
    expect(find.text('0%'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('关闭播放信息'));
    await tester.pumpAndSettle();
    expect(find.byType(PlayerInfoDialog), findsNothing);
  });

  for (final size in [
    const Size(640, 360),
    const Size(1280, 800),
    const Size(320, 640),
  ]) {
    testWidgets('信息弹窗在 $size 下保持紧凑工具栏与可滚动详情', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await openDialog(tester, PlayerState(width: 1920, height: 1080));
      expect(
        tester
            .getSize(find.byKey(const ValueKey('player-info-toolbar')))
            .height,
        48,
      );
      expect(
        tester.getSize(find.byType(Dialog)).height,
        lessThanOrEqualTo(size.height),
      );
      await tester.tap(find.text('来源'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('原始参数（已脱敏）'));
      await tester.pumpAndSettle();
      expect(find.byType(SelectableText), findsOneWidget);
      expect(find.byType(Dialog), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('关闭播放信息'));
      await tester.pumpAndSettle();
      expect(find.byType(PlayerInfoDialog), findsNothing);
    });
  }
  testWidgets('格式化视频参数，来源详情隐藏媒体签名', (tester) async {
    await openDialog(
      tester,
      PlayerState(
        width: 1920,
        height: 1080,
        track: const Track(
          video: VideoTrack(
            '1',
            null,
            null,
            codec: 'hevc',
            fps: 59.94,
            bitrate: 1599963,
          ),
        ),
        playlist: const Playlist([
          Media(
            'https://example.com/video.flv?token=example-secret&sign=example-signature',
          ),
        ]),
      ),
    );
    expect(find.text('59.94 fps'), findsOneWidget);
    expect(find.text('1.6 Mb/s'), findsOneWidget);
    await tester.tap(find.text('来源'));
    await tester.pumpAndSettle();
    expect(find.text('example.com'), findsOneWidget);
    await tester.ensureVisible(find.text('原始参数（已脱敏）'));
    await tester.tap(find.text('原始参数（已脱敏）'));
    await tester.pumpAndSettle();
    final raw = tester
        .widget<SelectableText>(find.byType(SelectableText))
        .data!;
    expect(raw, contains('example.com/video.flv'));
    expect(raw, isNot(contains('example-secret')));
    expect(raw, isNot(contains('example-signature')));
    expect(tester.takeException(), isNull);
  });
}
