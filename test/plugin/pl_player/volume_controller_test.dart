import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:pili_aurora/plugin/pl_player/controller.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';

void main() {
  testWidgets('播放器迁移旧音量并将新的调节结果限制为整数百分比', (tester) async {
    GStorage.setting = await Hive.openBox('setting', bytes: Uint8List(0));
    GStorage.video = await Hive.openBox('video', bytes: Uint8List(0));
    GStorage.localCache = await Hive.openBox('cache', bytes: Uint8List(0));
    await GStorage.setting.put(SettingBoxKey.desktopVolume, .9912);
    final controller = PlPlayerController.getInstance();
    addTearDown(() async {
      controller.volumeTimer?.cancel();
      await Hive.close();
    });
    expect(controller.volume.value, .99);
    expect(controller.maxVolume, 1);
    await controller.setVolume(.854, showIndicator: false);
    expect(controller.volume.value, .85);
    await controller.setVolume(1.5, showIndicator: false);
    expect(controller.volume.value, 1);
    await controller.setVolume(-.1, showIndicator: false);
    expect(controller.volume.value, 0);
    await controller.setVolume(.9912, showIndicator: false);
    await tester.pump(const Duration(milliseconds: 200));
    expect(GStorage.setting.get(SettingBoxKey.desktopVolume), .99);
  });
}
