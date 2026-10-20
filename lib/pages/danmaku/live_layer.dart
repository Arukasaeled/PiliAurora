import 'dart:async';
import 'dart:ui' as ui;

import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:pili_aurora/common/widgets/image/cached_image.dart';
import 'package:pili_aurora/pages/danmaku/interaction.dart';
import 'package:pili_aurora/pages/danmaku/live_queue.dart';
import 'package:pili_aurora/pages/danmaku/window_renderer.dart';
import 'package:pili_aurora/utils/image_utils.dart';
import 'package:pili_aurora/services/diagnostics/diagnostics.dart';

class LiveDanmakuLayer<T> extends StatefulWidget {
  const LiveDanmakuLayer({
    super.key,
    required this.messages,
    required this.running,
    required this.visible,
    required this.option,
    required this.size,
    this.frameRate = 0,
    this.videoDisplaySyncActive,
    this.createdInteraction,
    this.monotonicUs,
  });
  final Stream<LiveDanmakuMessage<T>> messages;
  final bool running, visible;
  final DanmakuOption option;
  final Size size;
  final int frameRate;
  final int Function()? monotonicUs;
  final ValueListenable<bool>? videoDisplaySyncActive;
  final void Function(DanmakuInteractionHandle<T> Function(), VoidCallback)?
  createdInteraction;
  @override
  State<LiveDanmakuLayer<T>> createState() => _LiveDanmakuLayerState<T>();
}

class _LiveDanmakuLayerState<T> extends State<LiveDanmakuLayer<T>> {
  DanmakuWindowRenderer<T>? _renderer;
  int _motionUs = 0;
  final _contents = <Object, DanmakuContentItem<T>>{};
  late final FrameRateTicker _ticker;
  late final LiveDanmakuQueue<T> _queue;
  StreamSubscription<LiveDanmakuMessage<T>>? _subscription;
  Timer? _deadline;
  late final VoidCallback _unregisterDiagnostics;
  bool _enabled = true, _queued = false, _disposed = false;
  bool _refreshing = false;
  late int _lastUs;
  int get _now => widget.monotonicUs?.call() ?? liveDanmakuNowUs();
  bool get _visible => widget.visible && _enabled && !widget.size.isEmpty;
  @override
  void initState() {
    super.initState();
    _lastUs = _now;
    _ticker = FrameRateTicker(
      (_) => _refresh(),
      frameRate: widget.frameRate,
      videoDisplaySyncActive: widget.videoDisplaySyncActive,
      screenRefreshRate: () => View.of(context).display.refreshRate,
    );
    _queue = LiveDanmakuQueue<T>(
      loadImage: _loadImage,
      nowUs: () => _now,
      admit: (item) {
        final renderer = _renderer!;
        final before = renderer.activeCount;
        final prepared = renderer.prepare(
          [DanmakuWindowContent(item, _motionUs, item)],
          generation: renderer.generation,
          preparedUntilUs: _motionUs + 1,
        );
        renderer.present(_motionUs, allowUnprepared: true);
        final accepted = prepared && renderer.activeCount > before;
        if (accepted) _contents[item] = item;
        return accepted;
      },
      wake: _wake,
    );
    _unregisterDiagnostics = Diagnostics.instance.register(
      'danmaku.layer.$hashCode',
      () => {
        ...?_renderer?.statistics,
        'input': 'live',
        'motionUs': _motionUs,
        'candidates': _queue.candidateCount,
        'resourceTasks': _queue.runningTasks,
        'resourceReservedBytes': _queue.reservedBytes,
        'scheduler': _ticker.diagnostics,
      },
    );
  }

  Future<ui.Image?> _loadImage(LiveEmoteDescriptor emote) {
    final result = Completer<ui.Image?>();
    final stream = CachedImageProvider(
      ImageUtils.thumbnailUrl(emote.url),
      maxDecodePixels: 1 << 16,
    ).resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        final image = info.image.clone();
        info.dispose();
        stream.removeListener(listener);
        result.complete(image);
      },
      onError: (Object _, StackTrace? _) {
        stream.removeListener(listener);
        result.complete(null);
      },
    );
    stream.addListener(listener);
    return result.future;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _enabled = TickerMode.valuesOf(context).enabled;
    if (_renderer == null) {
      _renderer = DanmakuWindowRenderer<T>(
        option: widget.option,
        size: widget.size,
        devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
        fontFamily: DefaultTextStyle.of(context).style.fontFamily,
      );
      _renderer!.addListener(_rendererChanged);
      widget.createdInteraction?.call(() => _renderer!.interaction, _clear);
    }
    _renderer!.requestConfiguration(
      option: widget.option,
      size: widget.size,
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
      fontFamily: DefaultTextStyle.of(context).style.fontFamily,
    );
    _lastUs = _now;
    _syncSubscription();
    _wake();
  }

  void _clear() {
    _queue.clear();
    _renderer?.reset(_motionUs);
    for (final content in _contents.values) {
      content.dispose();
    }
    _contents.clear();
    _wake();
  }

  void _syncSubscription() {
    if (_visible) {
      _subscription ??= widget.messages.listen(_queue.add);
    } else {
      unawaited(_subscription?.cancel());
      _subscription = null;
      _clear();
      _ticker.stop();
      _deadline?.cancel();
    }
  }

  @override
  void didUpdateWidget(LiveDanmakuLayer<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.messages != widget.messages) {
      unawaited(_subscription?.cancel());
      _subscription = null;
      _clear();
    }
    if (oldWidget.option.fontSize != widget.option.fontSize ||
        oldWidget.option.fontWeight != widget.option.fontWeight ||
        oldWidget.option.strokeWidth != widget.option.strokeWidth ||
        oldWidget.size != widget.size) {
      _queue.clear();
    }
    _ticker.frameRate = widget.frameRate;
    _ticker.videoDisplaySyncActive = widget.videoDisplaySyncActive;
    _renderer?.requestConfiguration(
      option: widget.option,
      size: widget.size,
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
      fontFamily: DefaultTextStyle.of(context).style.fontFamily,
    );
    _lastUs = _now;
    _syncSubscription();
    _wake();
  }

  void _rendererChanged() {
    if (!_refreshing) _wake();
  }

  void _wake() {
    if (_queued || _disposed) return;
    _queued = true;
    scheduleMicrotask(() {
      _queued = false;
      if (!_disposed) _refresh();
    });
  }

  void _refresh() {
    final renderer = _renderer;
    if (renderer == null || !_visible || _disposed) return;
    _refreshing = true;
    final now = _now;
    if (widget.running) {
      _motionUs += now - _lastUs;
    }
    _lastUs = now;
    renderer
      ..prepareConfiguration()
      ..present(_motionUs, allowUnprepared: true);
    if (!renderer.hasPendingConfiguration &&
        renderer.validUntilUs <= _motionUs) {
      renderer.prepare(
        [],
        generation: renderer.generation,
        preparedUntilUs: _motionUs + 1,
      );
    }
    renderer.trimBefore(
      _motionUs < renderer.validUntilUs ? _motionUs : renderer.validUntilUs,
    );
    final active = renderer.interaction.snapshot
        .map((item) => item.identity)
        .toSet();
    _contents.removeWhere((identity, content) {
      if (active.contains(identity)) return false;
      content.dispose();
      return true;
    });
    _queue.process(
      running: widget.running && !renderer.hasPendingConfiguration,
      fontSize: widget.option.fontSize,
    );
    _refreshing = false;
    final dynamic =
        renderer.hasPendingConfiguration ||
        (widget.running && (renderer.needsContinuousFrames || _queue.hasReady));
    if (dynamic && !_ticker.isActive) _ticker.start();
    if (!dynamic && _ticker.isActive) _ticker.stop();
    _deadline?.cancel();
    int? due = _queue.nextDeadlineUs;
    final expiry = renderer.nextChangeUs;
    if (widget.running && expiry != null) {
      final expiryUs = now + expiry - _motionUs;
      if (due == null || expiryUs < due) due = expiryUs;
    }
    if (due != null) {
      _deadline = Timer(
        Duration(microseconds: (due - now).clamp(1, 1000000)),
        _wake,
      );
    }
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: RepaintBoundary(
      child: CustomPaint(
        size: widget.size,
        painter: _LivePainter(_renderer, widget.visible),
      ),
    ),
  );
  @override
  void dispose() {
    _unregisterDiagnostics();
    _disposed = true;
    unawaited(_subscription?.cancel());
    _deadline?.cancel();
    _queue.dispose();
    _ticker.dispose();
    _renderer?.removeListener(_rendererChanged);
    _renderer?.dispose();
    for (final content in _contents.values) {
      content.dispose();
    }
    _contents.clear();
    super.dispose();
  }
}

class _LivePainter<T> extends CustomPainter {
  _LivePainter(this.renderer, this.visible) : super(repaint: renderer);
  final DanmakuWindowRenderer<T>? renderer;
  final bool visible;
  @override
  void paint(Canvas canvas, Size size) {
    if (visible) renderer?.paint(canvas, size);
  }

  @override
  bool shouldRepaint(_LivePainter<T> oldDelegate) =>
      oldDelegate.visible != visible || oldDelegate.renderer != renderer;
}
