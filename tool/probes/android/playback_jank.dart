import 'dart:async';
import 'dart:convert';
import 'dart:developer' show Timeline;

import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:pili_aurora/plugin/pl_player/utils/android_raster_scheduling.dart';
import 'package:pili_aurora/plugin/pl_player/utils/hardware_video_configuration.dart';

/// 本地媒体与弹幕的帧时间对照，不初始化账号、网络服务或应用诊断日志。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  const uri = String.fromEnvironment('JANK_MEDIA_URI');
  if (uri.isEmpty) throw ArgumentError('需要 JANK_MEDIA_URI');
  final frames = ValueNotifier<List<int>>(const []);
  final player = await Player.create(
    configuration: const PlayerConfiguration(
      options: {'video-sync': 'display-resample', 'audio': 'no'},
    ),
  );
  final video = await VideoController.create(
    player,
    configuration: hardwareVideoConfiguration(
      enabled: true,
      configured: 'mediacodec',
      onAndroidFrameTimings: (value) => frames.value = value,
    ),
  );
  runApp(
    MaterialApp(
      home: _Probe(video: video, frames: frames),
    ),
  );
  await player.setPlaylistMode(PlaylistMode.loop);
  await player.open(const Media(uri));
}

class _Probe extends StatefulWidget {
  const _Probe({required this.video, required this.frames});
  final VideoController video;
  final ValueNotifier<List<int>> frames;
  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  static const affinityComparison = bool.fromEnvironment(
    'JANK_RASTER_AFFINITY_ABA',
  );
  static const rates = affinityComparison ? [60, 60, 60] : [90, 120, 60, 0];
  int stage = 0;
  AndroidRasterScheduling? affinity;
  DanmakuController<void>? controller;
  Timer? timer;
  final timings = <FrameTiming>[];

  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addTimingsCallback(onTimings);
    unawaited(
      widget.video.waitUntilFirstFrameRendered
          .timeout(const Duration(seconds: 20))
          .then((_) async {
            if (!mounted) return;
            if (affinityComparison) {
              affinity = await AndroidRasterScheduling.open();
              if (affinity == null) throw StateError('没有可对照的 Raster 亲和性');
            }
            if (mounted) measure();
          }),
    );
  }

  void onTimings(List<FrameTiming> value) => timings.addAll(value);

  void measure() {
    affinity?.useAppCpus(stage == 1);
    timer = Timer(const Duration(seconds: 4), () {
      if (!mounted) return;
      if (stage == 0) {
        for (var i = 0; i < 12; i++) {
          controller!.addDanmaku(DanmakuContentItem<void>('播放帧时间对照 $i'));
        }
      }
      final started = Timeline.now;
      debugPrint(
        'PILI_JANK start ${jsonEncode({
          'stage': stage,
          'target': rates[stage],
          'startedUs': started,
          if (affinity != null) 'affinity': affinity!.diagnostics,
        })}',
      );
      final updates = controller!.schedulerDiagnostics['updates'] as int;
      timings.clear();
      timer = Timer(const Duration(seconds: 8), () {
        if (!mounted) return;
        final seconds = (Timeline.now - started) / 1e6;
        final raster =
            timings.map((f) => f.rasterDuration.inMicroseconds).toList()
              ..sort();
        final build = timings
            .map((f) => f.buildDuration.inMicroseconds)
            .toList();
        final hz = View.of(context).display.refreshRate;
        debugPrint(
          'PILI_JANK ${jsonEncode({
            'stage': stage,
            'target': rates[stage],
            'startedUs': started,
            'endedUs': Timeline.now,
            'seconds': seconds,
            'updatesPerSecond': ((controller!.schedulerDiagnostics['updates'] as int) - updates) / seconds,
            'frames': raster.length,
            'slowRaster': raster.where((us) => us > 1e6 / hz).length,
            'slowBuild': build.where((us) => us > 1e6 / hz).length,
            'averageRasterUs': raster.isEmpty ? null : raster.reduce((a, b) => a + b) / raster.length,
            'p95RasterUs': raster.isEmpty ? null : raster[((raster.length - 1) * .95).round()],
            'maxRasterUs': raster.isEmpty ? null : raster.last,
            'scheduler': controller!.schedulerDiagnostics,
            if (affinity != null) 'affinity': affinity!.diagnostics,
          })}',
        );
        if (stage < rates.length - 1) {
          setState(() => stage++);
          measure();
        } else {
          affinity?.restore();
          SchedulerBinding.instance.removeTimingsCallback(onTimings);
          debugPrint('PILI_JANK done');
        }
      });
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    body: Stack(
      fit: StackFit.expand,
      children: [
        Center(
          child: FittedBox(child: SimpleVideo(controller: widget.video)),
        ),
        LayoutBuilder(
          builder: (context, constraints) => DanmakuScreen<void>(
            frameRate: rates[stage],
            videoFrameTimings: widget.frames,
            size: constraints.biggest,
            option: const DanmakuOption(
              duration: 120,
              fontSize: 20,
              massiveMode: true,
            ),
            createdController: (value) => controller = value,
          ),
        ),
      ],
    ),
  );

  @override
  void dispose() {
    timer?.cancel();
    affinity?.restore();
    SchedulerBinding.instance.removeTimingsCallback(onTimings);
    unawaited(widget.video.player.dispose());
    widget.frames.dispose();
    super.dispose();
  }
}
