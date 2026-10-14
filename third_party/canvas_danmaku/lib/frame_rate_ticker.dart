import 'dart:async';
import 'dart:developer';
import 'dart:ui' show FramePhase;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// 复用已有 vsync 并按目标间隔更新；没有其它帧来源时定时请求刷新。
class FrameRateTicker extends Ticker {
  // release 的帧时间约每秒批量报告，保留一个批次间隔及调度余量。
  static const _timingWindowMicros = 1500000;
  static const _stableIntervalCount = 6;
  static const _frameToleranceMicros = 500;
  FrameRateTicker(
    super.onTick, {
    int frameRate = 0,
    ValueListenable<List<int>>? videoFrameTimings,
    ValueListenable<bool>? videoDisplaySyncActive,
    double Function()? screenRefreshRate,
  })  : _onFrame = onTick,
        _frameRate = frameRate,
        _videoFrameTimings = videoFrameTimings,
        _videoDisplaySyncActive = videoDisplaySyncActive,
        _screenRefreshRate = screenRefreshRate;

  final TickerCallback _onFrame;
  int _frameRate;
  Timer? _timer;
  int? _callbackId;
  int _frameStartedAt = 0;
  Duration? _origin;
  Duration? _nextFrameTime;
  int? _nativeAnchor;
  int? _nativePeriod;
  int _stableIntervals = 0;
  int? _nativeScreenPeriod;
  int _syncExpires = 0;
  bool _observing = false;
  Duration? _externalFrame;
  int _externalMatches = 0;
  bool _externalPhaseAdopted = false;
  Duration _lastFrame = Duration.zero;
  Duration _lastSystemFrame = Duration.zero;
  ValueListenable<List<int>>? _videoFrameTimings;
  ValueListenable<bool>? _videoDisplaySyncActive;
  final double Function()? _screenRefreshRate;
  /// 无原生到达通知时，使用播放器实际显示同步状态约束 timing 相位学习。
  set videoDisplaySyncActive(ValueListenable<bool>? value) {
    if (identical(value, _videoDisplaySyncActive)) return;
    if (_observing) {
      _videoDisplaySyncActive?.removeListener(_onVideoSyncChanged);
    }
    _videoDisplaySyncActive = value;
    if (_observing) value?.addListener(_onVideoSyncChanged);
    _onVideoSyncChanged();
  }

  void _onVideoSyncChanged() {
    // 纹理实际到达节奏已反映输出相位，不依赖 mpv 采用哪种播放时钟。
    if (_videoFrameTimings != null) return;
    _clearPhase();
  }

  /// 原生纹理刷新请求完成时间，单位为单调时钟微秒，按播放器隔离。
  set videoFrameTimings(ValueListenable<List<int>>? value) {
    if (identical(value, _videoFrameTimings)) return;
    if (_observing) _videoFrameTimings?.removeListener(_onVideoFrames);
    _videoFrameTimings = value;
    _clearPhase();
    if (_observing) value?.addListener(_onVideoFrames);
  }

  void _clearPhase() {
    _nativeAnchor = null;
    _nativePeriod = null;
    _stableIntervals = 0;
    _nativeScreenPeriod = null;
    _syncExpires = 0;
  }

  void _onVideoFrames() {
    final frames = _videoFrameTimings!.value;
    if (frames.isEmpty) {
      _clearPhase();
      return;
    }
    if (!isActive ||
        muted ||
        _frameRate <= 0 ||
        _lastSystemFrame == Duration.zero) {
      return;
    }
    if (_screenRate == null) {
      _clearPhase();
      return;
    }
    final screen = _screenPeriod;
    if (_nativeScreenPeriod != null && _nativeScreenPeriod != screen) {
      _clearPhase();
    }
    // 原生刷新请求下一次 vsync；BeginFrame 再使用该帧的目标时间。
    // 先还原请求对应的 vsync 开始，避免 raster 负载参与相位估算。
    final grid = _lastSystemFrame.inMicroseconds;
    for (final requested in frames) {
      final age = clockMicroseconds - requested;
      if (age < 0 || age > _timingWindowMicros) continue;
      final stamp =
          grid + ((requested - grid) / screen).floor() * screen + screen;
      _acceptNativeFrame(stamp);
    }
  }

  void _acceptNativeFrame(int stamp) {
    final previous = _nativeAnchor;
    if (previous != null && stamp > previous) {
      final period = stamp - previous;
      if (period >= _screenPeriod - 1000 && period <= 100000) {
        // 相邻间隔交替长短时，视频周期无法用单个屏幕槽位间隔预测。
        // 观察六个连续间隔，避免把长短交替节奏中的局部重复当成稳定周期。
        _stableIntervals =
            _nativePeriod != null && (period - _nativePeriod!).abs() <= 1000
                ? (_stableIntervals + 1).clamp(0, _stableIntervalCount)
                : 1;
        _nativePeriod = period;
        _nativeScreenPeriod = _screenPeriod;
        _syncExpires = stamp + _timingWindowMicros;
      } else {
        _nativePeriod = null;
        _stableIntervals = 0;
        _syncExpires = 0;
      }
    }
    if (previous == null || stamp > previous) _nativeAnchor = stamp;
  }

  /// 与引擎帧时间使用相同的单调时钟；测试宿主可替换为其虚拟时钟。
  int get clockMicroseconds => Timeline.now;

  double? get _screenRate {
    final views = SchedulerBinding.instance.platformDispatcher.views;
    final rate = _screenRefreshRate?.call() ??
        (views.isEmpty ? 0.0 : views.first.display.refreshRate);
    return rate.isFinite && rate > 0 ? rate : null;
  }

  int get _screenPeriod => (1000000 / (_screenRate ?? 60)).round();

  int get _frameInterval {
    final requested = (1000000 / _frameRate).floor();
    if (_screenRate == null) return requested;
    final screen = _screenPeriod;
    return requested > screen ? requested : screen;
  }

  void _onTimings(List<FrameTiming> frames) {
    if (!isActive ||
        muted ||
        _videoFrameTimings != null ||
        _frameRate <= 0 ||
        _videoDisplaySyncActive?.value == false) {
      return;
    }
    if (_screenRate == null) {
      _clearPhase();
      return;
    }
    for (final frame in frames) {
      final stamp = frame.timestampInMicroseconds(FramePhase.vsyncStart);
      if (clockMicroseconds - stamp > _timingWindowMicros) continue;
      final knownPeriod = _nativePeriod;
      if (knownPeriod != null &&
          _nativeAnchor != null &&
          (stamp - _nativeAnchor!) % knownPeriod <= 1000) {
        _syncExpires = clockMicroseconds + _timingWindowMicros;
      }
      // 原生纹理复用图层时，引擎将 buildStart/buildFinish 设为同一时间。
      // 普通界面帧不作为视频输出相位样本。
      if (frame.buildDuration != Duration.zero) continue;
      _acceptNativeFrame(stamp);
    }
  }

  void _scheduleWakeup() {
    // 采样只更新相位，已安排的唤醒照常执行；下一次安排时再应用新相位。
    if (_timer != null) return;
    final binding = SchedulerBinding.instance;
    var delay = _nextFrameTime! - _lastFrame;
    final period = _syncPeriod;
    if (period != null) {
      final screen = _screenPeriod;
      final anchor = _nativeAnchor! + screen;
      final desired = _lastSystemFrame.inMicroseconds + delay.inMicroseconds;
      // 就近校准，避免每次批量采样都向后跨过一个目标周期。
      var target = anchor + ((desired - anchor) / period).round() * period;
      final now = clockMicroseconds;
      int screenTarget() =>
          anchor + ((target - anchor - 1000) / screen).ceil() * screen;
      // BeginFrame 使用目标时刻，相位锚点保存对应的 vsync 开始。
      // 选择仍来得及请求的槽位，并提前半个屏幕周期唤醒。
      while (screenTarget() <= _lastSystemFrame.inMicroseconds + 1000 ||
          screenTarget() < now + screen ~/ 2) {
        target += period;
      }
      _nextFrameTime = _lastFrame +
          Duration(microseconds: target - _lastSystemFrame.inMicroseconds);
      delay = Duration(microseconds: screenTarget() - now - screen ~/ 2);
    } else {
      // 弹幕更新占用的时间已属于本周期，避免每帧把这段耗时累加到等待中。
      delay -= Duration(microseconds: clockMicroseconds - _frameStartedAt);
    }
    _timer ??= Timer(delay, () {
      _timer = null;
      if (!muted && isActive && scheduled) binding.scheduleFrame();
    });
  }

  bool get _validPhase =>
      _screenRate != null &&
      clockMicroseconds < _syncExpires &&
      _nativeScreenPeriod == _screenPeriod;

  int? get _syncPeriod {
    final period = _nativePeriod;
    if (_frameRate <= 0 ||
        (_videoFrameTimings == null &&
            _videoDisplaySyncActive?.value == false) ||
        period == null ||
        _stableIntervals < _stableIntervalCount ||
        !_validPhase) {
      return null;
    }
    final interval = _frameInterval;
    if (period <= interval + 1000) {
      // 分频也需要整数比例，避免将量化后的较短视频间隔强行对齐。
      final frames = (interval / period).round();
      return (interval - period * frames).abs() <= 1000 ? period : null;
    }
    // 弹幕为视频帧率的整数倍时，在视频帧之间补齐更新并共用相位。
    // 例如 30 FPS 视频配 60 FPS 弹幕，每个视频周期分成两次更新。
    final subdivisions = (period / interval).round();
    return (period - interval * subdivisions).abs() <= 1000
        ? (period / subdivisions).round()
        : null;
  }

  @override
  TickerFuture start() {
    if (!isActive) {
      _origin = null;
      _nextFrameTime = null;
      // 短空档复用仍有效的相位，屏幕刷新率改变或样本过期后重新学习。
      if ((_videoFrameTimings == null &&
              _videoDisplaySyncActive?.value == false) ||
          _videoFrameTimings?.value.isEmpty == true ||
          clockMicroseconds >= _syncExpires ||
          _nativeScreenPeriod != _screenPeriod) {
        _clearPhase();
      }
      _externalFrame = null;
      _externalMatches = 0;
      _externalPhaseAdopted = false;
    }
    if (!_observing) {
      SchedulerBinding.instance.addTimingsCallback(_onTimings);
      _videoFrameTimings?.addListener(_onVideoFrames);
      _videoDisplaySyncActive?.addListener(_onVideoSyncChanged);
      _observing = true;
    }
    final future = super.start();
    final binding = SchedulerBinding.instance;
    // 与 Ticker 一致，帧内恢复从当前帧计时，保留下一帧的完整时间差。
    if (binding.schedulerPhase.index > SchedulerPhase.idle.index &&
        binding.schedulerPhase.index <
            SchedulerPhase.postFrameCallbacks.index) {
      _origin = binding.currentFrameTimeStamp;
    }
    return future;
  }

  set frameRate(int value) {
    if (value == _frameRate) return;
    final wasMuted = muted;
    muted = true;
    _frameRate = value;
    _externalFrame = null;
    _externalMatches = 0;
    _externalPhaseAdopted = false;
    muted = wasMuted;
  }

  @override
  bool get scheduled => _callbackId != null;

  @override
  void scheduleTick({bool rescheduling = false}) {
    assert(shouldScheduleTick);
    final binding = SchedulerBinding.instance;
    if (!rescheduling) {
      _nextFrameTime = null;
      if (_syncPeriod != null) {
        _nextFrameTime = _lastFrame;
      }
    }
    // 先注册回调，视频或其它动画的帧可直接承载弹幕，避免定时器晚于
    // 视频 vsync 时错过该帧并额外唤醒高刷屏。
    _callbackId = binding.scheduleFrameCallback(
      _tickFrame,
      rescheduling: rescheduling,
      scheduleNewFrame: false,
    );
    if (_frameRate <= 0 ||
        _nextFrameTime == null ||
        (_screenRate != null && _frameRate >= _screenRate!)) {
      // 已达到屏幕上限时直接请求下一次 vsync，省去同频定时器唤醒。
      _timer?.cancel();
      _timer = null;
      binding.scheduleFrame();
    } else {
      _scheduleWakeup();
    }
  }

  void _tickFrame(Duration timestamp) {
    _frameStartedAt = clockMicroseconds;
    _lastFrame = timestamp;
    _lastSystemFrame = SchedulerBinding.instance.currentSystemFrameTimeStamp;
    _callbackId = null;
    var next = _nextFrameTime;
    if (_timer != null && _frameRate > 0) {
      final previous = _externalFrame;
      _externalFrame = timestamp;
      final interval = _frameInterval;
      if (previous == null ||
          (timestamp - previous).inMicroseconds > interval * 2 + 1000) {
        _externalPhaseAdopted = false;
      }
      // 高频 UI 动画也可能偶尔留下同频采样；连续确认后才调整相位。
      _externalMatches = previous != null &&
              ((timestamp - previous).inMicroseconds - interval).abs() <= 1000
          ? (_externalMatches + 1).clamp(0, 2)
          : 0;
      if (!_externalPhaseAdopted &&
          _externalMatches >= 2 &&
          next != null &&
          timestamp < next) {
        next = null;
        _nextFrameTime = null;
        // 连续外部帧只校准一次，避免高频 UI 动画反复提前弹幕更新。
        _externalPhaseAdopted = true;
      }
    }
    // 刷新周期取整可能使目标晚于真实 vsync 数微秒；按累计目标限频并容忍该误差。
    if (_frameRate <= 0 ||
        next == null ||
        timestamp.inMicroseconds + _frameToleranceMicros >=
            next.inMicroseconds) {
      _timer?.cancel();
      _timer = null;
      _origin ??= timestamp;
      if (_frameRate > 0) {
        final interval = Duration(microseconds: _frameInterval);
        // 按目标时间累积余量，使 90 FPS 在 120 Hz 上均匀分配帧。
        var target = (next ?? timestamp) + interval;
        if (target <= timestamp) target = timestamp + interval;
        _nextFrameTime = target;
      }
      _onFrame(timestamp - _origin!);
    }
    if (shouldScheduleTick) scheduleTick(rescheduling: true);
  }

  @override
  void unscheduleTick() {
    _timer?.cancel();
    _timer = null;
    if (_callbackId case final id?) {
      SchedulerBinding.instance.cancelFrameCallbackWithId(id);
      _callbackId = null;
    }
  }

  @override
  void stop({bool canceled = false}) {
    super.stop(canceled: canceled);
    if (_observing) {
      SchedulerBinding.instance.removeTimingsCallback(_onTimings);
      _videoFrameTimings?.removeListener(_onVideoFrames);
      _videoDisplaySyncActive?.removeListener(_onVideoSyncChanged);
      _observing = false;
    }
  }

  @override
  void dispose() {
    if (_observing) {
      SchedulerBinding.instance.removeTimingsCallback(_onTimings);
      _videoFrameTimings?.removeListener(_onVideoFrames);
      _videoDisplaySyncActive?.removeListener(_onVideoSyncChanged);
      _observing = false;
    }
    super.dispose();
  }
}
