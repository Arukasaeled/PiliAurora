import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:pili_aurora/app/bootstrap.dart';
import 'package:pili_aurora/common/widgets/scale_app.dart';
import 'package:pili_aurora/http/api.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/models/common/video/source_type.dart';
import 'package:pili_aurora/models/common/video/video_type.dart';
import 'package:pili_aurora/models/remote/download/bili_download_entry_info.dart';
import 'package:pili_aurora/pages/video/controller.dart';
import 'package:pili_aurora/pages/live_room/controller.dart';
import 'package:pili_aurora/pages/live_room/view.dart';
import 'package:pili_aurora/plugin/pl_player/controller.dart';
import 'package:pili_aurora/plugin/pl_player/widgets/desktop_playback_menu.dart';
import 'package:pili_aurora/plugin/pl_player/widgets/video_output_handoff.dart';
import 'package:pili_aurora/services/desktop_playback_request.dart';
import 'package:pili_aurora/services/desktop_playback_windows.dart';
import 'package:pili_aurora/utils/path_utils.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';
import 'package:window_manager/window_manager.dart';

/// 使用独立空账号存储、本地样片和生产 IPC/路由验收视频小窗。
Future<void> main(List<String> arguments) async {
  const output = String.fromEnvironment('WINDOW_PROBE_REPORT');
  const media = String.fromEnvironment('WINDOW_PROBE_MEDIA');
  if (output.isEmpty || media.isEmpty) throw ArgumentError('需要样片和报告路径');
  final reportFile = File(output);
  await reportFile.parent.create(recursive: true);
  final config = File('$output.config.json');
  final options = config.existsSync()
      ? jsonDecode(await config.readAsString()) as Map
      : const {};
  final liveBase = options['liveBase'] as String?;
  final onlineBase = options['onlineBase'] as String?;
  if (arguments.firstOrNull == DesktopPlaybackWindows.argument) {
    await bootstrapApplication(arguments);
    if (liveBase != null || onlineBase != null) {
      Request.dio.httpClientAdapter = _PlaybackFixture(liveBase ?? onlineBase!);
    }
    final report = <String, Object?>{};
    try {
      final startup = _observeStartup();
      await Future<void>.delayed(const Duration(seconds: 12));
      report['startup'] = await startup;
      final player = PlPlayerController.instance;
      if (player != null) {
        final snapshot = player.currentPlaybackSnapshot;
        report.addAll({
          'phase': snapshot.phase.name,
          'playing': snapshot.actual.playing,
          'intent': snapshot.intent.playing,
          'positionMs': snapshot.actual.position?.inMilliseconds,
          'textureId': player.videoController?.id.value,
          'output': snapshot.presentation.outputStrategy.name,
        });
        if (player.videoPlayerController case NativePlayer native) {
          report['native'] = {
            for (final key in const [
              'pause',
              'idle-active',
              'playlist-count',
              'video-codec',
              'current-vo',
              'hwdec-current',
              'video-out-params',
            ])
              key: native.getProperty(key),
          };
        }
      }
      if (Get.isRegistered<VideoDetailController>(tag: 'window-probe')) {
        final page = Get.find<VideoDetailController>(tag: 'window-probe');
        report['pageLoaded'] = page.videoState.value;
        report['pageAutoPlay'] = page.autoPlay;
      }
      final before = await _texturePixels();
      await Future<void>.delayed(const Duration(seconds: 2));
      final after = await _texturePixels();
      report.addAll({
        'beforePixels': before,
        'afterPixels': after,
        'passed':
            (report['startup'] as Map)['passed'] == true &&
            before['range'] != null &&
            (before['range']! as int) > 40 &&
            (after['range']! as int) > 40 &&
            before['fingerprint'] != after['fingerprint'],
      });
      if (liveBase != null) {
        LiveRoomController? live;
        void findLive(Element element) {
          if (element.widget is LiveRoomPage && element is StatefulElement) {
            final dynamic state = element.state;
            live = Get.find<LiveRoomController>(tag: state.heroTag as String);
          }
          element.visitChildren(findLive);
        }

        WidgetsBinding.instance.rootElement!.visitChildren(findLive);
        if (live == null) throw StateError('Live page is missing');
        final switches = <Map<String, Object?>>[];
        for (var index = 0; index < 6; index++) {
          final watch = Stopwatch()..start();
          await live!.initLiveUrl(
            streamIndex: options['lineSwitchOnly'] == true ? 0 : index % 2,
            liveUrlIndex: options['lineSwitchOnly'] == true ? index % 2 : 0,
          );
          await Future<void>.delayed(const Duration(milliseconds: 700));
          final first = await _texturePixels();
          await Future<void>.delayed(const Duration(seconds: 2));
          final last = await _texturePixels();
          final passed =
              (first['range'] as int? ?? 0) > 40 &&
              (last['range'] as int? ?? 0) > 40 &&
              first['fingerprint'] != last['fingerprint'];
          switches.add({
            'index': index,
            'passed': passed,
            'ms': watch.elapsedMilliseconds,
            'first': first,
            'last': last,
            'phase': player?.currentPlaybackSnapshot.phase.name,
            'playing': player?.currentPlaybackSnapshot.actual.playing,
          });
        }
        report['switches'] = switches;
        report['passed'] =
            report['passed'] == true &&
            switches.every((s) => s['passed'] == true);
      }
      if (liveBase == null && report['passed'] == true && player != null) {
        final page = Get.find<VideoDetailController>(tag: 'window-probe');
        await player.pause();
        await page.playerInit();
        final paused = player.currentPlaybackSnapshot;
        report['reloadKeptPause'] =
            !paused.intent.playing && paused.actual.playing == false;
        report['passed'] = report['reloadKeptPause'] == true;
      }
    } catch (error, stack) {
      report.addAll({
        'passed': false,
        'errorType': error.runtimeType.toString(),
        'stack': stack.toString().split('\n').take(6).toList(),
      });
    }
    await File('$output.child.json').writeAsString(
      const JsonEncoder.withIndent('  ').convert(report),
    );
    await windowManager.close();
    return;
  }

  ScaledWidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  final root = Directory('${reportFile.parent.path}/window-host');
  await root.create(recursive: true);
  appSupportDirPath = root.path;
  await GStorage.init();
  await GStorage.setting.putAll({
    SettingBoxKey.dynamicColor: false,
    SettingBoxKey.autoPlayEnable: true,
    SettingBoxKey.preInitPlayer: false,
  });
  await GStorage.localCache.putAll({
    LocalCacheKey.mixinKey: 'synthetic-local-window-probe-key',
    LocalCacheKey.timeStamp: DateTime.now().millisecondsSinceEpoch,
  });
  final fixture = Directory('${root.path}/fixture/video');
  await fixture.create(recursive: true);
  await File(media).copy('${fixture.path}/${PathUtils.videoNameType1}');
  final entry = BiliDownloadEntryInfo(
    isCompleted: true,
    totalBytes: 1,
    downloadedBytes: 1,
    title: 'Local window fixture',
    typeTag: 'video',
    cover: '',
    preferedVideoQuality: 80,
    guessedTotalBytes: 1,
    totalTimeMilli: 120000,
    danmakuCount: 0,
    avid: 1,
    bvid: 'BV-window-fixture',
    pageData: PageInfo(cid: 1, page: 1, hasAlias: false, tid: 0),
  );
  runApp(const MaterialApp(home: ColoredBox(color: Colors.black)));
  final report = <String, Object?>{};
  try {
    await DesktopPlaybackWindows.instance.open(
      liveBase != null
          ? const DesktopPlaybackRequest.live(1)
          : DesktopPlaybackRequest.video({
              'aid': 1,
              'bvid': entry.bvid,
              'cid': 1,
              'videoType': VideoType.ugc,
              'sourceType': onlineBase == null
                  ? SourceType.file
                  : SourceType.normal,
              'entry': entry,
              'dirPath': fixture.parent.path,
              'heroTag': 'window-probe',
              'title': entry.title,
            }),
    );
    report['readyAcknowledged'] = true;
    final deadline = DateTime.now().add(const Duration(seconds: 90));
    final child = File('$output.child.json');
    while (!child.existsSync() && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    report['child'] = jsonDecode(await child.readAsString());
  } catch (error) {
    report['errorType'] = error.runtimeType.toString();
    final child = File('$output.child.json');
    if (child.existsSync()) {
      report['child'] = jsonDecode(await child.readAsString());
    }
  }
  report['passed'] =
      report['readyAcknowledged'] == true &&
      (report['child'] as Map?)?['passed'] == true;
  await reportFile.writeAsString(
    const JsonEncoder.withIndent('  ').convert(report),
  );
  if (options['captureMenus'] == true) {
    final boundary = GlobalKey();
    for (final brightness in Brightness.values) {
      runApp(
        RepaintBoundary(
          key: boundary,
          child: MaterialApp(
            key: ValueKey(brightness),
            theme: ThemeData(brightness: brightness),
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            locale: const Locale('zh', 'CN'),
            supportedLocales: const [Locale('zh', 'CN')],
            home: Scaffold(
              backgroundColor: const Color(0xFF405A48),
              body: Center(
                child: DesktopPlaybackMenu(
                  controller: PlPlayerController.getInstance(),
                ),
              ),
            ),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 400));
      void openMenu(Element element) {
        if (element.widget is PopupMenuButton<String> &&
            element is StatefulElement) {
          (element.state as PopupMenuButtonState<String>).showButtonMenu();
        } else {
          element.visitChildren(openMenu);
        }
      }

      WidgetsBinding.instance.rootElement!.visitChildren(openMenu);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      int? foreground;
      void inspectText(Element element) {
        if (element.widget case Text(data: '弹出为独立小窗')) {
          foreground = DefaultTextStyle.of(element).style.color?.toARGB32();
        }
        element.visitChildren(inspectText);
      }

      WidgetsBinding.instance.rootElement!.visitChildren(inspectText);
      report['menuText-${brightness.name}'] = foreground;
      report['passed'] = report['passed'] == true && foreground != null;
      final render =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await render.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('$output.menu-${brightness.name}.png')
          .writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    }
    await reportFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(report),
    );
  }
  await GStorage.close();
  await windowManager.destroy();
}

Future<Map<String, Object?>> _observeStartup() async {
  final watch = Stopwatch()..start();
  final geometry = <String>[];
  var visibleWithoutTexture = 0, handoffSamples = 0;
  int? firstTextureMs;
  while (watch.elapsed < const Duration(seconds: 6)) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    var count = 0;
    void visit(RenderObject object) {
      if (object is TextureBox) count++;
      object.visitChildren(visit);
    }

    for (final view in RendererBinding.instance.renderViews) {
      visit(view);
    }
    if (count == 0 && await windowManager.isVisible()) visibleWithoutTexture++;
    final player = PlPlayerController.instance;
    if (count > 0 && player?.currentPlaybackSnapshot.actual.playing == true) {
      firstTextureMs ??= watch.elapsedMilliseconds;
      final rect = player!.videoController?.rect.value;
      final size = '${rect?.width}x${rect?.height}';
      if (geometry.isEmpty || geometry.last != size) geometry.add(size);
      void inspect(Element element) {
        final widget = element.widget;
        if (widget is VideoOutputHandoffView && widget.handoff.image != null) {
          handoffSamples++;
        }
        element.visitChildren(inspect);
      }

      WidgetsBinding.instance.rootElement?.visitChildren(inspect);
    }
  }
  return {
    'firstTextureMs': firstTextureMs,
    'visibleWithoutTextureSamples': visibleWithoutTexture,
    'geometryWhilePlaying': geometry,
    'handoffSamples': handoffSamples,
    'passed':
        firstTextureMs != null &&
        visibleWithoutTexture == 0 &&
        geometry.length == 1 &&
        handoffSamples == 0,
  };
}

Future<Map<String, Object?>> _texturePixels() async {
  await WidgetsBinding.instance.endOfFrame;
  final textures = <RenderRepaintBoundary>[];
  var textureCount = 0;
  void visit(RenderObject object, RenderRepaintBoundary? boundary) {
    if (object is RenderRepaintBoundary) boundary = object;
    if (object is TextureBox) {
      textureCount++;
      if (boundary != null) textures.add(boundary);
    }
    object.visitChildren((child) => visit(child, boundary));
  }

  for (final view in RendererBinding.instance.renderViews) {
    visit(view, null);
  }
  if (textures.isEmpty) return {'textureCount': textureCount};
  final image = await textures.first.toImage(pixelRatio: 0.5);
  final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  var low = 255, high = 0, fingerprint = 0;
  for (var y = image.height ~/ 5; y < image.height * 4 ~/ 5; y += 4) {
    for (var x = image.width ~/ 5; x < image.width * 4 ~/ 5; x += 4) {
      final offset = (y * image.width + x) * 4;
      final value =
          (bytes.getUint8(offset) +
              bytes.getUint8(offset + 1) +
              bytes.getUint8(offset + 2)) ~/
          3;
      if (value < low) low = value;
      if (value > high) high = value;
      fingerprint = (fingerprint * 31 + value) & 0x7fffffff;
    }
  }
  image.dispose();
  return {
    'textureCount': textureCount,
    'range': high - low,
    'fingerprint': fingerprint,
  };
}

class _PlaybackFixture implements HttpClientAdapter {
  _PlaybackFixture(this.base);
  final String base;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final Object data;
    if (options.path == Api.ugcUrl) {
      data = {
        'quality': 80,
        'timelength': 120000,
        'accept_quality': [80],
        'format': 'mp4',
        'durl': [
          {
            'order': 1,
            'length': 120000,
            'size': 1,
            'url': '$base/window-host/fixture/video/0.mp4',
          },
        ],
      };
    } else if (options.path == Api.liveRoomInfo) {
      Map<String, Object?> stream(
        String protocol,
        String format,
        String file,
      ) => {
        'protocol_name': protocol,
        'format': [
          {
            'format_name': format,
            'codec': [
              {
                'codec_name': 'avc',
                'current_qn': 80,
                'accept_qn': [80],
                'base_url': file,
                'url_info': [
                  {'host': base, 'extra': '?line=0'},
                  {'host': base, 'extra': '?line=1'},
                ],
              },
            ],
          },
        ],
      };
      data = {
        'room_id': 1,
        'uid': 1,
        'is_portrait': false,
        'live_status': 1,
        'live_time': 0,
        'playurl_info': {
          'playurl': {
            'stream': [
              stream('http_stream', 'flv', '/live.flv'),
              stream('http_hls', 'fmp4', '/live.m3u8'),
            ],
          },
        },
      };
    } else if (options.path == Api.liveRoomInfoH5) {
      data = {
        'room_info': {'title': 'Local live fixture', 'uid': 1},
      };
    } else {
      return ResponseBody.fromString(
        jsonEncode({'code': -1, 'message': 'Local fixture has no messages'}),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    return ResponseBody.fromString(
      jsonEncode({'code': 0, 'data': data}),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
