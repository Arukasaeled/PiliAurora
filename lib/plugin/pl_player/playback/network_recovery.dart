import 'dart:async';

import 'package:pili_aurora/plugin/pl_player/utils/playback_network_recovery.dart';

typedef RecoveryState = ({
  bool buffering,
  Duration position,
  Duration buffer,
});

/// 一份媒体一轮恢复状态。计时器、限频和错误升级在这里收敛。
class PlaybackNetworkRecovery {
  PlaybackNetworkRecovery({
    required this.isCurrent,
    required this.readState,
    required this.reload,
    required this.onError,
    this.onRetry,
    this.delay = const Duration(seconds: 3),
    this.cooldown = const Duration(seconds: 10),
  });

  final bool Function() isCurrent;
  final RecoveryState? Function() readState;
  final Future<void>? Function(bool tryNextCdn) reload;
  final void Function(Object error) onError;
  final void Function()? onRetry;
  final Duration delay;
  final Duration cooldown;
  final _clock = Stopwatch()..start();
  final _attempted = <(int, bool), Duration>{};
  Timer? _timer;
  bool _requireEmptyBuffer = true;
  bool _tryNextCdn = false;
  RecoveryState? _failureState;
  (int, bool)? _scheduledAttempt;
  bool _disposed = false;
  bool get isActive => !_disposed && isCurrent();

  void schedule({
    bool requireEmptyBuffer = false,
    bool tryNextCdn = false,
    int candidate = 0,
    bool throttle = false,
  }) {
    if (_disposed || !isCurrent()) return;
    if (_timer != null) {
      _requireEmptyBuffer &= requireEmptyBuffer;
      _tryNextCdn |= tryNextCdn;
      if (!requireEmptyBuffer) _failureState = readState();
      return;
    }
    if (throttle) {
      final key = (candidate, requireEmptyBuffer);
      final last = _attempted[key];
      if (last != null && _clock.elapsed - last < cooldown) return;
      _attempted[key] = _clock.elapsed;
    }
    _requireEmptyBuffer = requireEmptyBuffer;
    _tryNextCdn = tryNextCdn;
    _scheduledAttempt = throttle ? (candidate, requireEmptyBuffer) : null;
    _failureState = requireEmptyBuffer ? null : readState();
    _timer = Timer(delay, _check);
  }

  void _check() {
    _timer = null;
    if (_disposed || !isCurrent()) return;
    final previous = _failureState;
    if (!_requireEmptyBuffer && previous != null) {
      final state = readState();
      // FFmpeg 可以自行重连；播放和缓冲终点都恢复推进后，取消这次整段重载。
      // 仅播放时钟推进可能来自剩余缓存或独立音轨，仍需保留断流恢复。
      if (state != null &&
          !state.buffering &&
          state.position > previous.position &&
          state.buffer > previous.buffer) {
        // 本次没有重载，不占用下一次真实断流的限频名额。
        if (_scheduledAttempt case final key?) _attempted.remove(key);
        return;
      }
    }
    if (_requireEmptyBuffer) {
      final state = readState();
      if (state == null) return;
      if (!hasExhaustedPlaybackBuffer(
        buffering: state.buffering,
        position: state.position,
        buffer: state.buffer,
      )) {
        if (shouldDeferPlaybackNetworkRecovery(
          buffering: state.buffering,
          position: state.position,
          buffer: state.buffer,
        )) {
          _timer = Timer(delay, _check);
        }
        return;
      }
    }
    final attempt = reload(_tryNextCdn);
    if (attempt == null) {
      _timer = Timer(delay, _check);
      return;
    }
    if (_requireEmptyBuffer) onRetry?.call();
    attempt.catchError(onError);
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    _clock.stop();
  }
}
