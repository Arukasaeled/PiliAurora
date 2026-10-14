// 播放图标源稿为 SVG；阴影预渲染到透明 PNG。
// 重新生成：fvm flutter test --no-pub tool/generate_play_icon.dart
import 'dart:io';
import 'dart:ui';

import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('generate play icon resolution variants', () async {
    final info = await vg.loadPicture(
      SvgStringLoader(await File('tool/artwork/play.svg').readAsString()),
      null,
    );
    for (final scale in [1, 2, 3, 4]) {
      final recorder = PictureRecorder();
      // 图形维持 60px 逻辑尺寸，四周 12px 用于承载阴影。
      Canvas(recorder)
        ..scale(scale.toDouble())
        ..translate(12, 12)
        ..drawRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(5, 10, 50, 44),
            const Radius.circular(14),
          ),
          Paint()
            ..color = const Color(0x26000000)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.5),
        )
        ..drawPicture(info.picture);
      final picture = recorder.endRecording();
      final image = await picture.toImage(84 * scale, 84 * scale);
      final data = (await image.toByteData(format: ImageByteFormat.png))!;
      final path = scale == 1
          ? 'assets/images/play.png'
          : 'assets/images/$scale.0x/play.png';
      final file = File(path);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(data.buffer.asUint8List());
      image.dispose();
      picture.dispose();
    }
    info.picture.dispose();
  });
}
