import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:pili_aurora/plugin/pl_player/playback/frame_timing.dart';

/// 相位准入与出画证据分别更新，关闭相位不撤回已出画事实。
class PlaybackVideoFrameTimings implements PlaybackFrameSource {
  PlaybackVideoFrameTimings({required this.useRequestTimings});

  final bool useRequestTimings;
  final _state = ValueNotifier(const PlaybackFrameState());
  @override
  ValueListenable<PlaybackFrameState> get frameState => _state;
  final presented = ValueNotifier(false);
  final frames = ValueNotifier<List<int>>(const []);
  final _gate = VideoFrameEventGate();
  bool _enabled = false;
  int _batches = 0, _samples = 0, _consumedBatches = 0, _consumedSamples = 0;
  int? _lastScheduled, _lastConsumed;

  void beginLoad(OutputOperationToken output, int nowUs) {
    _gate.bind(output);
    _enabled = false;
    _lastConsumed = null;
    _lastScheduled = null;
    frames.value = const [];
    presented.value = false;
    _state.value = PlaybackFrameState(
      output: output,
      epoch: _state.value.epoch + 1,
      samplesValidAfterUs: nowUs,
      displaySyncActive: _state.value.displaySyncActive,
      frameTimelineSupported: _state.value.frameTimelineSupported,
    );
  }

  void withdraw(int nowUs) {
    _gate.bind(null);
    _enabled = false;
    _lastScheduled = null;
    frames.value = const [];
    _state.value = PlaybackFrameState(
      epoch: _state.value.epoch + 1,
      samplesValidAfterUs: nowUs,
      frameTimelineSupported: _state.value.frameTimelineSupported,
    );
  }

  void setEnabled(bool enabled, int nowUs) {
    if (_enabled == enabled) return;
    _enabled = enabled;
    invalidate(nowUs);
  }

  void invalidate(int nowUs) {
    final old = _state.value;
    _lastScheduled = null;
    frames.value = const [];
    _state.value = PlaybackFrameState(
      output: old.output,
      samplingGeneration: old.samplingGeneration,
      epoch: old.epoch + 1,
      samplesValidAfterUs: math.max(old.samplesValidAfterUs, nowUs),
      displaySyncActive: old.displaySyncActive,
      frameTimelineSupported: old.frameTimelineSupported,
    );
  }

  void setDisplaySyncActive(bool active) {
    final old = _state.value;
    if (old.displaySyncActive == active) return;
    _publish(old, displaySyncActive: active, samples: old.videoSamples);
  }

  void setFrameTimelineSupported(bool supported) {
    final old = _state.value;
    if (old.frameTimelineSupported == supported) return;
    _publish(old, frameTimelineSupported: supported, samples: old.videoSamples);
  }

  void accept(VideoFrameEvent event) {
    if (!_gate.accept(event)) return;
    final old = _state.value;
    if (event is VideoFrameSamplingState) {
      _lastScheduled = null;
      frames.value = const [];
      _state.value = PlaybackFrameState(
        output: event.output,
        samplingGeneration: event.samplingGeneration,
        admission: _enabled
            ? event.admission
            : VideoFrameSamplingAdmission.blocked,
        epoch: old.epoch + 1,
        samplesValidAfterUs: math.max(
          old.samplesValidAfterUs,
          event.validAfterUs,
        ),
        displaySyncActive: old.displaySyncActive,
        frameTimelineSupported: old.frameTimelineSupported,
      );
      return;
    }
    final batch = event as VideoFrameBatch;
    if (!_enabled ||
        old.admission != VideoFrameSamplingAdmission.active ||
        batch.samplingGeneration != old.samplingGeneration ||
        batch.kind !=
            (useRequestTimings
                ? VideoFrameSampleKind.refreshRequested
                : VideoFrameSampleKind.textureConsumed)) {
      return;
    }
    final values =
        batch.monotonicUs
            .where((t) => t > old.samplesValidAfterUs)
            .toSet()
            .toList()
          ..sort();
    if (values.length > 64) values.removeRange(0, values.length - 64);
    if (values.isEmpty) return;
    _batches++;
    _samples += values.length;
    _lastScheduled = values.last;
    frames.value = List.unmodifiable(values);
    _publish(
      old,
      samples: VideoFrameBatch(
        output: batch.output,
        samplingGeneration: batch.samplingGeneration,
        kind: batch.kind,
        sequence: batch.sequence,
        monotonicUs: values,
      ),
    );
  }

  void _publish(
    PlaybackFrameState old, {
    VideoFrameBatch? samples,
    bool? displaySyncActive,
    bool? frameTimelineSupported,
  }) {
    _state.value = PlaybackFrameState(
      output: old.output,
      samplingGeneration: old.samplingGeneration,
      admission: old.admission,
      epoch: old.epoch,
      samplesValidAfterUs: old.samplesValidAfterUs,
      displaySyncActive: displaySyncActive ?? old.displaySyncActive,
      frameTimelineSupported:
          frameTimelineSupported ?? old.frameTimelineSupported,
      videoSamples: samples,
    );
  }

  bool recordConsumed(List<int> values) {
    if (values.isEmpty) return false;
    final last = values.reduce(math.max);
    if (_lastConsumed != null && last <= _lastConsumed!) return false;
    _lastConsumed = last;
    _consumedBatches++;
    _consumedSamples += values.length;
    presented.value = true;
    return true;
  }

  Map<String, Object?> diagnostics(int now) => {
    'nativeFrameBatches': _batches,
    'nativeFrameSamples': _samples,
    if (_lastScheduled case final last?) 'nativeFrameAgeUs': now - last,
    'consumedFrameBatches': _consumedBatches,
    'consumedFrameSamples': _consumedSamples,
    'samplingGeneration': _state.value.samplingGeneration,
    'samplingAdmission': _state.value.admission.name,
    'sourceEpoch': _state.value.epoch,
  };

  void dispose() {
    _state.dispose();
    frames.dispose();
    presented.dispose();
  }
}
