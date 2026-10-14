import 'dart:io';
import 'dart:ui' show FrameTiming;

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:pili_aurora/services/diagnostics/diagnostics.dart';
import 'package:pili_aurora/services/diagnostics/player_diagnostics.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('disposed players never enter native property reads', () {
    expect(readMpvProperty(_DisposedNativePlayer(), 'hwdec-current'), isNull);
  });

  test('慢帧与播放器采样并存时保留弹幕计数和诊断状态', () async {
    final directory = await Directory.systemTemp.createTemp(
      'pili-player-diag-',
    );
    final diagnostics = Diagnostics.instance;
    await diagnostics.initialize(directory: directory);
    final detachApp = diagnostics.register(
      'app',
      () => {'version': 'fixture', 'commit': 'fixture'},
    );
    final detachHome = diagnostics.register(
      'homePage',
      () => {
        'tab': 'hot',
        'transitioning': false,
        'requestPending': false,
        'state': 'success',
        'items': 20,
      },
    );
    final viewport = {
      'player': 'player.fixture',
      'outputLimitActive': true,
      'resizePolicy': 'fixed-device-output-limit',
      'handoffActive': false,
      'state': 'fixed-output',
      'deviceOutputLimit': {'width': 2510, 'height': 1156},
      'fullScreen': true,
      'playing': true,
      'positionMs': 109000,
      'fit': 'contain',
      'viewport': {'width': 836.6, 'height': 385.3},
      'devicePixelRatio': 3.0,
      'surfaceGeneration': 0,
      'textureId': 3,
      'sourceRect': {'left': 0, 'top': 0, 'width': 3840, 'height': 2160},
      'target': null,
      'applied': null,
      'transform': List<double>.filled(16, 0),
    };
    final player = _SnapshotPlayer();
    final detachViewport = diagnostics.register(
      'videoViewport.${player.hashCode}.fixture',
      () => viewport,
    );
    final playerDiagnostics = PlayerDiagnostics(
      player,
      extra: () => {
        'previewCacheBytes': 0,
        'previewCacheLimitBytes': 25165824,
        'attachedPages': 1,
        'live': false,
      },
    );
    final detachDanmaku = diagnostics.register(
      'danmaku.fixture',
      () => {
        'elements': 6755,
        'buckets': 3631,
        'pendingSegments': 0,
        'localFile': false,
        'frameRate': 60,
        'enabled': true,
      },
    );
    try {
      await diagnostics.configure(tracing: true);
      for (final operation in [
        'imageFile',
        'imageDecode',
        'imageFrame',
        'http',
        'grpcDecode',
      ]) {
        diagnostics.begin(operation, 'fixture')!.finish();
      }
      await Future<void>.delayed(Duration.zero);
      TestWidgetsFlutterBinding.instance.platformDispatcher.onReportTimings!(
        List.generate(
          16,
          (_) => FrameTiming(
            vsyncStart: 0,
            buildStart: 1000,
            buildFinish: 21000,
            rasterStart: 22000,
            rasterFinish: 52000,
            rasterFinishWallTime: 1700000000000000,
          ),
        ),
      );
      diagnostics.capture();
      final sources = diagnostics.latest!['sources'] as Map;
      expect(sources['danmaku.fixture'], containsPair('elements', 6755));
      expect(
        diagnostics.latest!['diagnostics'],
        containsPair('droppedRecords', 0),
      );
      expect(
        sources[playerDiagnostics.playerId],
        containsPair('hwdec-current', 'mediacodec'),
      );
      expect(playerDiagnostics.snapshot(), contains('track-list'));
    } finally {
      detachDanmaku();
      detachViewport();
      detachApp();
      detachHome();
      playerDiagnostics.dispose();
      diagnostics.dispose();
      await diagnostics.flush();
      await directory.delete(recursive: true);
    }
  });
}

class _DisposedNativePlayer implements NativePlayer {
  @override
  bool get disposed => true;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Disposed player must not access native state');
}

class _SnapshotPlayer implements NativePlayer {
  @override
  bool get disposed => true;
  @override
  final state = PlayerState();
  @override
  final onLoadHooks = <Future<void> Function()>[];
  @override
  final onUnloadHooks = <Future<void> Function()>[];
  @override
  final stream = _EmptyStreams();
  @override
  Stream<String?> observeProperty(String name) => Stream.value(
    name == 'hwdec-current' ? 'mediacodec' : 'fixture-$name',
  );
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected native operation: ${invocation.memberName}');
}

class _EmptyStreams implements PlayerStream {
  @override
  Stream<PlayerLog> get log => const Stream.empty();
  @override
  Stream<bool> get playing => const Stream.empty();
  @override
  Stream<bool> get buffering => const Stream.empty();
  @override
  Stream<bool> get completed => const Stream.empty();
  @override
  Stream<VideoParams> get videoParams => const Stream.empty();
  @override
  Stream<String> get error => const Stream.empty();
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected player stream: ${invocation.memberName}');
}
