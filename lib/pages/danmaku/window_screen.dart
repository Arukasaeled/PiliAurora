import 'dart:async';
import 'dart:developer' show Timeline;
import 'dart:math' as math;
import 'dart:ui' show FlutterView;

import 'package:canvas_danmaku/frame_rate_ticker.dart';
import 'package:flutter/foundation.dart'
    show ValueListenable, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/scheduler.dart' show SchedulerBinding;
import 'package:flutter/widgets.dart';
import 'package:pili_aurora/pages/danmaku/window_renderer.dart';
import 'package:pili_aurora/services/diagnostics/diagnostics.dart';
import 'package:pili_aurora/plugin/pl_player/playback/media_clock.dart';

typedef DanmakuPrepareFrame<T> = void Function(
  DanmakuWindowRenderer<T>,
  int mediaUs, {
  required double effectiveRate,
});

/// 挂载方持有 renderer；此控件管理媒体订阅、帧调度与绘制挂载。
class DanmakuWindowScreen<T> extends StatefulWidget {
  const DanmakuWindowScreen({
    super.key,
    required this.renderer,
    required this.clock,
    required this.size,
    required this.prepareFrame,
    this.needsPreparation,
    this.nextPreparationUs,
    this.inputChanges,
    this.opacity = 1,
    this.frameRate = 0,
    this.videoFrameTimings,
    this.videoDisplaySyncActive,
    this.monotonicUs,
    this.frameTimeUs,
  });

  final DanmakuWindowRenderer<T> renderer;
  final PlaybackMediaClock clock;
  final Size size;
  final DanmakuPrepareFrame<T> prepareFrame;
  final bool Function()? needsPreparation;
  final int? Function()? nextPreparationUs;
  final Stream<Object?>? inputChanges;
  final double opacity;
  final int frameRate;
  final ValueListenable<List<int>>? videoFrameTimings;
  final ValueListenable<bool>? videoDisplaySyncActive;
  final int Function()? monotonicUs;

  /// 与单调时钟同域的帧目标时间；测试可分别控制目标与实际交付。
  final int Function()? frameTimeUs;

  @override
  State<DanmakuWindowScreen<T>> createState() => _DanmakuWindowScreenState<T>();
}

class _DanmakuWindowScreenState<T> extends State<DanmakuWindowScreen<T>> {
  late final FrameRateTicker _ticker;
  StreamSubscription<PlaybackMediaAnchor?>? _anchors;
  StreamSubscription<Object?>? _inputs;
  PlaybackMediaAnchor? _anchor;
  int? _continuity;
  int _lastPositionUs = 0;
  int? _lastFrameTimeUs;
  bool _enabled = false;
  FlutterView? _view;
  Timer? _wake;
  late final VoidCallback _unregisterDiagnostics;

  @override
  void initState() {
    super.initState();
    // 按当前帧的目标时间外推位置，避免回调交付抖动改变相邻帧位移。
    _ticker = FrameRateTicker(
      (_) => _update(
        frameTimeUs:
            widget.frameTimeUs?.call() ??
            SchedulerBinding
                .instance
                .currentSystemFrameTimeStamp
                .inMicroseconds,
      ),
      frameRate: widget.frameRate,
      videoFrameTimings: widget.videoFrameTimings,
      videoDisplaySyncActive: widget.videoDisplaySyncActive,
      screenRefreshRate: () => _view?.display.refreshRate ?? 0,
      continuousVideoVsync: defaultTargetPlatform == TargetPlatform.android,
      preserveVideoPhase: const bool.fromEnvironment(
        'PILIAURORA_CONTENT_COMPOSITION',
      ),
    );
    _unregisterDiagnostics = Diagnostics.instance.register(
      'danmaku.layer.$hashCode',
      () => {
        ...widget.renderer.statistics,
        'input': 'timeline',
        'visible': _visible,
        'opacity': widget.opacity,
        'tickerEnabled': _enabled,
        'presentationTimeUs': widget.renderer.presentationTimeUs,
        'sampledAtUs': widget.monotonicUs?.call() ?? Timeline.now,
        'mediaAnchor': {
          'positionUs': _anchor?.positionUs,
          'observedAtUs': _anchor?.observedAtUs,
          'effectiveRate': _anchor?.effectiveRate,
          'advancing': _anchor?.advancing,
          'ready': _anchor?.ready,
          'continuity': _anchor?.continuity,
          'validForUs': _anchor?.validForUs,
        },
        'scheduler': _ticker.diagnostics,
      },
    );
    widget.renderer.addListener(_syncTicker);
    _bindClock();
    _bindInputs();
  }

  void _bindClock() {
    _anchors = widget.clock.mediaAnchors.listen(
      _acceptAnchor,
      onDone: () => _acceptAnchor(null),
    );
    _acceptAnchor(widget.clock.currentMediaAnchor);
  }

  void _bindInputs() {
    _inputs = widget.inputChanges?.listen((_) {
      if (!_ticker.isActive) _update();
    });
  }

  void _acceptAnchor(PlaybackMediaAnchor? anchor) {
    final previous = _anchor;
    _anchor = anchor;
    if (anchor == null || !anchor.ready) {
      _continuity = null;
      widget.renderer.suspendPresentation();
    }
    // 连续播放的采样只校准时钟，呈现统一由限帧回调推进。
    // 暂停、恢复和连续域变化仍立即处理，及时冻结或切换窗口。
    if (!_ticker.isActive ||
        anchor == null ||
        !anchor.advancing ||
        previous?.advancing != true ||
        previous?.continuity != anchor.continuity) {
      _update();
    }
    _syncTicker();
  }

  bool get _visible => _enabled && widget.opacity > 0;

  void _update({int? frameTimeUs}) {
    if (!_visible) return;
    final anchor = _anchor;
    var position = anchor?.positionAt(
      frameTimeUs ?? widget.monotonicUs?.call() ?? Timeline.now,
    );
    if (position == null) return;
    final renderer = widget.renderer;
    if (_continuity != anchor!.continuity) {
      if (!renderer.containsPreparedTime(position)) renderer.reset(position);
      _continuity = anchor.continuity;
    } else {
      final previousFrame = _lastFrameTimeUs;
      if (frameTimeUs != null &&
          previousFrame != null &&
          frameTimeUs > previousFrame &&
          frameTimeUs - previousFrame <= 50000 &&
          anchor.advancing &&
          frameTimeUs < anchor.observedAtUs + anchor.validForUs) {
        final advance = (frameTimeUs - previousFrame) * anchor.effectiveRate;
        final projected = _lastPositionUs + advance.round();
        final error = position - projected;
        // time-pos 随视频帧离散推进，接收时刻还包含通知延迟。
        // 连续帧的小幅校准分摊到后续帧，速度偏差限于 5%。
        // 超过 50ms 的显示空档或明显时钟偏移重新贴合媒体时间。
        if (error.abs() <= 100000 * anchor.effectiveRate &&
            frameTimeUs - previousFrame < anchor.validForUs) {
          final correction = (advance * .05).round();
          position = projected + error.clamp(-correction, correction);
        }
      }
      // 原生校准可能落后于已外推的画面，同一连续域等待媒体时间追上。
      position = math.max(
        position,
        math.max(_lastPositionUs, renderer.validFromUs),
      );
    }
    _lastPositionUs = position;
    _lastFrameTimeUs = frameTimeUs;
    renderer
      ..prepareConfiguration()
      ..present(position, allowUnprepared: true);
    widget.prepareFrame(
      renderer,
      position,
      effectiveRate: anchor.effectiveRate,
    );
    renderer.present(position, allowUnprepared: true);
    _syncTicker();
  }

  void _syncTicker() {
    _wake?.cancel();
    _wake = null;
    final now = widget.monotonicUs?.call() ?? Timeline.now;
    final anchor = _anchor;
    final advancing =
        anchor != null &&
        anchor.advancing &&
        now - anchor.observedAtUs < anchor.validForUs;
    final animate =
        _visible &&
        (_anchor?.ready ?? false) &&
        (widget.renderer.hasPendingConfiguration ||
            (widget.needsPreparation?.call() ?? false) ||
            (advancing && widget.renderer.needsContinuousFrames));
    if (animate && !_ticker.isActive) {
      _ticker.start();
    } else if (!animate && _ticker.isActive) {
      _ticker.stop();
    }
    if (!_visible || animate || !advancing || !anchor.ready) return;
    final position = anchor.positionAt(now)!;
    final deadlines = [
      ?widget.renderer.nextChangeUs,
      ?widget.nextPreparationUs?.call(),
    ];
    if (deadlines.isEmpty) return;
    final next = deadlines.reduce((a, b) => a < b ? a : b);
    final delay = ((next - position) / anchor.effectiveRate).ceil();
    final freshness = anchor.observedAtUs + anchor.validForUs - now;
    _wake = Timer(
      Duration(microseconds: delay.clamp(0, freshness)),
      _update,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _view = View.of(context);
    _enabled = TickerMode.valuesOf(context).enabled;
    if (!_ticker.isActive) _update();
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant DanmakuWindowScreen<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    _ticker.frameRate = widget.frameRate;
    _ticker.videoFrameTimings = widget.videoFrameTimings;
    _ticker.videoDisplaySyncActive = widget.videoDisplaySyncActive;
    if (!identical(oldWidget.clock, widget.clock)) {
      unawaited(_anchors?.cancel());
      _continuity = null;
      widget.renderer.reset(_lastPositionUs);
      _bindClock();
    }
    if (!identical(oldWidget.inputChanges, widget.inputChanges)) {
      unawaited(_inputs?.cancel());
      _bindInputs();
    }
    if (!identical(oldWidget.renderer, widget.renderer)) {
      oldWidget.renderer.removeListener(_syncTicker);
      widget.renderer.addListener(_syncTicker);
      _continuity = null;
    }
    if (!_ticker.isActive || !identical(oldWidget.renderer, widget.renderer)) {
      _update();
    }
    _syncTicker();
  }

  @override
  Widget build(BuildContext context) => Offstage(
    offstage: widget.opacity <= 0,
    child: IgnorePointer(
      child: RepaintBoundary(
        child: CustomPaint(
          size: widget.size,
          painter: _WindowPainter(widget.renderer, widget.opacity),
          willChange: _ticker.isActive,
        ),
      ),
    ),
  );

  @override
  void dispose() {
    _unregisterDiagnostics();
    _wake?.cancel();
    widget.renderer.removeListener(_syncTicker);
    unawaited(_anchors?.cancel());
    unawaited(_inputs?.cancel());
    _ticker.dispose();
    super.dispose();
  }
}

class _WindowPainter<T> extends CustomPainter {
  _WindowPainter(this.renderer, this.opacity) : super(repaint: renderer);
  final DanmakuWindowRenderer<T> renderer;
  final double opacity;
  @override
  void paint(Canvas canvas, Size size) =>
      renderer.paint(canvas, size, opacity: opacity);
  @override
  bool shouldRepaint(covariant _WindowPainter<T> oldDelegate) =>
      !identical(renderer, oldDelegate.renderer) ||
      opacity != oldDelegate.opacity;
}
