import 'dart:ui' as ui;
import 'dart:math' as math;

import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:pili_aurora/pages/danmaku/arrangement.dart';
import 'package:pili_aurora/pages/danmaku/raster_cache.dart';
import 'package:pili_aurora/pages/danmaku/render_guard.dart';
import 'package:pili_aurora/pages/danmaku/special_frame.dart';
import 'package:pili_aurora/pages/danmaku/interaction.dart';
import 'package:pili_aurora/pages/danmaku/timeline_window.dart';

class DanmakuWindowContent<T> {
  const DanmakuWindowContent(this.identity, this.sourceUs, this.content);
  final Object identity;
  final int sourceUs;
  final DanmakuContentItem<T> content;
}

class _ActiveRaster<T> {
  _ActiveRaster(this.item, this.image, {this.specialBounds});
  DanmakuWindowItem<DanmakuArrangement<DanmakuContentItem<T>>> item;
  final ui.Image image;
  final Rect? specialBounds;
  DanmakuSpecialFrame? specialFrame;
  int get bytes => image.width * image.height * 4;
}

/// 普通窗口的显示资源适配；同一媒体时刻用于绘制与命中。
class DanmakuWindowRenderer<T> extends ChangeNotifier {
  DanmakuWindowRenderer({
    required DanmakuOption option,
    required Size size,
    double devicePixelRatio = 1,
    String? fontFamily,
    this.maxActiveBytes = danmakuActiveRasterBytes,
    int rasterCacheMaxBytes = 16 * 1024 * 1024,
    int rasterCacheMaxEntries = 512,
  }) : _size = size,
       rasters = DanmakuRasterCache(
         option: option,
         devicePixelRatio: devicePixelRatio,
         fontFamily: fontFamily,
         maxBytes: rasterCacheMaxBytes,
         maxEntries: rasterCacheMaxEntries,
       ) {
    final trackHeight = rasters.measureTrackHeight();
    final tracks = size.isEmpty || trackHeight <= 0
        ? 0
        : math.max(
            0,
            (size.height * option.area / trackHeight).floor() -
                (option.safeArea && option.area == 1 ? 1 : 0),
          );
    _planner = DanmakuWindowPlanner(
      option: option,
      width: size.width,
      trackHeight: trackHeight,
      trackCount: tracks,
      padding: 1 / devicePixelRatio,
    );
  }

  final Size _size;
  final DanmakuRasterCache rasters;
  late final DanmakuWindowPlanner<DanmakuContentItem<T>> _planner;
  final int maxActiveBytes;
  final _active = <Object, _ActiveRaster<T>>{};
  final _unavailable = <Object>{};
  int _mediaUs = 0;
  int activeBytes = 0;
  bool _disposed = false;
  int _interactionEpoch = 0;
  ({Object identity, int remainingUs, double velocity})? _held;
  DanmakuInteractionHandle<T> get interaction =>
      _WindowInteraction(this, _interactionEpoch);
  int get activeCount => _active.length;
  int get activeSpecialCount =>
      _active.values.where((item) => item.specialBounds != null).length;
  bool hasPrepared(Object identity) => _planner.window.hasIdentity(identity);
  int get generation => _planner.window.generation;
  int get validFromUs => _planner.window.validFromUs;
  int get validUntilUs => _planner.window.validUntilUs;

  /// 在配置生效帧调用；视频倍速由媒体时钟表达，不传入显示时长。
  void updateTiming({
    required int mediaUs,
    required double duration,
    required double staticDuration,
    required bool scrollFixedVelocity,
  }) {
    if (_disposed) return;
    if (mediaUs < 0 ||
        !duration.isFinite ||
        duration <= 0 ||
        !staticDuration.isFinite ||
        staticDuration <= 0) {
      throw ArgumentError('媒体位置和弹幕时长必须有效');
    }
    final old = rasters.option;
    if (old.duration == duration &&
        old.staticDuration == staticDuration &&
        old.scrollFixedVelocity == scrollFixedVelocity) {
      return;
    }
    present(mediaUs, allowUnprepared: true);
    final next = old.copyWith(
      duration: duration,
      staticDuration: staticDuration,
      scrollFixedVelocity: scrollFixedVelocity,
    );
    final items =
        <DanmakuWindowItem<DanmakuArrangement<DanmakuContentItem<T>>>>[];
    for (final active in _active.values) {
      final item = active.item;
      final arrangement = item.payload;
      var motion = arrangement.trajectory!;
      var endUs = item.endUs;
      if (active.specialBounds == null) {
        final held = _held?.identity == item.identity;
        final velocity = arrangement.scrolling
            ? DanmakuGeometry.scrollVelocity(
                _size.width,
                motion.width,
                next.durationInMilliseconds,
                fixed: next.scrollFixedVelocity,
              )
            : 0.0;
        final x = motion.xAt(mediaUs / 1000);
        // 静态已显示时长包含此前重锚定，挂起期间不消耗剩余寿命。
        final remainingUs = arrangement.scrolling
            ? ((x + motion.width) / velocity * 1000).ceil()
            : (held ? _held!.remainingUs : item.endUs - mediaUs) +
                  ((staticDuration - old.staticDuration) * 1000000).round();
        if (held) {
          _held = (
            identity: item.identity,
            remainingUs: math.max(0, remainingUs),
            velocity: velocity,
          );
        }
        endUs = held ? 0x7fffffffffffffff : mediaUs + remainingUs;
        if (endUs <= mediaUs) continue;
        motion = DanmakuTrajectory(
          startMs: mediaUs / 1000,
          endMs: endUs / 1000,
          startX: x,
          y: motion.y,
          width: motion.width,
          height: motion.height,
          velocity: held ? 0 : velocity,
        );
      }
      items.add(
        DanmakuWindowItem(
          identity: item.identity,
          sourceUs: item.sourceUs,
          startUs: mediaUs,
          endUs: endUs,
          estimatedBytes: item.estimatedBytes,
          payload: DanmakuArrangement(
            arrangement.candidate,
            motion,
            arrangement.track,
            arrangement.scrolling,
            suspended: arrangement.suspended,
          ),
        ),
      );
    }
    rasters.option = _planner.option = next;
    _replaceActiveDomain(items);
  }

  bool prepare(
    List<DanmakuWindowContent<T>> contents, {
    required int generation,
    required int preparedUntilUs,
  }) {
    if (_disposed ||
        generation != _planner.window.generation ||
        contents.length > DanmakuDisplayLimits.maxPerBatch) {
      return false;
    }
    final known = {
      for (final item in _planner.window.preparedItems)
        item.identity: item.payload.candidate,
    };
    final candidates = <DanmakuMeasuredCandidate<DanmakuContentItem<T>>>[];
    for (final input in contents) {
      final previous = known[input.identity];
      if (previous != null) {
        candidates.add(previous);
        continue;
      }
      final special = input.content is SpecialDanmakuContentItem<T>
          ? input.content as SpecialDanmakuContentItem<T>
          : null;
      final hidden = rasters.option.hideWhat(input.content.type);
      final raster = hidden || input.content.type == DanmakuItemType.special
          ? null
          : rasters.get(input.content);
      final renderable =
          !hidden &&
          (special == null
              ? raster != null
              : DanmakuRenderGuard.canRasterizeSpecial(
                  special,
                  rasters.devicePixelRatio,
                  rasters.option.strokeWidth,
                  rasters.option.fontWeight,
                  fontFamily: rasters.fontFamily,
                ));
      candidates.add(
        DanmakuMeasuredCandidate(
          identity: input.identity,
          sourceUs: input.sourceUs,
          width: raster?.width ?? 0,
          height: raster?.height ?? 1,
          type: input.content.type,
          payload: input.content,
          selfSend: input.content.selfSend,
          renderable: renderable,
          specialDurationUs: special == null ? null : special.duration * 1000,
          estimatedBytes: input.content.text.length * 2,
        ),
      );
    }
    return _planner.prepare(
      candidates,
      generation: generation,
      preparedUntilUs: preparedUntilUs,
    );
  }

  bool present(int mediaUs, {bool allowUnprepared = false}) {
    if (_disposed) return false;
    _mediaUs = math.max(0, mediaUs);
    final visible = _planner.window.visibleAt(
      mediaUs,
      allowUnprepared: allowUnprepared,
    );
    final desired = {
      for (final item
          in visible ??
              <DanmakuWindowItem<DanmakuArrangement<DanmakuContentItem<T>>>>[])
        if (item.payload.accepted) item.identity: item,
    };
    _active.removeWhere((identity, raster) {
      if (desired.containsKey(identity)) return false;
      activeBytes -= raster.bytes;
      raster.image.dispose();
      return true;
    });
    for (final item in desired.values) {
      final existing = _active[item.identity];
      if (existing != null) {
        existing.item = item;
        continue;
      }
      if (_unavailable.contains(item.identity)) continue;
      final content = item.payload.candidate.payload;
      if (content is SpecialDanmakuContentItem<T>) {
        final raster = rasters.textRenderer.rasterizeSpecial(
          content: content,
          strokeWidth: rasters.option.strokeWidth,
          fontWeight: rasters.option.fontWeight,
        );
        final bytes = raster.image.width * raster.image.height * 4;
        if (activeBytes + bytes > maxActiveBytes) {
          raster.image.dispose();
          _unavailable.add(item.identity);
          continue;
        }
        _active[item.identity] = _ActiveRaster(
          item,
          raster.image,
          specialBounds: raster.bounds,
        );
        activeBytes += bytes;
        continue;
      }
      final raster = rasters.get(content);
      if (raster == null || activeBytes + raster.bytes > maxActiveBytes) {
        _unavailable.add(item.identity);
        continue;
      }
      final image = rasters.rasterize(content, raster);
      if (image == null) {
        _unavailable.add(item.identity);
        continue;
      }
      final active = _ActiveRaster(item, image.clone());
      _active[item.identity] = active;
      activeBytes += active.bytes;
    }
    for (final active in _active.values) {
      if (active.specialBounds != null) {
        active.specialFrame = DanmakuSpecialFrame.evaluate(
          content:
              active.item.payload.candidate.payload
                  as SpecialDanmakuContentItem<T>,
          rasterBounds: active.specialBounds!,
          size: _size,
          sourceUs: active.item.sourceUs,
          mediaUs: _mediaUs,
        );
      }
    }
    final ordered = {
      for (final identity in desired.keys)
        if (_active.containsKey(identity)) identity: _active[identity]!,
    };
    _active
      ..clear()
      ..addAll(ordered);
    notifyListeners();
    return visible != null;
  }

  DanmakuDisplaySnapshot<T>? _snapshotFor(_ActiveRaster<T> active) {
    final content = active.item.payload.candidate.payload;
    final motion = active.item.payload.trajectory!;
    final bounds = active.specialBounds == null
        ? Rect.fromLTWH(
            motion.xAt(_mediaUs / 1000),
            motion.y,
            motion.width,
            motion.height,
          )
        : active.specialFrame?.bounds;
    if (bounds == null) return null;
    return DanmakuDisplaySnapshot(
      identity: active.item.identity,
      text: content.text,
      extra: content.extra,
      bounds: bounds,
      selectable: active.specialBounds == null,
      selected: active.item.identity == _held?.identity,
    );
  }

  DanmakuDisplaySnapshot<T>? hitTest(Offset point) {
    final held = _active[_held?.identity];
    final selected = held == null ? null : _snapshotFor(held);
    if (selected != null && selected.bounds.contains(point)) return selected;
    for (final active in _active.values.toList().reversed) {
      if (active.specialBounds != null) continue;
      final snapshot = _snapshotFor(active);
      if (snapshot != null && snapshot.bounds.contains(point)) return snapshot;
    }
    return null;
  }

  bool _select(Object identity) {
    final active = _active[identity];
    if (active == null || active.specialBounds != null) return false;
    if (_held?.identity == identity) return true;
    final previous = _held;
    _held = (
      identity: identity,
      remainingUs: active.item.endUs - _mediaUs,
      velocity: active.item.payload.trajectory!.velocity,
    );
    _rebaseInteraction(previous);
    return true;
  }

  bool _clearSelection() {
    final previous = _held;
    if (previous == null) return true;
    _held = null;
    _rebaseInteraction(previous);
    return true;
  }

  void _rebaseInteraction(
    ({Object identity, int remainingUs, double velocity})? previous,
  ) {
    final items =
        <DanmakuWindowItem<DanmakuArrangement<DanmakuContentItem<T>>>>[];
    for (final active in _active.values) {
      final item = active.item;
      final arrangement = item.payload;
      var motion = arrangement.trajectory!;
      var endUs = item.endUs;
      if (active.specialBounds == null) {
        final x = motion.xAt(_mediaUs / 1000);
        var velocity = motion.velocity;
        if (previous?.identity == item.identity) {
          velocity = previous!.velocity;
          endUs = _mediaUs + previous.remainingUs;
        }
        final held = _held?.identity == item.identity;
        if (held) {
          velocity = 0;
          endUs = 0x7fffffffffffffff;
        }
        motion = DanmakuTrajectory(
          startMs: _mediaUs / 1000,
          endMs: endUs / 1000,
          startX: x,
          y: motion.y,
          width: motion.width,
          height: motion.height,
          velocity: velocity,
        );
      }
      if (endUs <= _mediaUs) continue;
      items.add(
        DanmakuWindowItem(
          identity: item.identity,
          sourceUs: item.sourceUs,
          startUs: _mediaUs,
          endUs: endUs,
          estimatedBytes: item.estimatedBytes,
          payload: DanmakuArrangement(
            arrangement.candidate,
            motion,
            arrangement.track,
            arrangement.scrolling,
            suspended: _held?.identity == item.identity,
          ),
        ),
      );
    }
    _replaceActiveDomain(items);
  }

  void _replaceActiveDomain(
    List<DanmakuWindowItem<DanmakuArrangement<DanmakuContentItem<T>>>> items,
  ) {
    _planner.window.reset(_mediaUs);
    _planner.window.extend(
      items,
      generation: _planner.window.generation,
      preparedUntilUs: _mediaUs + 1,
    );
    _unavailable.clear();
    present(_mediaUs, allowUnprepared: true);
  }

  void _paintOrdinary(Canvas canvas, _ActiveRaster<T> active, Paint paint) {
    final motion = active.item.payload.trajectory!;
    final position = Offset(motion.xAt(_mediaUs / 1000), motion.y);
    if (active.image.width == motion.width.ceil()) {
      canvas.drawImage(active.image, position, paint);
    } else {
      canvas.drawImageRect(
        active.image,
        Rect.fromLTWH(
          0,
          0,
          active.image.width.toDouble(),
          active.image.height.toDouble(),
        ),
        Rect.fromLTWH(position.dx, position.dy, motion.width, motion.height),
        paint,
      );
    }
  }

  void paint(Canvas canvas, Size size, {double opacity = 1}) {
    if (_disposed || opacity <= 0 || _active.isEmpty) return;
    canvas
      ..save()
      ..clipRect(Offset.zero & size);
    if (opacity < 1) {
      canvas.saveLayer(
        Offset.zero & size,
        Paint()..color = Color.fromRGBO(255, 255, 255, opacity),
      );
    }
    final paint = Paint();
    for (final active in _active.values) {
      if (active.specialBounds == null &&
          active.item.identity != _held?.identity) {
        _paintOrdinary(canvas, active, paint);
      }
    }
    for (final active in _active.values) {
      final frame = active.specialFrame;
      if (frame == null) continue;
      paint.color = frame.color;
      if (active.image.width == frame.bounds.width.ceil()) {
        canvas.drawImage(active.image, frame.bounds.topLeft, paint);
      } else {
        canvas.drawImageRect(
          active.image,
          Rect.fromLTWH(
            0,
            0,
            active.image.width.toDouble(),
            active.image.height.toDouble(),
          ),
          frame.bounds,
          paint,
        );
      }
    }
    final held = _active[_held?.identity];
    if (held != null) {
      _paintOrdinary(canvas, held, paint..color = const Color(0xffffffff));
    }
    if (opacity < 1) canvas.restore();
    canvas.restore();
  }

  void reset(int fromUs) {
    _interactionEpoch++;
    _held = null;
    for (final active in _active.values) {
      active.image.dispose();
    }
    _active.clear();
    activeBytes = 0;
    _unavailable.clear();
    _planner.window.reset(fromUs);
    _mediaUs = fromUs;
    notifyListeners();
  }

  void trimBefore(int fromUs) {
    _planner.window.trimBefore(fromUs);
    final retained = _planner.window.preparedItems
        .map((item) => item.identity)
        .toSet();
    _unavailable.removeWhere((identity) => !retained.contains(identity));
    present(_mediaUs, allowUnprepared: true);
  }

  @override
  void dispose() {
    reset(_mediaUs);
    _disposed = true;
    rasters.clear();
    super.dispose();
  }
}

class _WindowInteraction<T> implements DanmakuInteractionHandle<T> {
  _WindowInteraction(this.renderer, this.epoch);
  final DanmakuWindowRenderer<T> renderer;
  final int epoch;
  @override
  bool get isValid =>
      !renderer._disposed && epoch == renderer._interactionEpoch;
  @override
  List<DanmakuDisplaySnapshot<T>> get snapshot => !isValid
      ? const []
      : List.unmodifiable([
          for (final active in renderer._active.values)
            ?renderer._snapshotFor(active),
        ]);
  @override
  DanmakuDisplaySnapshot<T>? hitTest(Offset point) =>
      isValid ? renderer.hitTest(point) : null;
  @override
  bool select(Object identity) => isValid && renderer._select(identity);
  @override
  bool clearSelection() => isValid && renderer._clearSelection();
}
