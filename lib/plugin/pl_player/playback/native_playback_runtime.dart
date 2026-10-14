import 'dart:io';
import 'dart:async' show StreamSubscription;
import 'dart:developer' show Timeline;

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:pili_aurora/http/browser_ua.dart';
import 'package:pili_aurora/http/constants.dart';
import 'package:pili_aurora/services/android_video_output_limit.dart';
import 'package:pili_aurora/services/diagnostics/diagnostics.dart';
import 'package:pili_aurora/services/diagnostics/player_diagnostics.dart';
import 'package:pili_aurora/services/windows_video_output_limit.dart';
import 'package:pili_aurora/utils/platform_utils.dart';
import 'package:pili_aurora/utils/storage_pref.dart';

import 'package:pili_aurora/plugin/pl_player/models/data_source.dart';
import 'package:pili_aurora/plugin/pl_player/utils/hardware_video_configuration.dart';
import 'package:pili_aurora/plugin/pl_player/utils/native_media_source.dart';

/// 原生资源只在首次加载时创建，切源复用 Player、VideoController 和纹理输出。
class NativePlaybackRuntime {
  NativePlaybackRuntime({required this.diagnosticsExtra});

  final Map<String, Object?> Function() diagnosticsExtra;
  Player? _player;
  VideoController? _videoController;
  PlayerDiagnostics? _diagnostics;
  bool _disposed = false;
  final videoFrameTimings = ValueNotifier<List<int>>(const []);
  final videoDisplaySyncActive = ValueNotifier<bool>(false);
  StreamSubscription<String?>? _videoSyncSubscription;
  int _videoFrameBatches = 0;
  int _videoFrameSamples = 0;
  int? _lastVideoFrame;

  Map<String, Object?> get videoFrameDiagnostics => {
    'nativeFrameBatches': _videoFrameBatches,
    'nativeFrameSamples': _videoFrameSamples,
    if (_lastVideoFrame case final stamp?)
      'nativeFrameAgeUs': Timeline.now - stamp,
  };

  Player? get player => _player;
  VideoController? get videoController => _videoController;
  PlayerDiagnostics? get diagnostics => _diagnostics;

  /// 由会话加载队列调用；尚未发布的资源在初始化失败或关闭时就地释放。
  Future<Player?> initialize({
    required double volume,
    int? width,
    int? height,
  }) async {
    if (_disposed) return null;
    if (_player != null) return _player;
    final options = {
      'video-sync': Pref.videoSync,
      // ANGLE 硬解表面可能带有对齐填充；部分驱动上 mpv 简化渲染会采样到填充区。
      // 使用完整渲染路径保留有效画面边界，解码器配置继续由 VideoController 管理。
      if (Platform.isWindows) 'gpu-dumb-mode': 'no',
      if (Platform.isAndroid) 'ao': Pref.audioOutput,
      'volume': (PlatformUtils.isMobile ? Pref.playerVolume : volume * 100)
          .toString(),
      if (Pref.autosync != '0') 'autosync': Pref.autosync,
    };
    final player = await Player.create(
      configuration: PlayerConfiguration(
        logLevel: kDebugMode ? .warn : .error,
        options: options,
      ),
    );
    if (_disposed) {
      await player.dispose();
      return null;
    }
    final diagnostics = PlayerDiagnostics(player, extra: diagnosticsExtra);
    final VideoController video;
    try {
      video = await VideoController.create(
        player,
        configuration: hardwareVideoConfiguration(
          enabled: Pref.enableHA,
          configured: Pref.hardwareDecoding,
          windowsSourceSize:
              Platform.isWindows && width != null && height != null
              ? (width: width, height: height)
              : null,
          windowsOutputLimit: Platform.isWindows
              ? WindowsVideoOutputLimit.detected
              : null,
          androidOutputLimit: Platform.isAndroid
              ? () => Pref.enableAndroidTextureScaling
                    ? AndroidVideoOutputLimit.detected
                    : null
              : null,
          onAndroidDiagnostic: (action, details) => diagnostics.event(
            action,
            level: action.contains('error')
                ? DiagnosticLogLevel.error
                : DiagnosticLogLevel.info,
            details: details,
          ),
          onAndroidFrameTimings: (frames) {
            if (_disposed) return;
            if (frames.isNotEmpty) {
              _videoFrameBatches++;
              _videoFrameSamples += frames.length;
              _lastVideoFrame = frames.last;
            } else {
              _lastVideoFrame = null;
            }
            videoFrameTimings.value = frames;
          },
        ),
      );
      if (Platform.isAndroid) player.setProperty('force-window', 'no');
      player.setMediaHeader(
        userAgent: BrowserUa.pc,
        referer: HttpString.baseUrl,
      );
    } catch (error) {
      diagnostics
        ..event(
          'player.create.failed',
          level: DiagnosticLogLevel.error,
          details: {'error': error},
        )
        ..dispose();
      await player.dispose();
      rethrow;
    }
    if (_disposed) {
      diagnostics.dispose();
      await player.dispose();
      return null;
    }
    _player = player;
    _videoController = video;
    _diagnostics = diagnostics;
    // display-* 设置可能在播放中回退到音频时钟，使用实际生效状态。
    _videoSyncSubscription = player
        .observeProperty('display-sync-active')
        .listen(
          (value) {
            if (!_disposed) videoDisplaySyncActive.value = value == 'yes';
          },
          onError: (Object error) {
            if (!_disposed) videoDisplaySyncActive.value = false;
          },
        );
    return player;
  }

  Future<bool> open({
    required DataSource source,
    required bool audioOnly,
    required bool Function() isCurrent,
    Duration? start,
    Map<String, String> extras = const {},
  }) async {
    final player = _player;
    if (_disposed || player == null || !isCurrent()) return false;
    videoFrameTimings.value = const [];
    _videoFrameBatches = _videoFrameSamples = 0;
    _lastVideoFrame = null;
    player.setProperty(
      'hwdec',
      hardwareVideoConfiguration(
        enabled: Pref.enableHA,
        configured: Pref.hardwareDecoding,
      ).hwdec!,
    );
    _diagnostics?.event(
      'media.open.requested',
      details: {
        'startMs': start?.inMilliseconds,
        'sourceType': source.runtimeType.toString(),
        'audioOnly': audioOnly,
      },
    );
    final watch = Stopwatch()..start();
    await player.open(
      nativeMediaSource(
        source: source,
        audioOnly: audioOnly,
        start: start,
        extras: extras,
      ),
      play: false,
    );
    _diagnostics?.event(
      'media.open.completed',
      details: {
        'durationUs': watch.elapsedMicroseconds,
        'isCurrent': isCurrent(),
      },
    );
    return !_disposed && isCurrent();
  }

  /// 先使资源不可见，再等已发出的原生操作结束，避免 open 与 dispose 交错。
  Future<void> dispose({required Future<void> after}) async {
    if (_disposed) return;
    _disposed = true;
    videoFrameTimings.value = const [];
    videoDisplaySyncActive.value = false;
    final player = _player;
    _player = null;
    _videoController = null;
    _diagnostics?.dispose();
    _diagnostics = null;
    await _videoSyncSubscription?.cancel();
    _videoSyncSubscription = null;
    await after;
    await player?.dispose();
    videoFrameTimings.dispose();
    videoDisplaySyncActive.dispose();
  }
}
