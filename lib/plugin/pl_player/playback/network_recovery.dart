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
  bool _allowNativeRecovery = true;
  bool _waitForCachedPlayback = false;
  bool _tryNextCdn = false;
  RecoveryState? _failureState;
  (int, bool)? _scheduledAttempt;
  bool _disposed = false;
  bool get isActive => !_disposed && isCurrent();

  /// 强制恢复可关闭进度判断；分离音视频的读取失败可先保留主视频缓存。
  void schedule({
    bool requireEmptyBuffer = false,
    bool allowNativeRecovery = true,
    bool waitForCachedPlayback = false,
    bool tryNextCdn = false,
    int candidate = 0,
    bool throttle = false,
  }) {
    if (_disposed || !isCurrent()) return;
    if (_timer != null) {
      _requireEmptyBuffer &= requireEmptyBuffer;
      _allowNativeRecovery &= allowNativeRecovery;
      _waitForCachedPlayback |= waitForCachedPlayback;
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
    _allowNativeRecovery = allowNativeRecovery;
    _waitForCachedPlayback = waitForCachedPlayback;
    _tryNextCdn = tryNextCdn;
    _scheduledAttempt = throttle ? (candidate, requireEmptyBuffer) : null;
    _failureState = requireEmptyBuffer && !waitForCachedPlayback
        ? null
        : readState();
    _timer = Timer(delay, _check);
  }

  void _check() {
    _timer = null;
    if (_disposed || !isCurrent()) return;
    final previous = _failureState;
    if (_allowNativeRecovery && !_requireEmptyBuffer && previous != null) {
      final state = readState();
      // 新读入的数据需补足已消耗的时长，残余损坏包的少量推进仍要等待缓存耗尽。
      if (state != null &&
          !state.buffering &&
          state.buffer > state.position &&
          state.position > previous.position &&
          state.buffer > previous.buffer &&
          state.buffer - state.position >=
              previous.buffer - previous.position) {
        // 本次没有重载，不占用下一次真实断流的限频名额。
        if (_scheduledAttempt case final key?) _attempted.remove(key);
        return;
      }
    }
    if (_waitForCachedPlayback) {
      final state = readState();
      if (state == null) return;
      // 分离音视频可能由另一轨推进时钟；主视频缓存耗尽后再恢复画面。
      if (state.buffer > state.position) {
        _timer = Timer(delay, _check);
        return;
      }
    } else if (_requireEmptyBuffer) {
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
