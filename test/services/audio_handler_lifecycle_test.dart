import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:pili_aurora/models/remote/video/video_detail/page.dart'
    show Part;
import 'package:pili_aurora/plugin/pl_player/controller.dart';
import 'package:pili_aurora/plugin/pl_player/playback/playback_session.dart';
import 'package:pili_aurora/services/audio_handler.dart';
import 'package:pili_aurora/services/service_locator.dart';
import 'package:pili_aurora/utils/storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('pili-audio-handler-');
    Hive.init(directory.path);
    GStorage.setting = await Hive.openBox('setting');
    GStorage.video = await Hive.openBox('video');
    GStorage.localCache = await Hive.openBox('cache');
  });

  tearDownAll(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test(
    'last media item releases its lease after older page disposal',
    () async {
      final controller = PlPlayerController.getInstance();
      final firstOwner = controller.attachPlaybackOwner();
      final handler = VideoPlayerServiceHandler()..enableBackgroundPlay = true;
      videoPlayerServiceHandler = handler;
      PlaybackOwner? secondOwner;
      addTearDown(() async {
        handler.clear();
        controller.closePlaybackOwner(firstOwner);
        if (secondOwner case final owner?) {
          controller.closePlaybackOwner(owner);
        }
        try {
          await controller.playbackReleased.timeout(const Duration(seconds: 2));
        } on TimeoutException {
          // 保持 teardown 有界；主断言会报告 lease 是否阻止了释放。
        }
        videoPlayerServiceHandler = null;
      });

      handler.onVideoDetailChange(Part(part: 'first'), 1, 'first');
      secondOwner = controller.attachPlaybackOwner();
      handler.onVideoDetailChange(Part(part: 'second'), 2, 'second');
      var released = false;
      unawaited(controller.playbackReleased.then((_) => released = true));

      handler.onVideoDetailDispose('first');
      expect(handler.mediaItem.value?.id, '2second');
      controller.closePlaybackOwner(firstOwner);
      await Future<void>.delayed(Duration.zero);
      expect(released, isFalse);

      handler.onVideoDetailDispose('second');
      expect(handler.mediaItem.value, isNull);
      controller.closePlaybackOwner(secondOwner);
      await controller.playbackReleased.timeout(const Duration(seconds: 2));

      expect(released, isTrue);
    },
  );
}
