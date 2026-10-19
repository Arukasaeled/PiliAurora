import 'dart:async';
import 'dart:developer' show Timeline;
import 'dart:ui' show FlutterView;

import 'package:canvas_danmaku/frame_rate_ticker.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/widgets.dart';
import 'package:pili_aurora/pages/danmaku/window_renderer.dart';
import 'package:pili_aurora/plugin/pl_player/playback/media_clock.dart';

typedef DanmakuPrepareFrame<T> = void Function(
  DanmakuWindowRenderer<T>,
  int mediaUs,
);

/// 挂载方持有 renderer；此控件管理媒体订阅、帧调度与绘制挂载。
class DanmakuWindowScreen<T> extends StatefulWidget {
  const DanmakuWindowScreen({
    super.key,
    required this.renderer,
    required this.clock,
    required this.size,
    required this.prepareFrame,
    this.inputChanges,
    this.opacity = 1,
    this.frameRate = 0,
    this.videoFrameTimings,
    this.videoDisplaySyncActive,
    this.monotonicUs,
  });

  final DanmakuWindowRenderer<T> renderer;
  final PlaybackMediaClock clock;
  final Size size;
  final DanmakuPrepareFrame<T> prepareFrame;
  final Stream<Object?>? inputChanges;
  final double opacity;
  final int frameRate;
  final ValueListenable<List<int>>? videoFrameTimings;
  final ValueListenable<bool>? videoDisplaySyncActive;
  final int Function()? monotonicUs;

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
  bool _enabled = false;
  FlutterView? _view;

  @override
  void initState() {
    super.initState();
    _ticker = FrameRateTicker(
      (_) => _update(),
      frameRate: widget.frameRate,
      videoFrameTimings: widget.videoFrameTimings,
      videoDisplaySyncActive: widget.videoDisplaySyncActive,
      screenRefreshRate: () => _view?.display.refreshRate ?? 0,
    );
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
    _inputs = widget.inputChanges?.listen((_) => _update());
  }

  void _acceptAnchor(PlaybackMediaAnchor? anchor) {
    _anchor = anchor;
    if (anchor == null || !anchor.ready) {
      _continuity = null;
      widget.renderer.reset(_lastPositionUs);
    }
    _update();
    _syncTicker();
  }

  bool get _visible => _enabled && widget.opacity > 0;

  void _update() {
    if (!_visible) return;
    final anchor = _anchor;
    final position = anchor?.positionAt(
      widget.monotonicUs?.call() ?? Timeline.now,
    );
    if (position == null) return;
    final renderer = widget.renderer;
    if (_continuity != anchor!.continuity ||
        (renderer.validUntilUs > renderer.validFromUs &&
            (position < renderer.validFromUs ||
                position >= renderer.validUntilUs))) {
      renderer.reset(position);
      _continuity = anchor.continuity;
    }
    _lastPositionUs = position;
    widget.prepareFrame(renderer, position);
    renderer.present(position);
    _syncTicker();
  }

  void _syncTicker() {
    final animate =
        _visible &&
        (_anchor?.ready ?? false) &&
        (_anchor?.advancing ?? false) &&
        (widget.monotonicUs?.call() ?? Timeline.now) - _anchor!.observedAtUs <
            _anchor!.validForUs;
    if (animate && !_ticker.isActive) {
      _ticker.start();
    } else if (!animate && _ticker.isActive) {
      _ticker.stop();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _view = View.of(context);
    _enabled = TickerMode.valuesOf(context).enabled;
    _update();
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
    if (!identical(oldWidget.renderer, widget.renderer)) _continuity = null;
    _update();
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
