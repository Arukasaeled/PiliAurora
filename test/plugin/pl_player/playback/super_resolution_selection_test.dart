import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:pili_aurora/models/common/super_resolution_type.dart';
import 'package:pili_aurora/plugin/pl_player/controller.dart';
import 'package:pili_aurora/utils/storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  late PlPlayerController controller;

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('pili-shader-selection-');
    Hive.init(directory.path);
    GStorage.setting = await Hive.openBox('setting');
    GStorage.video = await Hive.openBox('video');
    GStorage.localCache = await Hive.openBox('cache');
    controller = PlPlayerController.getInstance();
  });

  tearDownAll(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  setUp(() {
    controller.superResolutionType.value = SuperResolutionType.disable;
  });

  test('尺寸未确认时拒绝开启，保留当前档位和设置', () async {
    for (final current in [
      SuperResolutionType.disable,
      SuperResolutionType.efficiency,
    ]) {
      controller.superResolutionType.value = current;
      final settings = GStorage.setting.toMap();
      await controller.setShader(SuperResolutionType.quality);
      expect(controller.superResolutionType.value, current);
      expect(GStorage.setting.toMap(), settings);
    }
  });

  test('重复选择当前关闭档位不执行 shader 更新', () async {
    await controller.setShader(SuperResolutionType.disable);
    expect(controller.superResolutionType.value, SuperResolutionType.disable);
  });
}
