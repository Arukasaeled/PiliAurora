import 'dart:async';

import 'package:flutter/scheduler.dart';

/// 限制主动请求帧的频率，仍使用 vsync 时间戳推进动画。
class FrameRateTicker extends Ticker {
  FrameRateTicker(super.onTick, {int frameRate = 0}) : _frameRate = frameRate;

  int _frameRate;
  Timer? _timer;
  Duration? _nextFrameTime;

  set frameRate(int value) {
    if (value == _frameRate) return;
    final wasMuted = muted;
    muted = true;
    _frameRate = value;
    muted = wasMuted;
  }

  @override
  bool get scheduled => _timer != null || super.scheduled;

  @override
  void scheduleTick({bool rescheduling = false}) {
    if (_frameRate <= 0 || !rescheduling) {
      _nextFrameTime = null;
      super.scheduleTick(rescheduling: rescheduling);
      return;
    }
    // 等到下一档位周期再请求 vsync，避免在高刷屏上持续唤醒每一帧。
    final now = SchedulerBinding.instance.currentFrameTimeStamp;
    final interval = Duration(microseconds: (1000000 / _frameRate).floor());
    var next = (_nextFrameTime ?? now) + interval;
    if (next <= now) next = now + interval;
    _nextFrameTime = next;
    // 保留目标时间的余量，使 90 FPS 在 120 Hz 屏幕上也能均匀分配帧。
    _timer = Timer(
      next - now,
      () {
        _timer = null;
        if (shouldScheduleTick) super.scheduleTick();
      },
    );
  }

  @override
  void unscheduleTick() {
    _timer?.cancel();
    _timer = null;
    super.unscheduleTick();
  }
}
