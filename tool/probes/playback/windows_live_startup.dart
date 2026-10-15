import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:pili_aurora/http/browser_ua.dart';
import 'package:pili_aurora/plugin/pl_player/playback/shader_updates.dart';

/// 用真实 mpv/ANGLE 检查首次播放及刷新后的纹理像素，音频输出为 null。
/// 媒体地址从本地清单读取，避免把直播签名放进构建参数和测试输出。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!Platform.isWindows) throw UnsupportedError('Windows probe');
  const input = String.fromEnvironment('LIVE_STARTUP_INPUT');
  const output = String.fromEnvironment('LIVE_STARTUP_OUTPUT');
  final sources = jsonDecode(await File(input).readAsString()) as List;
  final report = File(output);
  await report.parent.create(recursive: true);
  MediaKit.ensureInitialized();
  final results = <Map<String, Object?>>[];
  var failed = false;
  runApp(const MaterialApp(home: ColoredBox(color: Colors.black)));

  for (var index = 0; index < sources.length; index++) {
    final source = sources[index] as Map<String, dynamic>;
    final player = await Player.create(
      configuration: const PlayerConfiguration(
        logLevel: .error,
        options: {
          'ao': 'null',
          'gpu-dumb-mode': 'no',
          'video-sync': 'audio',
        },
      ),
    );
    var renderErrors = 0;
    final subscription = player.stream.log.listen((log) {
      if ((log.level == 'error' || log.level == 'fatal') &&
          log.prefix.contains('libmpv')) {
        renderErrors++;
      }
    });
    final video = await VideoController.create(
      player,
      configuration: VideoControllerConfiguration(
        hwdec: 'd3d11va',
        width: source['width'] as int?,
        height: source['height'] as int?,
      ),
    );
    player.setMediaHeader(
      userAgent: BrowserUa.pc,
      referer: 'https://www.bilibili.com/',
    );
    final boundary = GlobalKey();

    try {
      for (final phase in ['initial', 'refresh']) {
        renderErrors = 0;
        if (phase == 'refresh' && player.state.width > 0) {
          // 对齐应用刷新入口：重载前清理 shader，并重建已就绪的 Windows 输出。
          await applyShaderList(
            '',
            command: player.command,
            resetRenderer: video.resetRenderer,
          );
        }
        await player
            .open(
              Media(
                source['source'] as String,
                extras: const {
                  'cache': 'yes',
                  'demuxer-max-bytes': '8388608',
                  'demuxer-max-back-bytes': '0',
                },
              ),
              play: false,
            )
            .timeout(const Duration(seconds: 20));
        await player.play();
        if (phase == 'initial') {
          // 直播页面在加载完成后才挂载视频控件。
          runApp(
            MaterialApp(
              home: Center(
                child: RepaintBoundary(
                  key: boundary,
                  child: SizedBox(
                    width: 640,
                    height: 360,
                    child: FittedBox(child: SimpleVideo(controller: video)),
                  ),
                ),
              ),
            ),
          );
        }
        await Future<void>.delayed(const Duration(seconds: 4));
        final beforeAudio = double.tryParse(player.getProperty('audio-pts'));
        await Future<void>.delayed(const Duration(milliseconds: 300));
        final afterAudio = double.tryParse(player.getProperty('audio-pts'));
        await WidgetsBinding.instance.endOfFrame;
        final render =
            boundary.currentContext!.findRenderObject()
                as RenderRepaintBoundary;
        final image = await render.toImage(pixelRatio: 1);
        final pixels = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        var low = 255, high = 0, bright = 0, count = 0;
        for (var y = 20; y < image.height - 20; y += 4) {
          for (var x = 20; x < image.width - 20; x += 4) {
            final offset = (y * image.width + x) * 4;
            final value =
                (pixels.getUint8(offset) +
                    pixels.getUint8(offset + 1) +
                    pixels.getUint8(offset + 2)) ~/
                3;
            if (value < low) low = value;
            if (value > high) high = value;
            if (value > 10) bright++;
            count++;
          }
        }
        image.dispose();
        final audioAdvancing =
            beforeAudio != null &&
            afterAudio != null &&
            afterAudio > beforeAudio;
        final decoder = player.getProperty('hwdec-current');
        final passed =
            high - low > 16 &&
            bright > count * 0.01 &&
            renderErrors == 0 &&
            decoder == 'd3d11va' &&
            (source['expectAudio'] != true || audioAdvancing);
        failed |= !passed;
        results.add({
          'sourceIndex': index,
          'phase': phase,
          'fixedOutput': source['width'] != null,
          'passed': passed,
          'pixelRange': high - low,
          'brightFraction': count == 0 ? 0 : bright / count,
          'renderErrors': renderErrors,
          'decoder': decoder,
          'audioAdvancing': audioAdvancing,
        });
        await report.writeAsString(
          const JsonEncoder.withIndent('  ').convert(results),
        );
      }
    } catch (error) {
      failed = true;
      // 网络异常可能携带签名地址，报告仅保留类型。
      results.add({
        'sourceIndex': index,
        'errorType': error.runtimeType.toString(),
      });
    } finally {
      runApp(const MaterialApp(home: ColoredBox(color: Colors.black)));
      await WidgetsBinding.instance.endOfFrame;
      await subscription.cancel();
      await player.dispose();
    }
    await report.writeAsString(
      const JsonEncoder.withIndent('  ').convert(results),
    );
  }
  exit(failed || results.isEmpty ? 1 : 0);
}
