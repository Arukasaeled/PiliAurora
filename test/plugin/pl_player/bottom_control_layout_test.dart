import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/common/widgets/player_bar.dart';
import 'package:pili_aurora/common/widgets/progress_bar/audio_video_progress_bar.dart';
import 'package:pili_aurora/pages/video/controller.dart';
import 'package:pili_aurora/plugin/pl_player/controller.dart';
import 'package:pili_aurora/plugin/pl_player/widgets/bottom_control.dart';
import 'package:pili_aurora/utils/storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  late PlPlayerController playerController;
  late VideoDetailController videoDetailController;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'pili-bottom-control-',
    );
    Hive.init(directory.path);
    GStorage.setting = await Hive.openBox('setting');
    GStorage.video = await Hive.openBox('video');
    GStorage.localCache = await Hive.openBox('cache');
    playerController = PlPlayerController.getInstance()
      ..showControls.value = true;
    videoDetailController = VideoDetailController();
  });

  tearDown(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  testWidgets('非全屏底部控件贴合播放器两侧', (tester) async {
    const width = 400.0;
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(width, 300);
    addTearDown(tester.view.reset);

    const leftKey = ValueKey('bottom-control-left');
    const rightKey = ValueKey('bottom-control-right');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: width,
            child: BottomControl(
              maxWidth: width,
              isFullScreen: false,
              controller: playerController,
              videoDetailController: videoDetailController,
              buildBottomControl: () => const PlayerBar(
                children: [
                  Row(key: leftKey),
                  Row(key: rightKey),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final progressRect = tester.getRect(find.byType(ProgressBar));
    final leftRect = tester.getRect(find.byKey(leftKey));
    final rightRect = tester.getRect(find.byKey(rightKey));

    expect(progressRect.left, 0);
    expect(progressRect.right, width);
    expect(leftRect.left, 0);
    expect(rightRect.right, width);
  });
}
