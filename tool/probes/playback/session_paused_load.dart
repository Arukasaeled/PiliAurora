import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:pili_aurora/plugin/pl_player/models/data_source.dart';
import 'package:pili_aurora/plugin/pl_player/playback/native_playback_runtime.dart';
import 'package:pili_aurora/plugin/pl_player/playback/playback_contracts.dart';
import 'package:pili_aurora/plugin/pl_player/playback/playback_session.dart';

/// 使用生产 Session/Runtime 检查暂停起播、重载与真实释放；输入保持在本机。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  const source = String.fromEnvironment('PAUSED_OUTPUT_MEDIA');
  const output = String.fromEnvironment('PAUSED_OUTPUT_REPORT');
  const shader = String.fromEnvironment('SESSION_SHADER');
  if (source.isEmpty || output.isEmpty) {
    throw ArgumentError('需要本地媒体与报告路径');
  }
  final runtime = NativePlaybackRuntime(
    configuration: PlaybackRuntimeConfig(
      playerOptions: const {'ao': 'null'},
      hardwareAccelerationEnabled: true,
      hardwareDecoder: 'auto-safe',
    ),
    diagnosticsExtra: () => const {},
  );
  final session = PlaybackSession(runtime: runtime);
  final owner = session.attach();
  final report = <String, Object?>{};
  runApp(const MaterialApp(home: ColoredBox(color: Colors.black)));
  final attach = Timer.periodic(const Duration(milliseconds: 20), (timer) {
    final video = runtime.videoController;
    if (video == null) return;
    runApp(
      MaterialApp(
        home: Center(child: SimpleVideo(controller: video)),
      ),
    );
    timer.cancel();
  });
  final plan = PlaybackPlan(
    contentKey: 'local-fixture',
    source: PlaybackSourceSnapshot.fromDataSource(
      NetworkSource(videoSource: source, audioSource: null),
    ),
    timeline: const PlaybackTimeline(
      kind: PlaybackTimelineKind.onDemand,
      seekPolicy: PlaybackSeekPolicy.allowed,
    ),
    configuration: PlaybackConfiguration(),
  );
  try {
    final first = await owner.load(plan, start: PlaybackStartPolicy.pause);
    report['firstLoad'] = first.outcome.name;
    report['firstFailure'] = first.failure?.operation;
    report['firstLoadId'] = session.loadId;
    final second = await owner.load(plan, start: PlaybackStartPolicy.preserve);
    report['secondLoad'] = second.outcome.name;
    report['secondFailure'] = second.failure?.operation;
    report['secondLoadId'] = session.loadId;
    report['paused'] = runtime.player?.state.playing == false;
    report['passed'] =
        first.outcome == LoadOutcome.ready &&
        second.outcome == LoadOutcome.ready &&
        report['paused'] == true;
    if (shader.isNotEmpty) {
      final live = PlaybackPlan(
        contentKey: 'live-policy-fixture',
        source: plan.source,
        timeline: const PlaybackTimeline(
          kind: PlaybackTimelineKind.live,
          seekPolicy: PlaybackSeekPolicy.disabled,
        ),
        configuration: plan.configuration,
      );
      final loaded = await owner.load(live, start: PlaybackStartPolicy.pause);
      final before = session.loadId;
      final changed = await owner.setShader([shader]);
      final shaderReloaded = session.loadId == before + 1;
      final cleared = await owner.setShader([]);
      report['liveLoad'] = loaded.outcome.name;
      report['shaderChange'] = changed.outcome.name;
      report['shaderClear'] = cleared.outcome.name;
      report['shaderReloaded'] = shaderReloaded;
      report['liveStillPaused'] = runtime.player?.state.playing == false;
      report['passed'] =
          report['passed'] == true &&
          loaded.outcome == LoadOutcome.ready &&
          changed.outcome == CommandOutcome.applied &&
          cleared.outcome == CommandOutcome.applied &&
          shaderReloaded &&
          report['liveStillPaused'] == true;
    }
  } catch (error) {
    report['errorType'] = error.runtimeType.toString();
    report['passed'] = false;
  } finally {
    attach.cancel();
    owner.close();
    final closed = await session.shutdown();
    report['shutdown'] = closed.outcome.name;
    if (closed.outcome != PlaybackShutdownOutcome.released) {
      report['passed'] = false;
    }
    final file = File(output);
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(report),
    );
  }
  exit(report['passed'] == true ? 0 : 1);
}
