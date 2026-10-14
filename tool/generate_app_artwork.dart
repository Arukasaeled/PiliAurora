// 从可编辑 SVG 生成应用位图；使用项目固定的 Flutter 渲染器。
// 重新生成：fvm flutter test --no-pub tool/generate_app_artwork.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

// 暗色源稿复用相同几何，调整表面亮度与线条对比度。
const _darkPalettes = {
  'tool/artwork/shortcut-search.svg': {'#606C7B': '#B7C7DD'},
  'tool/artwork/shortcut-download.svg': {'#606C7B': '#B7C7DD'},
  'tool/artwork/loading.svg': {
    '#E5EDF4': '#506584',
    '#A9BED5': '#2D3B52',
    '#C8D2DF': '#394C66',
    '#879CB9': '#8198B9',
    '#8499B7': '#A6B7CC',
    '#6F86AF': '#C2D3E8',
    '#445D86': '#92B1DB',
    '#8191A6': '#000000',
    '#C8A575': '#D4B890',
  },
  'tool/artwork/avatar.svg': {
    '#E5E2DE': '#293341',
    '#AAA6A0': '#87929F',
    '#D7D3CE': '#25303B',
  },
  'tool/artwork/ai.svg': {
    '#CBD5E0': '#405368',
    '#52677E': '#C9D8E8',
    '#B29978': '#C6AD86',
    '#F3EFE8': '#485B72',
  },
  'tool/artwork/error.svg': {
    '#CDD4DC': '#344253',
    '#8C96A3': '#8397AF',
    '#ECEAE6': '#4D5563',
    '#ACA9A3': '#8A939D',
    '#C4C0BA': '#A1ADB8',
    '#DCE1E7': '#46566A',
    '#9AA4B0': '#A9BACD',
    '#E9DDCB': '#635E58',
    '#B5A58E': '#B8AC98',
    '#A08E73': '#E5D2B2',
    '#A7ACB4': '#8E9EB3',
    '#B9C3CE': '#9DADBE',
    '#8E9298': '#000000',
  },
  'tool/artwork/vip.svg': {'#B38388': '#986E7A', '#FFFFFF': '#CCD4DC'},
  'tool/artwork/topic-header.svg': {
    '#9C9184': '#B9B0A2',
    '#9B948B': '#9FA9BB',
    '#8B929B': '#B8CADF',
  },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('generate app artwork', () async {
    await File('tool/artwork/error.svg').copy('assets/images/error.svg');
    await File('tool/artwork/vip.svg').copy('assets/images/big-vip.svg');
    for (final (source, destination) in [
      ('tool/artwork/error.svg', 'assets/images/error_dark.svg'),
      ('tool/artwork/vip.svg', 'assets/images/big-vip_dark.svg'),
    ]) {
      await File(destination)
          .writeAsString(await loadSvg(source, _darkPalettes[source]!));
    }
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
      if (_darkPalettes[source] case final palette?) {
        await renderSvg(
          source,
          destination.startsWith('android/')
              ? destination.replaceFirst('/drawable/', '/drawable-night/')
              : destination.replaceFirst('.png', '_dark.png'),
          width: width,
          height: height,
          palette: palette,
        );
      }
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
  Map<String, String> palette = const {},
}) async {
  final svg = await loadSvg(source, palette);
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

Future<String> loadSvg(String source, Map<String, String> palette) async {
  var svg = await File(source).readAsString();
  for (final entry in palette.entries) {
    svg = svg.replaceAll(entry.key, entry.value);
  }
  return svg;
}
