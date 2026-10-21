import 'dart:async';

import 'package:pili_aurora/plugin/pl_player/playback/media_clock.dart';

/// 合并采样通知，释放时等待仍在访问原生句柄的读取退出。
class NativeMediaClockSampling {
  int _revision = 0;
  bool _closed = false;
  Future<void>? _running;
  ({
    Future<PlaybackMediaAnchor?> Function() read,
    void Function(PlaybackMediaAnchor) publish,
  })?
  _pending;

  Future<void> get idle => _running ?? Future<void>.value();

  void request(
    Future<PlaybackMediaAnchor?> Function() read,
    void Function(PlaybackMediaAnchor) publish,
  ) {
    if (_closed) return;
    _revision++;
    _pending = (read: read, publish: publish);
    // 先登记任务，再开始读取，通知重入时仍共用同一个在途任务。
    _running ??= Future<void>.microtask(_drain);
  }

  void invalidate() {
    _revision++;
    _pending = null;
  }

  Future<void> _drain() async {
    try {
      while (!_closed && _pending != null) {
        final sample = _pending!;
        _pending = null;
        final revision = _revision;
        PlaybackMediaAnchor? anchor;
        try {
          anchor = await sample.read();
        } catch (_) {
          // 文件退出期间可能无法读取属性，后续通知仍可重新采样。
        }
        if (!_closed && revision == _revision && anchor != null) {
          sample.publish(anchor);
        }
      }
    } finally {
      _running = null;
    }
  }

  Future<void> close() async {
    _closed = true;
    invalidate();
    await _running;
  }
}
