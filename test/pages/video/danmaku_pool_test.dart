import 'dart:typed_data';

import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/pages/danmaku/danmaku_model.dart';
import 'package:pili_aurora/pages/danmaku/display_binding.dart';
import 'package:pili_aurora/pages/danmaku/interaction.dart';
import 'package:pili_aurora/pages/danmaku/window_renderer.dart';
import 'package:pili_aurora/pages/video/controller.dart';
import 'package:pili_aurora/pages/video/introduction/ugc/controller.dart';
import 'package:pili_aurora/pages/video/widgets/header_control.dart';
import 'package:pili_aurora/plugin/pl_player/controller.dart';
import 'package:pili_aurora/utils/storage.dart';

void main() {
  testWidgets(
    'pool refresh obtains the current handle after seek and media replacement',
    (tester) async {
      GStorage.setting = await Hive.openBox<dynamic>(
        'pool-test',
        bytes: Uint8List(0),
      );
      Get.put<UgcIntroController>(_Intro(), tag: 'pool-test');
      final renderer = DanmakuWindowRenderer<DanmakuExtra>(
        option: const DanmakuOption(),
        size: const Size(640, 360),
      );
      renderer
        ..prepare(
          [
            DanmakuWindowContent(
              'one',
              0,
              DanmakuContentItem<DanmakuExtra>(
                'visible comment',
                extra: VideoDanmaku(id: 7, mid: 'self'),
              ),
            ),
          ],
          generation: renderer.generation,
          preparedUntilUs: 2000000,
        )
        ..present(0);
      final player = _Player()
        ..danmakuDisplay = DanmakuDisplayBinding(
          interaction: () => renderer.interaction,
          clear: () => renderer.reset(0),
        );
      await tester.pumpWidget(MaterialApp(home: _Header(player)));
      tester.state<_HeaderState>(find.byType(_Header)).showDanmakuPool();
      await tester.pump();
      expect(find.text('visible comment'), findsOneWidget);
      renderer
        ..suspendPresentation()
        ..present(100000);
      await tester.tap(find.byIcon(Icons.refresh).first);
      await tester.pump();
      expect(find.text('visible comment'), findsOneWidget);
      player.danmakuDisplay = null;
      await tester.tap(find.byIcon(Icons.refresh).first);
      await tester.pump();
      expect(find.text('visible comment'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      renderer.dispose();
      Get.reset();
      await GStorage.setting.close();
    },
  );
}

class _Header extends HeaderControl {
  _Header(PlPlayerController player)
    : super(
        controller: player,
        videoDetailCtr: _Detail(),
        heroTag: 'pool-test',
        isPortrait: true,
      );
  @override
  HeaderControlState createState() => _HeaderState();
}

class _HeaderState extends HeaderControlState {
  Widget? sheet;
  @override
  Widget build(BuildContext context) => Scaffold(body: sheet);
  @override
  Future<void> showBottomSheet(
    StatefulWidgetBuilder builder, {
    ValueGetter<EdgeInsets>? padding,
  }) async {
    setState(() => sheet = StatefulBuilder(builder: builder));
  }
}

class _Detail implements VideoDetailController {
  @override
  bool get isFileSource => false;
  @override
  bool get isUgc => true;
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Intro extends GetxController implements UgcIntroController {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Player implements PlPlayerController {
  @override
  DanmakuDisplayBinding? danmakuDisplay;
  @override
  DanmakuInteractionHandle<DanmakuExtra>? get danmakuInteraction =>
      danmakuDisplay?.interaction();
  @override
  bool get darkVideoPage => false;
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
