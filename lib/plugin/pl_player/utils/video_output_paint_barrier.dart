import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// Confirms rasterization of a scene containing the protective snapshot.
/// endOfFrame only acknowledges UI submission. An older queued scene cannot
/// authorize resize, even when it rasterizes after that UI submission.
class VideoOutputPaintBarrier {
  VideoOutputPaintBarrier({
    SchedulerBinding? binding,
    @visibleForTesting int Function()? frameNumber,
  }) : _binding = binding ?? SchedulerBinding.instance {
    _frameNumber =
        frameNumber ?? () => _binding.platformDispatcher.frameData.frameNumber;
  }

  final SchedulerBinding _binding;
  late final int Function() _frameNumber;
  final _waits = <Completer<bool>, ({TimingsCallback callback, Timer timer})>{};
  bool _disposed = false;

  Future<bool> wait() {
    if (_disposed) return Future.value(false);
    final result = Completer<bool>();
    int? protectedFrame;
    void onTimings(List<ui.FrameTiming> timings) {
      final frame = protectedFrame;
      if (frame != null && timings.any((t) => t.frameNumber >= frame)) {
        _finish(result, true);
      }
    }

    _waits[result] = (
      callback: onTimings,
      // release 帧统计可能批量延迟一秒；回执长期缺失时取消尚未提交的 resize，
      // 让截图遮罩退出并继续显示原生纹理。
      timer: Timer(const Duration(seconds: 3), () => _finish(result, false)),
    );
    _binding.addTimingsCallback(onTimings);
    _binding.addPostFrameCallback((_) {
      if (!_waits.containsKey(result)) return;
      final frame = _frameNumber();
      if (frame < 0) {
        // No reliable frame identity: retain existing native output.
        _finish(result, false);
      } else {
        protectedFrame = frame;
      }
    }, debugLabel: 'VideoOutputPaintBarrier.protectedFrame');
    _binding.ensureVisualUpdate();
    return result.future;
  }

  void _finish(Completer<bool> result, bool painted) {
    final wait = _waits.remove(result);
    if (wait == null) return;
    wait.timer.cancel();
    _binding.removeTimingsCallback(wait.callback);
    result.complete(painted);
  }

  /// Source invalidation must release waits even if no further frame is drawn.
  void cancel() {
    for (final wait in _waits.keys.toList()) {
      _finish(wait, false);
    }
  }

  void dispose() {
    _disposed = true;
    cancel();
  }
}
