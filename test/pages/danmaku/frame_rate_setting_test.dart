import 'dart:typed_data';

import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive.dart';
import 'package:pili_aurora/pages/danmaku/view.dart';
import 'package:pili_aurora/pages/danmaku/danmaku_model.dart';
import 'package:pili_aurora/pages/danmaku/windows_screen.dart';
import 'package:pili_aurora/pages/live_room/controller.dart';
import 'package:pili_aurora/pages/live_room/view.dart' as live;
import 'package:pili_aurora/plugin/pl_player/controller.dart';
import 'package:pili_aurora/plugin/pl_player/models/play_status.dart';
import 'package:pili_aurora/utils/platform_utils.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';

void main() {
  setUpAll(() async {
    GStorage.setting = await Hive.openBox<dynamic>(
      'frame_rate_settings',
      bytes: Uint8List(0),
    );
  });
  tearDownAll(() => GStorage.setting.close());

  for (final isLive in [false, true]) {
    testWidgets('保存帧率后当前${isLive ? '直播' : '视频'}弹幕立即更新且保留控制器', (tester) async {
      final player = _Player();
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: MediaQuery(
            data: const MediaQueryData(),
            child: isLive
                ? live.LiveDanmaku(
                    liveRoomController: _LiveRoom(),
                    plPlayerController: player,
                    isFullScreen: false,
                    size: const Size(800, 600),
                  )
                : PlDanmaku(
                    cid: 1,
                    playerController: player,
                    isFullScreen: false,
                    isFileSource: false,
                    size: const Size(800, 600),
                  ),
          ),
        ),
      );
      int rate() => PlatformUtils.isDesktop && !isLive
          ? tester
                .widget<WindowsDanmakuScreen>(
                  find.byWidgetPredicate((w) => w is WindowsDanmakuScreen),
                )
                .frameRate
          : tester
                .widget<DanmakuScreen>(
                  find.byWidgetPredicate((w) => w is DanmakuScreen),
                )
                .frameRate;
      final controller = player.danmakuController;
      expect(rate(), 0);
      for (final fps in [30, 60, 90, 120, 0]) {
        await GStorage.setting.put(SettingBoxKey.danmakuFrameRate, fps);
        await tester.pump();
        expect(rate(), fps);
        expect(player.danmakuController, same(controller));
      }
      if (isLive) {
        controller!.addDanmaku(DanmakuContentItem<DanmakuExtra>('hidden'));
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        expect(tester.binding.hasScheduledFrame, isFalse);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    });
  }
}

class _Player implements PlPlayerController {
  @override
  final enableShowDanmaku = false.obs;
  @override
  final enableShowLiveDanmaku = false.obs;
  @override
  final danmakuOpacity = 1.0.obs;
  @override
  bool get mergeDanmaku => false;
  @override
  double get playbackSpeed => 1;
  @override
  PlayerStatus get playerStatus => PlayerStatus.paused;
  @override
  DanmakuController<DanmakuExtra>? danmakuController;
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _LiveRoom implements LiveRoomController {
  @override
  DanmakuController<DanmakuExtra>? danmakuController;
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
