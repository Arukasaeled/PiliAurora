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
  static const _refreshRateTolerance = 0.5;
  FrameRateTicker(
    super.onTick, {
    int frameRate = 0,
    ValueListenable<List<int>>? videoFrameTimings,
    ValueListenable<bool>? videoDisplaySyncActive,
    double Function()? screenRefreshRate,
    int? wakeLeadMicros,
    void Function()? beforeFrame,
    void Function()? beforeTimings,
    // 共用视频输出 Surface 时稳定提交节奏，位置更新仍按 frameRate 推进。
    bool continuousVideoVsync = false,
    // 按内容合成时，视频与弹幕仍需共用更新相位。
    bool preserveVideoPhase = false,
  })  : _onFrame = onTick,
        _frameRate = frameRate,
        _videoFrameTimings = videoFrameTimings,
        _videoDisplaySyncActive = videoDisplaySyncActive,
        _screenRefreshRate = screenRefreshRate,
        _wakeLeadMicros = wakeLeadMicros,
        _beforeFrame = beforeFrame,
        _beforeTimings = beforeTimings,
        _continuousVideoVsync = continuousVideoVsync,
        _preserveVideoPhase = preserveVideoPhase;

  final TickerCallback _onFrame;
  int _frameRate;
  Timer? _timer;
  int? _callbackId;
  int _frameStartedAt = 0;
  Duration? _origin;
  // 接受本次更新时才提交下一截止；唤醒重排不改变尚未完成的更新。
  Duration? _nextFrameTime;
  int? _nativeAnchor;
  int? _nativePeriod;
  int _stableIntervals = 0;
  int? _nativeScreenPeriod;
  int _syncExpires = 0;
  bool _observing = false;
  int _slot = 0;
  int? _slotPeriod;
  int? _previousSlotFrameUs;
  double? _nextUpdateSlot;
  int? _scheduledUpdateSlot;
  double? _cadencePhase;
  double? _cadencePhasePeriod;
  Duration _lastFrame = Duration.zero;
  Duration _lastSystemFrame = Duration.zero;
  ValueListenable<List<int>>? _videoFrameTimings;
  ValueListenable<bool>? _videoDisplaySyncActive;
  final double Function()? _screenRefreshRate;
  final int? _wakeLeadMicros;
  bool _continuousVideoVsync;
  bool _preserveVideoPhase;
  String? _videoPhaseFallback;
  int _invalidPresentationTimings = 0;
  int? _lastPresentationTimingUs;
  bool get _useVideoPhase => _preserveVideoPhase && _videoPhaseFallback == null;
  final void Function()? _beforeFrame;
  final void Function()? _beforeTimings;
  final _frameTargets = <int, int>{};
  int _frameTargetEpoch = 0;
  int? _presentationLeadUs;
  int _updates = 0;
  int _frameRequests = 0;
  int _timerWakeups = 0;
  int _frameCallbacks = 0;
  int _deadlineSkips = 0;
  int? _previousUpdateFrameUs;
  int _maxUpdateGapUs = 0;
  int _longUpdateGaps = 0;
  // 各桶互斥，边界单位为微秒；快照差分可查看短窗口的间隔分布。
  static const _gapBoundsUs = [10000, 20000, 30000, 40000, 60000, 100000];
  final _updateGapBuckets = List<int>.filled(_gapBoundsUs.length + 1, 0);
  int? _lastUpdate;
  int? _lastFrameRequest;

  /// 累计调度计数，由现有诊断采样器读取；请求数包含被引擎合并的请求。
  Map<String, Object?> get diagnostics => {
        'targetFrameRate': _frameRate,
        'displayRefreshRate': _screenRate,
        'active': isActive,
        'muted': muted,
        'mode': !isActive
            ? 'stopped'
            : muted
                ? 'muted'
                : _followVsync
                    ? 'vsync'
                    : _syncPeriod != null
                        ? 'locked'
                        : 'independent',
        'nativePeriodUs': _nativePeriod,
        'preserveVideoPhase': _useVideoPhase,
        'videoPhaseFallback': _videoPhaseFallback,
        if (_preserveVideoPhase) 'presentationLeadUs': _presentationLeadUs,
        'syncPeriodUs': _syncPeriod,
        'stableIntervals': _stableIntervals,
        'updates': _updates,
        'frameRequests': _frameRequests,
        'timerWakeups': _timerWakeups,
        'frameCallbacks': _frameCallbacks,
        'deadlineSkips': _deadlineSkips,
        'requestEveryVsync': isActive && !muted && _requestEveryVsync,
        'maxUpdateGapUs': _maxUpdateGapUs,
        'longUpdateGaps': _longUpdateGaps,
        'updateGapBuckets': {
          for (var i = 0; i < _gapBoundsUs.length; i++)
            'le${_gapBoundsUs[i]}': _updateGapBuckets[i],
          'gt${_gapBoundsUs.last}': _updateGapBuckets.last,
        },
        'lastUpdateMonotonicUs': _lastUpdate,
        'lastFrameRequestMonotonicUs': _lastFrameRequest,
      };

  void _requestFrame() {
    _frameRequests++;
    _lastFrameRequest = clockMicroseconds;
    SchedulerBinding.instance.scheduleFrame();
  }

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

  /// 输出或视图失效时一并撤销帧匹配和旧槽位；新样本不改变已有截止。
  void invalidatePhase() {
    _clearPhase();
    _frameTargetEpoch++;
    _frameTargets.clear();
    _presentationLeadUs = null;
    _invalidPresentationTimings = 0;
    _lastPresentationTimingUs = null;
    _previousUpdateFrameUs = null;
    _nextFrameTime = null;
    _resetSlots();
    _timer?.cancel();
    _timer = null;
    if (isActive && !muted && scheduled) {
      unscheduleTick();
      scheduleTick();
    }
  }

  void configureVideoPhase(
      {required bool continuousVideoVsync, required bool preserveVideoPhase}) {
    if (_continuousVideoVsync == continuousVideoVsync &&
        _preserveVideoPhase == preserveVideoPhase) return;
    _continuousVideoVsync = continuousVideoVsync;
    _preserveVideoPhase = preserveVideoPhase;
    invalidatePhase();
  }

  void _clearPhase() {
    _nativeAnchor = null;
    _nativePeriod = null;
    _stableIntervals = 0;
    _nativeScreenPeriod = null;
    _syncExpires = 0;
    _cadencePhase = null;
    _cadencePhasePeriod = null;
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
    final grid = _lastSystemFrame.inMicroseconds - _presentationLead;
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

  int get _presentationLead =>
      _useVideoPhase ? _presentationLeadUs ?? _screenPeriod : _screenPeriod;

  double? get _screenRate {
    final views = SchedulerBinding.instance.platformDispatcher.views;
    final rate = _screenRefreshRate?.call() ??
        (views.isEmpty ? 0.0 : views.first.display.refreshRate);
    return rate.isFinite && rate > 0 ? rate : null;
  }

  int get _screenPeriod => (1000000 / (_screenRate ?? 60)).round();

  // Android 可能把 120 Hz 报成 120.000007 Hz；标称同频时直接复用 vsync。
  bool get _followVsync =>
      _frameRate <= 0 ||
      (_screenRate != null &&
          _frameRate >= _screenRate! - _refreshRateTolerance);

  bool get _requestEveryVsync {
    if (_followVsync) return true;
    if (!_continuousVideoVsync || _screenRate == null) return false;
    final frames = _videoFrameTimings?.value;
    if (frames == null || frames.isEmpty) return false;
    final age = clockMicroseconds - frames.last;
    return age >= 0 && age < _timingWindowMicros;
  }

  int? get _screenDivisor {
    final rate = _screenRate;
    if (rate == null || _frameRate <= 0) return null;
    final divisor = (rate / _frameRate).round();
    return divisor >= 1 &&
            (rate - _frameRate * divisor).abs() <= _refreshRateTolerance
        ? divisor
        : null;
  }

  int get _frameInterval {
    if (_followVsync && _screenRate != null) return _screenPeriod;
    final divisor = _screenDivisor;
    if (divisor != null) return divisor * _screenPeriod;
    final requested = (1000000 / _frameRate).floor();
    if (_screenRate == null) return requested;
    final screen = _screenPeriod;
    return requested > screen ? requested : screen;
  }

  void _onTimings(List<FrameTiming> frames) {
    _beforeTimings?.call();
    if (_useVideoPhase) {
      for (final frame in frames) {
        final target = _frameTargets.remove(frame.frameNumber);
        if (target == null) continue;
        final lead =
            target - frame.timestampInMicroseconds(FramePhase.vsyncStart);
        _lastPresentationTimingUs = clockMicroseconds;
        // 帧计划至少预留两屏预算；一屏提前量表示引擎已退回旧回调。
        // 连续证据触发后保持兼容节奏，暂停、重配不重新试探故障路径。
        final legacy = lead > 0 && lead <= _screenPeriod * 3 ~/ 2;
        if (legacy || lead <= 0 || lead > _screenPeriod * 8) {
          if (++_invalidPresentationTimings >= 3) {
            _fallbackVideoPhase(legacy ? 'legacyVsync' : 'invalidFrameTiming');
            break;
          }
        } else {
          _invalidPresentationTimings = 0;
          _presentationLeadUs = lead;
        }
      }
    }
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

  void _fallbackVideoPhase(String reason) {
    _videoPhaseFallback = reason;
    invalidatePhase();
  }

  void _resetSlots() {
    _slot = 0;
    _slotPeriod = null;
    _previousSlotFrameUs = null;
    _nextUpdateSlot = null;
    _scheduledUpdateSlot = null;
    _cadencePhase = null;
    _cadencePhasePeriod = null;
  }

  void _trackSlots() {
    final period = _screenRate == null ? null : _screenPeriod;
    if (period != _slotPeriod) {
      _resetSlots();
      _slotPeriod = period;
      _nextFrameTime = null;
    }
    if (period == null) return;
    final frame = _lastSystemFrame.inMicroseconds;
    final previous = _previousSlotFrameUs;
    if (previous != null && frame > previous) {
      // 用相邻 vsync 的距离数槽位，微小周期漂移不会积累到下一次截止。
      _slot += ((frame - previous) / period).round();
    }
    _previousSlotFrameUs = frame;
  }

  void _planNextUpdate(Duration timestamp) {
    final screen = _slotPeriod;
    if (screen == null) {
      if (_frameRate <= 0) return;
      final interval = Duration(microseconds: _frameInterval);
      final next = (_nextFrameTime ?? timestamp) + interval;
      _nextFrameTime = next <= timestamp ? timestamp + interval : next;
      return;
    }
    final interval = _followVsync
        ? 1.0
        : _screenDivisor?.toDouble() ?? _screenRate! / _frameRate;
    final period = _followVsync ? null : _syncPeriod;
    final anchor = period == null
        ? null
        : _slot +
            (_nativeAnchor! +
                    _presentationLead -
                    _lastSystemFrame.inMicroseconds) /
                screen;
    final phasePeriod = period == null ? null : period / screen;
    if (anchor != null && phasePeriod != null) {
      final previous = _cadencePhase;
      final offset = previous == null
          ? 0.0
          : anchor -
              previous -
              ((anchor - previous) / phasePeriod).round() * phasePeriod;
      if (previous == null ||
          (phasePeriod - _cadencePhasePeriod!).abs() > 0.1 ||
          offset.abs() > 0.5) {
        // 视频跨到另一屏幕相位时重新建立一次预算；批次内的小幅波动沿用原预算。
        _nextUpdateSlot = null;
        _cadencePhase = anchor;
        _cadencePhasePeriod = phasePeriod;
      }
    }
    var next = (_nextUpdateSlot ?? _slot.toDouble()) + interval;
    if (next <= _slot) next = _slot + interval;
    _nextUpdateSlot = next;
    final latest = _slot + interval.ceil();
    var scheduled = next.round().clamp(_slot + 1, latest);
    if (anchor != null && phasePeriod != null) {
      var aligned =
          (anchor + ((next - anchor) / phasePeriod).round() * phasePeriod)
              .round();
      if (aligned > latest) aligned = (aligned - phasePeriod).round();
      // 相位偏差保持在一个更新周期内；累计余量与最长槽距共同约束校准。
      if (aligned > _slot &&
          aligned <= latest &&
          (aligned - next).abs() < interval) {
        scheduled = aligned;
      }
    }
    _scheduledUpdateSlot = scheduled;
    _nextFrameTime =
        timestamp + Duration(microseconds: (scheduled - _slot) * screen);
  }

  void _scheduleWakeup() {
    if (_timer != null) return;
    var delay = _nextFrameTime! - _lastFrame;
    final screen = _slotPeriod;
    if (screen != null) {
      // 已提交的更新槽位同时承载唤醒，重排不再改变更新截止。
      final wakeLead = (_wakeLeadMicros ?? screen ~/ 2).clamp(
        0,
        screen * 2,
      );
      delay = Duration(
        microseconds: (_scheduledUpdateSlot! - _slot) * screen - wakeLead,
      );
      final lead = _lastSystemFrame.inMicroseconds - _frameStartedAt;
      // BeginFrame 是目标呈现时间；交付超过目标后仍需扣除已耗时，
      // 否则一次迟到会把仍可请求的下一更新额外推迟一屏。
      if (lead <= screen) {
        delay -= Duration(microseconds: screen - lead);
      }
    }
    delay -= Duration(microseconds: clockMicroseconds - _frameStartedAt);
    _timer ??= Timer(delay, () {
      _timer = null;
      _timerWakeups++;
      if (!muted && isActive && scheduled) _requestFrame();
    });
  }

  bool get _validPhase =>
      _screenRate != null &&
      clockMicroseconds < _syncExpires &&
      _nativeScreenPeriod == _screenPeriod;

  int? get _syncPeriod {
    // 持续合成时各屏幕槽位均已承载视频，位移预算保持自身节奏，
    // 无需再为视频合帧移动更新相位。
    if (_continuousVideoVsync && !_useVideoPhase && _requestEveryVsync)
      return null;
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
      _previousUpdateFrameUs = null;
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
      _resetSlots();
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
    _previousUpdateFrameUs = null;
    final wasMuted = muted;
    muted = true;
    _frameRate = value;
    _resetSlots();
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
    if (_followVsync || _nextFrameTime == null) {
      // 已达到屏幕上限时直接请求下一次 vsync，省去同频定时器唤醒。
      _timer?.cancel();
      _timer = null;
      _requestFrame();
    } else {
      _scheduleWakeup();
    }
    if (_continuousVideoVsync && !_followVsync && _requestEveryVsync) {
      final callback = _callbackId;
      // 保留更新截止的唤醒；当前 Scene 交付后再补充连续屏幕请求，
      // 避免请求下一屏与本帧提交交错。停止或重启后撤销旧帧的补充请求。
      binding.addPostFrameCallback((_) {
        if (isActive && !muted && _callbackId == callback) _requestFrame();
      });
    }
  }

  void _tickFrame(Duration timestamp) {
    _callbackId = null;
    _beforeFrame?.call();
    _frameCallbacks++;
    _frameStartedAt = clockMicroseconds;
    _lastFrame = timestamp;
    _lastSystemFrame = SchedulerBinding.instance.currentSystemFrameTimeStamp;
    if (_useVideoPhase) {
      _lastPresentationTimingUs ??= clockMicroseconds;
      if (clockMicroseconds - _lastPresentationTimingUs! >
          _timingWindowMicros * 2) {
        _fallbackVideoPhase('missingFrameTiming');
      }
    }
    if (_useVideoPhase) {
      final target = _lastSystemFrame.inMicroseconds;
      final epoch = _frameTargetEpoch;
      // 固定 SDK 在 BeginFrame 返回后发布本帧编号，帧末再关联目标。
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (!isActive || muted || epoch != _frameTargetEpoch) return;
        final frame = SchedulerBinding.instance.platformDispatcher.frameData;
        _frameTargets[frame.frameNumber] = target;
        if (_frameTargets.length > 256) {
          _frameTargets.remove(_frameTargets.keys.first);
        }
      });
    }
    _trackSlots();
    final next = _nextFrameTime;
    final due = _slotPeriod != null
        ? _scheduledUpdateSlot == null || _slot >= _scheduledUpdateSlot!
        : next == null ||
            timestamp.inMicroseconds + _frameToleranceMicros >=
                next.inMicroseconds;
    if (_followVsync || due) {
      _timer?.cancel();
      _timer = null;
      _origin ??= timestamp;
      _planNextUpdate(timestamp);
      _updates++;
      _lastUpdate = clockMicroseconds;
      _recordUpdateGap();
      _onFrame(timestamp - _origin!);
    } else {
      _deadlineSkips++;
    }
    if (shouldScheduleTick) scheduleTick(rescheduling: true);
  }

  void _recordUpdateGap() {
    final stamp = _lastSystemFrame.inMicroseconds;
    final previous = _previousUpdateFrameUs;
    _previousUpdateFrameUs = stamp;
    if (previous == null || stamp <= previous) return;
    final gap = stamp - previous;
    if (gap > _maxUpdateGapUs) _maxUpdateGapUs = gap;
    var bucket = 0;
    while (bucket < _gapBoundsUs.length && gap > _gapBoundsUs[bucket]) {
      bucket++;
    }
    _updateGapBuckets[bucket]++;
    final screen = _screenPeriod;
    // 非整除档位允许正常槽位量化，例如120Hz上的90FPS交替占1/2槽。
    final expected = _followVsync
        ? screen
        : _screenRate == null
            ? _frameInterval
            : ((_frameInterval - _frameToleranceMicros) / screen).ceil() *
                screen;
    if (gap > expected + _frameToleranceMicros) _longUpdateGaps++;
  }

  @override
  void unscheduleTick() {
    // 暂停、静音和切档的空档不计入连续播放间隔。
    _previousUpdateFrameUs = null;
    _frameTargetEpoch++;
    _frameTargets.clear();
    _presentationLeadUs = null;
    _invalidPresentationTimings = 0;
    _lastPresentationTimingUs = null;
    _resetSlots();
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
