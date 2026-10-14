import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/common/assets.dart';
import 'package:pili_aurora/common/widgets/image/network_img_layer.dart';
import 'package:pili_aurora/common/widgets/loading_widget/http_error.dart';
import 'package:pili_aurora/models/common/image_type.dart';
import 'package:pili_aurora/utils/storage.dart';

String imageAsset(Image image) => switch (image.image) {
  AssetImage(:final assetName) => assetName,
  ResizeImage(imageProvider: AssetImage(:final assetName)) => assetName,
  _ => '',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    GStorage.setting = await Hive.openBox<dynamic>(
      'themed_assets_test',
      bytes: Uint8List(0),
    );
  });
  tearDownAll(Hive.close);

  test('明暗资源均能从应用 bundle 加载并解码', () async {
    for (final brightness in Brightness.values) {
      for (final asset in [
        Assets.logo,
        Assets.loading,
        Assets.ai,
        Assets.avatarPlaceHolder,
        Assets.topicHeader,
      ]) {
        final path = Assets.themed(asset, brightness);
        final data = await rootBundle.load(path);
        final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
        final frame = await codec.getNextFrame();
        expect(frame.image.width, greaterThan(0), reason: path);
        frame.image.dispose();
        codec.dispose();
      }
      for (final asset in [Assets.error, Assets.vipIcon]) {
        final path = Assets.themed(asset, brightness);
        final picture = await vg.loadPicture(
          SvgStringLoader(await rootBundle.loadString(path)),
          null,
        );
        expect(picture.size.isEmpty, isFalse, reason: path);
        picture.picture.dispose();
      }
    }
  });

  test('单色标记与封面播放等通用资源在两种主题下复用', () {
    for (final path in [
      Assets.logo2,
      Assets.playIcon,
      Assets.buffering,
      Assets.livingBackground,
      Assets.coinTossOne,
    ]) {
      expect(Assets.themed(path, Brightness.light), path);
      expect(Assets.themed(path, Brightness.dark), path);
    }
    expect(File(Assets.logoIco).existsSync(), isTrue);
    expect(
      File(Assets.themed(Assets.logoIco, Brightness.dark)).existsSync(),
      isTrue,
    );
  });

  testWidgets('切换主题后占位和头像实时更新，空状态重试仍可用', (tester) async {
    final brightness = ValueNotifier(Brightness.light);
    addTearDown(brightness.dispose);
    var retries = 0;
    await tester.pumpWidget(
      ValueListenableBuilder(
        valueListenable: brightness,
        builder: (context, value, child) => MaterialApp(
          theme: ThemeData(brightness: value),
          home: Scaffold(
            body: Column(
              children: [
                const NetworkImgLayer(src: null, width: 180, height: 100),
                const NetworkImgLayer(
                  src: null,
                  width: 48,
                  height: 48,
                  type: ImageType.avatar,
                ),
                HttpError(
                  isSliver: false,
                  safeArea: false,
                  onReload: () => retries++,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    List<String> paths() =>
        tester.widgetList<Image>(find.byType(Image)).map(imageAsset).toList();
    expect(paths(), containsAll([Assets.loading, Assets.avatarPlaceHolder]));
    for (final value in [Brightness.dark, Brightness.light]) {
      brightness.value = value;
      await tester.pumpAndSettle();
      expect(
        paths(),
        containsAll([
          Assets.themed(Assets.loading, value),
          Assets.themed(Assets.avatarPlaceHolder, value),
        ]),
      );
      await tester.tap(find.text('点击重试'));
      expect(tester.takeException(), isNull);
    }
    expect(retries, 2);
  });
}
