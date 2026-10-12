import 'dart:async';

import 'package:pili_aurora/plugin/pl_player/utils/playback_network_recovery.dart';

typedef AudioRecoveryState = ({
  bool playing,
  bool waiting,
  bool completed,
  Duration position,
  Duration duration,
  double? audioPts,
  double audioDelay,
});

/// 出错后观察音频时钟；依次尝试外部音轨重连和一次整段重载。
class PlaybackAudioRecovery {
  PlaybackAudioRecovery({
    required this.readState,
    required this.repairAudio,
    required this.reload,
    required this.onError,
    this.onDiagnostic,
    this.onExhausted,
    this.elapsedMilliseconds,
  });

  final AudioRecoveryState? Function() readState;
  // null 表示加载繁忙；false 表示当前来源不支持独立音轨重连。
  final Future<bool>? Function() repairAudio;
  final Future<void>? Function() reload;
  final void Function(Object error) onError;
  final void Function(String action)? onDiagnostic;
  final void Function()? onExhausted;
  final int Function()? elapsedMilliseconds;
  final _clock = Stopwatch()..start();
  Timer? _timer;
  AudioRecoveryState? _previous;
  int _generation = 0;
  int _watchUntilMs = 0;
  int? _healthySinceMs;
  bool _watching = false;
  bool _inFlight = false;
  bool _playbackChanged = false;
  bool _audioAttempted = false;
  bool _reloadAttempted = false;
  bool _notified = false;
  bool _decoderFailed = false;
  bool _permissionDenied = false;
  bool _disposed = false;
  int get _nowMs => elapsedMilliseconds?.call() ?? _clock.elapsedMilliseconds;
  bool get isActive => !_disposed && readState() != null;

  void onLog({
    required String prefix,
    required String level,
    required String message,
  }) {
    if (_disposed || (level != 'error' && level != 'fatal')) return;
    if (isPlaybackPermissionFailure(message)) {
      reset();
      _permissionDenied = true;
      return;
    }
    if (_permissionDenied) return;
    final audioError =
        prefix == 'ffmpeg/audio' ||
        (prefix == 'ad' && message == 'Error decoding audio.');
    if (!audioError &&
        !isPlaybackStreamReadFailure(
          prefix: prefix,
          level: level,
          message: message,
        )) {
      return;
    }
    if (readState() == null) return;
    if (prefix == 'ad' && message == 'Error decoding audio.') {
      _decoderFailed = true;
    }
    if (!_watching) {
      _previous = null;
      _healthySinceMs = null;
    }
    _watching = true;
    _watchUntilMs = _nowMs + 30000;
    _schedule();
  }

  /// 暂停、缓冲、拖动和静音期间让出恢复；恢复播放后继续确认遗留故障。
  void onPlaybackChanged() {
    if (_disposed || !_watching) return;
    if (_inFlight) {
      _playbackChanged = true;
      return;
    }
    _timer?.cancel();
    _timer = null;
    _previous = null;
    _healthySinceMs = null;
    _watchUntilMs = _nowMs + 30000;
    _schedule();
  }

  bool _canObserve(AudioRecoveryState state) =>
      state.playing &&
      !state.waiting &&
      !state.completed &&
      (state.duration == Duration.zero ||
          state.position < state.duration - const Duration(seconds: 2));

  void _schedule() {
    if (_disposed || !_watching || _inFlight || _timer != null) return;
    final state = readState();
    if (state == null) {
      reset();
      return;
    }
    if (!_canObserve(state)) return;
    _previous ??= state;
    _timer = Timer(Duration(seconds: _notified ? 10 : 2), _check);
  }

  void _check() {
    _timer = null;
    final state = readState();
    if (_disposed || state == null) {
      reset();
      return;
    }
    if (!_canObserve(state)) {
      _previous = null;
      _healthySinceMs = null;
      return;
    }
    final previous = _previous;
    _previous = state;
    if (previous == null ||
        (state.position <= previous.position && !_decoderFailed)) {
      _healthySinceMs = null;
      _schedule();
      return;
    }
    final pts = state.audioPts;
    final audioProgress =
        pts != null &&
        pts.isFinite &&
        (previous.audioPts == null || pts > previous.audioPts!);
    // 比较时间戳而非音量，静音片段仍会推进音频时钟。
    final inSync =
        pts != null &&
        pts.isFinite &&
        (state.position.inMicroseconds / 1000000 - state.audioDelay - pts)
                .abs() <
            1.5;
    if (audioProgress && inSync) {
      _decoderFailed = false;
      _healthySinceMs ??= _nowMs;
      if (_nowMs - _healthySinceMs! >= 30000) {
        reset();
        onDiagnostic?.call('audio.recovery.healthy');
        return;
      }
      if (!_audioAttempted && !_reloadAttempted && _nowMs >= _watchUntilMs) {
        _watching = false;
        _previous = null;
        return;
      }
      _schedule();
      return;
    }
    _healthySinceMs = null;
    if (_audioAttempted && _reloadAttempted) {
      if (!_notified) {
        _notified = true;
        onDiagnostic?.call('audio.recovery.exhausted');
        onExhausted?.call();
      }
      _schedule();
      return;
    }
    unawaited(_recover());
  }

  Future<void> _recover() async {
    final generation = _generation;
    _inFlight = true;
    _playbackChanged = false;
    try {
      if (!_audioAttempted) {
        final repair = repairAudio();
        if (repair == null) return;
        _audioAttempted = true;
        onDiagnostic?.call('audio.recovery.track.begin');
        final supported = await repair.timeout(const Duration(seconds: 8));
        if (_disposed || generation != _generation) return;
        if (supported) {
          onDiagnostic?.call('audio.recovery.track.completed');
          return;
        }
        if (_playbackChanged) return;
      }
      final state = readState();
      if (state == null || !_canObserve(state)) return;
      final attempt = reload();
      if (attempt == null) return;
      _reloadAttempted = true;
      onDiagnostic?.call('audio.recovery.media.begin');
      await attempt;
      if (!_disposed && generation == _generation) {
        onDiagnostic?.call('audio.recovery.media.completed');
      }
    } catch (error) {
      if (!_disposed && generation == _generation) onError(error);
    } finally {
      if (!_disposed && generation == _generation) {
        _inFlight = false;
        _previous = null;
        _schedule();
      }
    }
  }

  void reset() {
    _generation++;
    _timer?.cancel();
    _timer = null;
    _previous = null;
    _healthySinceMs = null;
    _watching = false;
    _inFlight = false;
    _playbackChanged = false;
    _audioAttempted = false;
    _reloadAttempted = false;
    _notified = false;
    _decoderFailed = false;
    _permissionDenied = false;
  }

  void dispose() {
    _disposed = true;
    reset();
    _clock.stop();
  }
}
