import 'dart:developer' show Timeline;
import 'dart:ui' show FlutterView;

import 'package:canvas_danmaku/frame_rate_ticker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:media_kit_video/media_kit_video.dart' show OutputOperationToken;
import 'package:pili_aurora/plugin/pl_player/playback/frame_timing.dart';
import 'package:pili_aurora/plugin/pl_player/playback/presentation_profile.dart';

final class DanmakuFrame {
  const DanmakuFrame({
    required this.targetUs,
    required this.nowUs,
    required this.viewEpoch,
  });

  final int targetUs, nowUs, viewEpoch;
}

/// 每个显示实例持有一份，内容期限与媒体时间仍由挂载方维护。
class DanmakuFrameScheduler with WidgetsBindingObserver {
  DanmakuFrameScheduler({
    required this.onFrame,
    PresentationEngineConfiguration? engine,
    TargetPlatform? platform,
  }) : engine = engine ?? presentationEngineConfiguration,
       _platform = platform ?? defaultTargetPlatform {
    _ticker = FrameRateTicker(
      (_) => _deliver(),
      videoFrameTimings: _frames,
      screenRefreshRate: () => _view?.display.refreshRate ?? 0,
      beforeFrame: _checkView,
      beforeTimings: _checkView,
    );
    WidgetsBinding.instance.addObserver(this);
  }

  final void Function(DanmakuFrame) onFrame;
  final PresentationEngineConfiguration engine;
  final TargetPlatform _platform;
  final _frames = ValueNotifier<List<int>>(const []);
  late final FrameRateTicker _ticker;
  FlutterView? _view;
  (int, int, double)? _display;
  PlaybackFrameSource? _source;
  OutputOperationToken? _output;
  int? _sourceEpoch;
  final _sequences = <VideoFrameSampleKind, int>{};
  int _viewEpoch = 0;
  int? _oneShot;
  bool _enabled = false, _disposed = false, _delivered = false;
  int _deliveries = 0, _sampleBatches = 0, _oneShotRequests = 0;

  bool get isContinuous => _ticker.isActive;

  Map<String, Object?> get diagnostics => {
    ..._ticker.diagnostics,
    'updates': _deliveries,
    'frameRequests':
        (_ticker.diagnostics['frameRequests'] as int) + _oneShotRequests,
    'viewEpoch': _viewEpoch,
    'sourceEpoch': _sourceEpoch,
    'videoSampleBatches': _sampleBatches,
    'viewId': _display?.$1,
    'displayId': _display?.$2,
    'engineProfile': engine.profile.name,
    'engineIdentity': engine.identityDigest,
    'frameTimelineSupported': _source?.frameState.value.frameTimelineSupported,
    'displaySyncActive': _source?.frameState.value.displaySyncActive,
  };

  void configure({
    required FlutterView view,
    required PlaybackFrameSource source,
    required int targetFrameRate,
    required bool enabled,
    required bool continuous,
  }) {
    if (_disposed) return;
    final sourceChanged = !identical(source, _source);
    if (sourceChanged || _enabled && !enabled) {
      _source?.frameState.removeListener(_acceptSource);
    }
    if (sourceChanged) {
      _source = source;
      _sourceEpoch = null;
      _output = null;
      _sequences.clear();
      _invalidate();
    }
    if (!identical(_view, view)) _display = null;
    _view = view;
    _checkView();
    _ticker.frameRate = _platform == TargetPlatform.windows
        ? 0
        : targetFrameRate;
    final disabling = _enabled && !enabled;
    final enabling = enabled && (!_enabled || sourceChanged);
    _enabled = enabled;
    if (!enabled) {
      _cancelOneShot();
      _ticker.stop();
      if (disabling) _invalidate();
      return;
    }
    if (enabling) {
      source.frameState.addListener(_acceptSource);
      _acceptSource();
    }
    if (continuous && !_ticker.isActive) {
      _cancelOneShot();
      _ticker.start();
    } else if (!continuous && _ticker.isActive) {
      _ticker.stop();
    }
  }

  void _invalidate() {
    _ticker.invalidatePhase();
    _frames.value = const [];
  }

  void _checkView() {
    final view = _view;
    if (_disposed || view == null) return;
    final snapshot = (view.viewId, view.display.id, view.display.refreshRate);
    if (_display == snapshot) return;
    _display = snapshot;
    _viewEpoch++;
    _invalidate();
  }

  @override
  void didChangeMetrics() => _checkView();

  void _acceptSource() {
    if (!_enabled || _disposed) return;
    final state = _source!.frameState.value;
    if (state.output != _output) {
      _output = state.output;
      _sequences.clear();
      _sourceEpoch = null;
    }
    if (_sourceEpoch != state.epoch) {
      _sourceEpoch = state.epoch;
      _invalidate();
    }
    final android = _platform == TargetPlatform.android;
    _ticker.configureVideoPhase(
      continuousVideoVsync: android,
      preserveVideoPhase:
          android &&
          engine.profile == PresentationProfile.androidFramePlan &&
          state.frameTimelineSupported,
    );
    final batch = state.videoSamples;
    if (state.admission != VideoFrameSamplingAdmission.active ||
        batch == null ||
        batch.output != _output ||
        batch.samplingGeneration != state.samplingGeneration ||
        batch.sequence <= (_sequences[batch.kind] ?? -1)) {
      return;
    }
    _sequences[batch.kind] = batch.sequence;
    _sampleBatches++;
    if (android && batch.kind == VideoFrameSampleKind.refreshRequested) {
      _frames.value = List.unmodifiable(
        batch.monotonicUs.where((t) => t > state.samplesValidAfterUs),
      );
    }
  }

  void requestFrame() {
    if (!_enabled || _disposed || _ticker.isActive || _oneShot != null) return;
    _oneShotRequests++;
    _oneShot = SchedulerBinding.instance.scheduleFrameCallback((_) {
      _oneShot = null;
      _deliver();
    });
  }

  void _deliver() {
    if (!_enabled || _disposed || _delivered) return;
    _checkView();
    _delivered = true;
    SchedulerBinding.instance.addPostFrameCallback((_) => _delivered = false);
    _deliveries++;
    onFrame(
      DanmakuFrame(
        targetUs: SchedulerBinding
            .instance
            .currentSystemFrameTimeStamp
            .inMicroseconds,
        nowUs: Timeline.now,
        viewEpoch: _viewEpoch,
      ),
    );
  }

  void _cancelOneShot() {
    if (_oneShot case final id?) {
      SchedulerBinding.instance.cancelFrameCallbackWithId(id);
    }
    _oneShot = null;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _source?.frameState.removeListener(_acceptSource);
    WidgetsBinding.instance.removeObserver(this);
    _cancelOneShot();
    _ticker.dispose();
    _frames.dispose();
  }
}
