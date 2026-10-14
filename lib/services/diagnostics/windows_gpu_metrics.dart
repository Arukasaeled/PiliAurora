import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// 原生线程按秒采样；高频诊断读取最近快照。
class WindowsGpuMetrics {
  static const _channel = MethodChannel('pili_aurora/windows_gpu');
  Timer? _timer;
  int _generation = 0;
  bool _reading = false;
  Map<String, Object?> _latest = {'status': 'warmingUp'};
  final _clock = Stopwatch()..start();
  int? _receivedMs;

  Map<String, Object?> sample() => {
    ..._latest,
    'cacheAgeMs': _receivedMs == null
        ? null
        : _clock.elapsedMilliseconds - _receivedMs!,
  };

  Future<void> start() async {
    if (!Platform.isWindows) return;
    final generation = ++_generation;
    _timer?.cancel();
    _latest = {'status': 'warmingUp'};
    _receivedMs = null;
    try {
      await _channel.invokeMethod<void>('start');
      if (generation != _generation) return;
      _timer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => _read(generation),
      );
      await _read(generation);
    } catch (_) {
      if (generation == _generation) _latest = {'status': 'unavailable'};
    }
  }

  Future<void> _read(int generation) async {
    if (_reading) return;
    _reading = true;
    try {
      final data = await _channel.invokeMapMethod<String, Object?>('sample');
      if (generation == _generation && data != null) {
        _latest = data;
        _receivedMs = _clock.elapsedMilliseconds;
      }
    } catch (_) {
      if (generation == _generation) _latest = {'status': 'unavailable'};
    } finally {
      _reading = false;
    }
  }

  Future<void> stop() async {
    ++_generation;
    _timer?.cancel();
    _timer = null;
    if (!Platform.isWindows) return;
    try {
      await _channel.invokeMethod<void>('stop');
    } catch (_) {
      // 引擎退出时通道可能已经释放。
    }
  }
}
