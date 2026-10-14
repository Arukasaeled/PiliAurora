import 'dart:async';
import 'dart:developer';
import 'dart:ui' show FramePhase;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// 复用已有 vsync 并按目标间隔更新；没有其它帧来源时定时请求刷新。
class FrameRateTicker extends Ticker {
  // release 的帧时间约每秒批量报告，保留一个批次间隔及调度余量。
  static const _timingWindowMicros = 1500000;
  FrameRateTicker(
    super.onTick, {
    int frameRate = 0,
    ValueListenable<List<int>>? videoFrameTimings,
  })  : _onFrame = onTick,
        _frameRate = frameRate,
        _videoFrameTimings = videoFrameTimings;

  final TickerCallback _onFrame;
  int _frameRate;
  Timer? _timer;
  int? _callbackId;
  Duration? _origin;
  Duration? _nextFrameTime;
  int? _nativeAnchor;
  int? _nativePeriod;
  int? _nativeScreenPeriod;
  int _syncExpires = 0;
  bool _observing = false;
  Duration? _externalFrame;
  Duration _lastFrame = Duration.zero;
  Duration _lastSystemFrame = Duration.zero;
  ValueListenable<List<int>>? _videoFrameTimings;

  /// 原生纹理消费时间，单位为单调时钟微秒，按播放器隔离。
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
    final screen = _screenPeriod;
    if (_nativeScreenPeriod != null && _nativeScreenPeriod != screen) {
      _clearPhase();
    }
    // 消费发生在 raster 线程，晚于 vsync 开始。使用当前 Flutter vsync
    // 网格还原帧槽，避免将消费回调的耗时抖动当成视频周期。
    final grid = _lastSystemFrame.inMicroseconds;
    for (final consumed in frames) {
      final age = clockMicroseconds - consumed;
      if (age < 0 || age > _timingWindowMicros) continue;
      final stamp = grid + ((consumed - grid) / screen).floor() * screen;
      _acceptNativeFrame(stamp);
    }
    _rescheduleWakeup();
  }

  void _acceptNativeFrame(int stamp) {
    final previous = _nativeAnchor;
    if (previous != null && stamp > previous) {
      final period = stamp - previous;
      if (period >= _screenPeriod - 1000 && period <= 100000) {
        _nativePeriod = period;
        _nativeScreenPeriod = _screenPeriod;
        _syncExpires = stamp + _timingWindowMicros;
      }
    }
    if (previous == null || stamp > previous) _nativeAnchor = stamp;
  }

  /// 与引擎帧时间使用相同的单调时钟；测试宿主可替换为其虚拟时钟。
  int get clockMicroseconds => Timeline.now;

  int get _screenPeriod {
    final views = SchedulerBinding.instance.platformDispatcher.views;
    final rate = views.isEmpty ? 60.0 : views.first.display.refreshRate;
    return (1000000 / (rate.isFinite && rate > 0 ? rate : 60)).round();
  }

  void _onTimings(List<FrameTiming> frames) {
    if (!isActive || muted || _frameRate <= 0) return;
    for (final frame in frames) {
      final stamp = frame.timestampInMicroseconds(FramePhase.vsyncStart);
      if (clockMicroseconds - stamp > _timingWindowMicros) continue;
      final knownPeriod = _nativePeriod;
      if (_videoFrameTimings == null &&
          knownPeriod != null &&
          _nativeAnchor != null &&
          (stamp - _nativeAnchor!) % knownPeriod <= 1000) {
        _syncExpires = clockMicroseconds + _timingWindowMicros;
      }
      // 原生纹理复用图层时，引擎将 buildStart/buildFinish 设为同一时间。
      // 普通界面帧不作为视频输出相位样本。
      if (frame.buildDuration != Duration.zero) continue;
      if (_videoFrameTimings == null) _acceptNativeFrame(stamp);
    }
    _rescheduleWakeup();
  }

  void _rescheduleWakeup() {
    if (scheduled &&
        _nextFrameTime != null &&
        _nativePeriod != null &&
        _nativePeriod! <= (1000000 / _frameRate).ceil() + 1000 &&
        _validPhase &&
        !SchedulerBinding.instance.hasScheduledFrame) {
      _timer?.cancel();
      _timer = null;
      _scheduleWakeup();
    }
  }

  void _scheduleWakeup() {
    final binding = SchedulerBinding.instance;
    var delay = _nextFrameTime! - _lastFrame;
    final period = _nativePeriod;
    if (period != null &&
        _validPhase &&
        period <= (1000000 / _frameRate).ceil() + 1000) {
      // BeginFrame 使用 vsync target 时间；原生 timing 提供 vsync start。
      // 提前半个屏幕周期唤醒，将 Dart 更新合入目标 vsync。
      final anchor = _nativeAnchor! + _screenPeriod;
      // 容纳帧时间取整与轻微抖动，避免相邻目标差几微秒却跳过整张视频帧。
      final desired =
          _lastSystemFrame.inMicroseconds + delay.inMicroseconds - 1000;
      final now = clockMicroseconds;
      final earliest = desired > now + _screenPeriod ~/ 2
          ? desired
          : now + _screenPeriod ~/ 2;
      final steps = ((earliest - anchor) / period).ceil();
      final target = anchor + steps * period;
      _nextFrameTime = _lastFrame +
          Duration(
            microseconds: target - _lastSystemFrame.inMicroseconds,
          );
      delay = Duration(microseconds: target - now - _screenPeriod ~/ 2);
    }
    _timer ??= Timer(delay, () {
      _timer = null;
      if (!muted && isActive && scheduled) binding.scheduleFrame();
    });
  }

  bool get _validPhase =>
      clockMicroseconds < _syncExpires && _nativeScreenPeriod == _screenPeriod;

  @override
  TickerFuture start() {
    if (!isActive) {
      _origin = null;
      _nextFrameTime = null;
      // 短空档复用仍有效的相位，屏幕刷新率改变或样本过期后重新学习。
      if (_videoFrameTimings?.value.isEmpty == true ||
          clockMicroseconds >= _syncExpires ||
          _nativeScreenPeriod != _screenPeriod) {
        _nativeAnchor = null;
        _nativePeriod = null;
      }
      _externalFrame = null;
    }
    if (!_observing) {
      SchedulerBinding.instance.addTimingsCallback(_onTimings);
      _videoFrameTimings?.addListener(_onVideoFrames);
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
      if (_frameRate > 0 &&
          _nativePeriod != null &&
          _nativePeriod! <= (1000000 / _frameRate).ceil() + 1000 &&
          _validPhase) {
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
    if (_frameRate <= 0 || _nextFrameTime == null) {
      binding.scheduleFrame();
    } else {
      _scheduleWakeup();
    }
  }

  void _tickFrame(Duration timestamp) {
    _lastFrame = timestamp;
    _lastSystemFrame = SchedulerBinding.instance.currentSystemFrameTimeStamp;
    _callbackId = null;
    var next = _nextFrameTime;
    if (_timer != null && _frameRate > 0) {
      final previous = _externalFrame;
      _externalFrame = timestamp;
      final interval = (1000000 / _frameRate).floor();
      if (previous != null &&
          next != null &&
          timestamp < next &&
          ((timestamp - previous).inMicroseconds - interval).abs() <= 1000) {
        // 等待期间到达的同频外部 Dart 帧可成为新相位，避免继续夹帧。
        next = null;
        _nextFrameTime = null;
      }
    }
    if (_frameRate <= 0 || next == null || timestamp >= next) {
      _timer?.cancel();
      _timer = null;
      _origin ??= timestamp;
      if (_frameRate > 0) {
        final interval = Duration(microseconds: (1000000 / _frameRate).floor());
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
      _observing = false;
    }
  }

  @override
  void dispose() {
    if (_observing) {
      SchedulerBinding.instance.removeTimingsCallback(_onTimings);
      _videoFrameTimings?.removeListener(_onVideoFrames);
      _observing = false;
    }
    super.dispose();
  }
}
