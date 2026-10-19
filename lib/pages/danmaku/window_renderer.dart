import 'dart:ui' as ui;
import 'dart:math' as math;

import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:pili_aurora/pages/danmaku/arrangement.dart';
import 'package:pili_aurora/pages/danmaku/raster_cache.dart';
import 'package:pili_aurora/pages/danmaku/timeline_window.dart';

class DanmakuWindowContent<T> {
  const DanmakuWindowContent(this.identity, this.sourceUs, this.content);
  final Object identity;
  final int sourceUs;
  final DanmakuContentItem<T> content;
}

class _ActiveRaster<T> {
  _ActiveRaster(this.item, this.image);
  final DanmakuWindowItem<DanmakuArrangement<DanmakuContentItem<T>>> item;
  final ui.Image image;
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
  }) : rasters = DanmakuRasterCache(
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

  final DanmakuRasterCache rasters;
  late final DanmakuWindowPlanner<DanmakuContentItem<T>> _planner;
  final int maxActiveBytes;
  final _active = <Object, _ActiveRaster<T>>{};
  final _unavailable = <Object>{};
  int _mediaUs = 0;
  int activeBytes = 0;
  bool _disposed = false;
  int get activeCount => _active.length;
  int get generation => _planner.window.generation;
  int get validFromUs => _planner.window.validFromUs;
  int get validUntilUs => _planner.window.validUntilUs;

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
      final raster = input.content.type == DanmakuItemType.special
          ? null
          : rasters.get(input.content);
      candidates.add(
        DanmakuMeasuredCandidate(
          identity: input.identity,
          sourceUs: input.sourceUs,
          width: raster?.width ?? 0,
          height: raster?.height ?? 1,
          type: input.content.type,
          payload: input.content,
          selfSend: input.content.selfSend,
          renderable: raster != null,
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

  bool present(int mediaUs) {
    if (_disposed) return false;
    _mediaUs = math.max(0, mediaUs);
    final visible = _planner.window.visibleAt(mediaUs);
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
      if (_active.containsKey(item.identity) ||
          _unavailable.contains(item.identity)) {
        continue;
      }
      final content = item.payload.candidate.payload;
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

  ({Object identity, DanmakuContentItem<T> content, Rect bounds})? hitTest(
    Offset point,
  ) {
    for (final active in _active.values.toList().reversed) {
      final motion = active.item.payload.trajectory!;
      final bounds = Rect.fromLTWH(
        motion.xAt(_mediaUs / 1000),
        motion.y,
        motion.width,
        motion.height,
      );
      if (bounds.contains(point)) {
        return (
          identity: active.item.identity,
          content: active.item.payload.candidate.payload,
          bounds: bounds,
        );
      }
    }
    return null;
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
    if (opacity < 1) canvas.restore();
    canvas.restore();
  }

  void reset(int fromUs) {
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
    present(_mediaUs);
  }

  @override
  void dispose() {
    reset(_mediaUs);
    _disposed = true;
    rasters.clear();
    super.dispose();
  }
}
