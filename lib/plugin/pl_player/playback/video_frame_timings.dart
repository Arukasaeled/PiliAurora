import 'package:flutter/foundation.dart';

/// Android 用刷新请求学习调度相位，纹理消费独立证明出画。
class PlaybackVideoFrameTimings {
  PlaybackVideoFrameTimings({required this.useRequestTimings});

  final bool useRequestTimings;
  final frames = ValueNotifier<List<int>>(const []);
  final presented = ValueNotifier(false);
  int _batches = 0;
  int _samples = 0;
  int? _lastScheduled;
  int? _lastConsumed;
  int _consumedBatches = 0;
  int _consumedSamples = 0;

  void recordRequests(List<int> values) {
    if (values.isEmpty) {
      clearPhase();
    } else if (useRequestTimings) {
      _publish(values);
    }
  }

  bool recordConsumed(List<int> values) {
    if (values.isEmpty) return false;
    final last = values.reduce((left, right) => left > right ? left : right);
    if (_lastConsumed != null && last <= _lastConsumed!) return false;
    _lastConsumed = last;
    _consumedBatches++;
    _consumedSamples += values.length;
    presented.value = true;
    if (!useRequestTimings) _publish(values);
    return true;
  }

  void _publish(List<int> values) {
    _batches++;
    _samples += values.length;
    _lastScheduled = values.last;
    frames.value = List.unmodifiable(values);
  }

  Map<String, Object?> diagnostics(int now) => {
    'nativeFrameBatches': _batches,
    'nativeFrameSamples': _samples,
    if (_lastScheduled case final last?) 'nativeFrameAgeUs': now - last,
    'consumedFrameBatches': _consumedBatches,
    'consumedFrameSamples': _consumedSamples,
  };

  void clearPhase() {
    _lastScheduled = null;
    _lastConsumed = null;
    frames.value = const [];
  }

  void beginLoad() {
    clearPhase();
    presented.value = false;
  }

  void dispose() {
    frames.dispose();
    presented.dispose();
  }
}
