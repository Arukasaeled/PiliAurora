// 从可编辑 SVG 生成应用位图；使用项目固定的 Flutter 渲染器。
// 重新生成：fvm flutter test --no-pub tool/generate_app_artwork.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('generate app artwork', () async {
    await File('tool/artwork/error.svg').copy('assets/images/error.svg');
    await File('tool/artwork/vip.svg').copy('assets/images/big-vip.svg');
    for (final (source, destination, width, height) in [
      ('tool/artwork/loading.svg', 'assets/images/loading.png', 200, 200),
      ('tool/artwork/avatar.svg', 'build/asset-refresh/avatar.png', 180, 180),
      ('tool/artwork/ai.svg', 'assets/images/ai.png', 75, 75),
      ('tool/artwork/logo-mark.svg', 'assets/images/logo/logo_2.png', 512, 512),
      (
        'tool/artwork/shortcut-search.svg',
        'android/app/src/main/res/drawable/ic_shortcut_search.png',
        200,
        200,
      ),
      (
        'tool/artwork/shortcut-download.svg',
        'android/app/src/main/res/drawable/ic_shortcut_download.png',
        202,
        200,
      ),
      (
        'tool/artwork/topic-header.svg',
        'assets/images/topic-header-bg.png',
        1125,
        720,
      ),
    ]) {
      await renderSvg(source, destination, width: width, height: height);
    }
    for (final source in Directory('tool/artwork/paycoins').listSync()) {
      if (source is File && source.path.endsWith('.svg')) {
        final name = source.uri.pathSegments.last.replaceAll('.svg', '.png');
        await renderSvg(source.path, 'assets/images/paycoins/$name');
      }
    }
    final monochrome = await File(
      'tool/artwork/logo-mark.svg',
    ).readAsString();
    final path = RegExp(r'<path d="([^"]+)"').firstMatch(monochrome)!.group(1)!;
    // Android 单色主题图标与应用内标记复用相同轮廓。
    await File(
      'android/app/src/main/res/drawable/ic_launcher_monochrome.xml',
    ).writeAsString('''<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:height="108dp"
    android:width="108dp"
    android:viewportWidth="512"
    android:viewportHeight="512">
    <path
        android:fillColor="@color/ic_launcher_foreground"
        android:pathData="$path"
        android:fillType="evenOdd" />
</vector>
''');
  });
}

Future<void> renderSvg(
  String source,
  String destination, {
  int? width,
  int? height,
}) async {
  final svg = await File(source).readAsString();
  final info = await vg.loadPicture(SvgStringLoader(svg), null);
  final outputWidth = width ?? info.size.width.round();
  final outputHeight = height ?? info.size.height.round();
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder)
    ..scale(outputWidth / info.size.width, outputHeight / info.size.height)
    ..drawPicture(info.picture);
  final picture = recorder.endRecording();
  final image = await picture.toImage(outputWidth, outputHeight);
  final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
  final file = File(destination);
  await file.parent.create(recursive: true);
  await file.writeAsBytes(data.buffer.asUint8List());
  image.dispose();
  picture.dispose();
  info.picture.dispose();
}
