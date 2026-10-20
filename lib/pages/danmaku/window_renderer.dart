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
  _ActiveRaster(this.item, this.image, {this.specialBounds, Object? backing})
    : backing = backing ?? image,
      bytes = image.width * image.height * 4;
  DanmakuWindowItem<DanmakuArrangement<DanmakuContentItem<T>>> item;
  final ui.Image image;
  final Rect? specialBounds;
  DanmakuSpecialFrame? specialFrame;
  final Object backing;
  final int bytes;
  bool released = false;
  void release() {
    if (released) return;
    released = true;
    image.dispose();
  }
}

class _ConfigurationTarget {
  _ConfigurationTarget(this.rasters, this.size);
  final DanmakuRasterCache rasters;
  final Size size;
  final prepared =
      <
        Object,
        ({
          ui.Image image,
          double width,
          double height,
          Rect? specialBounds,
          Object backing,
        })?
      >{};
  int bytes = 0;
  void dispose() {
    for (final raster in prepared.values) {
      raster?.image.dispose();
    }
    rasters.clear();
  }
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
    int? maxWorkingSetBytes,
  }) : maxWorkingSetBytes =
           maxWorkingSetBytes ??
           maxActiveBytes + rasterCacheMaxBytes + 4 * 1024 * 1024,
       _size = size,
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

  Size _size;
  DanmakuRasterCache rasters;
  late DanmakuWindowPlanner<DanmakuContentItem<T>> _planner;
  _ConfigurationTarget? _configuration;
  bool get hasPendingConfiguration => _configuration != null;
  Rect get _displayClip {
    final target = _configuration;
    final size = target?.size ?? _size;
    final area = math.min(
      rasters.option.area,
      target?.rasters.option.area ?? rasters.option.area,
    );
    return Rect.fromLTWH(0, 0, size.width, size.height * area);
  }

  /// 连续更新覆盖尚未生效的目标，准备工作由帧入口分批推进。
  void requestConfiguration({
    required DanmakuOption option,
    required Size size,
    required double devicePixelRatio,
    String? fontFamily,
  }) {
    if (_disposed) return;
    if (!size.width.isFinite ||
        !size.height.isFinite ||
        size.width < 0 ||
        size.height < 0 ||
        !devicePixelRatio.isFinite ||
        devicePixelRatio <= 0) {
      throw ArgumentError('弹幕尺寸和 DPI 必须有效');
    }
    final current = _configuration?.rasters ?? rasters;
    final currentSize = _configuration?.size ?? _size;
    if (currentSize == size &&
        current.devicePixelRatio == devicePixelRatio &&
        current.fontFamily == fontFamily &&
        _sameOptions(current.option, option)) {
      return;
    }
    _configuration?.dispose();
    _configuration = _ConfigurationTarget(
      DanmakuRasterCache(
        option: option,
        devicePixelRatio: devicePixelRatio,
        fontFamily: fontFamily,
        maxBytes: rasters.maxBytes,
        maxEntries: rasters.maxEntries,
        maxItemBytes: rasters.maxItemBytes,
      ),
      size,
    );
  }

  static bool _sameOptions(DanmakuOption a, DanmakuOption b) =>
      a.fontSize == b.fontSize &&
      a.fontWeight == b.fontWeight &&
      a.area == b.area &&
      a.duration == b.duration &&
      a.staticDuration == b.staticDuration &&
      a.hideTop == b.hideTop &&
      a.hideBottom == b.hideBottom &&
      a.hideScroll == b.hideScroll &&
      a.hideSpecial == b.hideSpecial &&
      a.strokeWidth == b.strokeWidth &&
      a.scrollFixedVelocity == b.scrollFixedVelocity &&
      a.massiveMode == b.massiveMode &&
      a.static2Scroll == b.static2Scroll &&
      a.safeArea == b.safeArea &&
      a.lineHeight == b.lineHeight;

  /// 每次最多准备一小批活动资源，准备峰值共用实例工作集预算。
  bool prepareConfiguration({int maxItems = 16}) {
    if (maxItems <= 0) throw ArgumentError.value(maxItems);
    final target = _configuration;
    if (target == null) return true;
    target.prepared.removeWhere((identity, raster) {
      if (_active.containsKey(identity)) return false;
      if (raster != null) {
        target.bytes -= raster.image.width * raster.image.height * 4;
        raster.image.dispose();
      }
      return true;
    });
    var count = 0;
    for (final active in _active.values) {
      final identity = active.item.identity;
      if (target.prepared.containsKey(identity)) continue;
      if (count++ >= math.min(maxItems, 16)) return false;
      target.prepared[identity] = null;
      final content = active.item.payload.candidate.payload;
      if (target.size.isEmpty || target.rasters.option.hideWhat(content.type)) {
        continue;
      }
      final next = target.rasters;
      if (!active.released &&
          next.option.fontSize == rasters.option.fontSize &&
          next.option.fontWeight == rasters.option.fontWeight &&
          next.option.strokeWidth == rasters.option.strokeWidth &&
          next.devicePixelRatio == rasters.devicePixelRatio &&
          next.fontFamily == rasters.fontFamily &&
          target.bytes + active.bytes <= maxActiveBytes) {
        final motion = active.item.payload.trajectory!;
        target.prepared[identity] = (
          image: active.image.clone(),
          width: motion.width,
          height: motion.height,
          specialBounds: active.specialBounds,
          backing: active.backing,
        );
        target.bytes += active.bytes;
        continue;
      }
      ui.Image? image;
      double width, height;
      Rect? bounds;
      Object backing;
      if (content is SpecialDanmakuContentItem<T>) {
        if (!DanmakuRenderGuard.canRasterizeSpecial(
          content,
          target.rasters.devicePixelRatio,
          target.rasters.option.strokeWidth,
          target.rasters.option.fontWeight,
          fontFamily: target.rasters.fontFamily,
        )) {
          continue;
        }
        if (!_reserveConfigurationBytes(
          _specialBytes(content, target.rasters),
        )) {
          continue;
        }
        final raster = target.rasters.textRenderer.rasterizeSpecial(
          content: content,
          strokeWidth: target.rasters.option.strokeWidth,
          fontWeight: target.rasters.option.fontWeight,
        );
        image = raster.image;
        backing = image;
        bounds = raster.bounds;
        width = bounds.width;
        height = bounds.height;
      } else {
        var raster = target.rasters.get(content);
        if (raster == null || target.bytes + raster.bytes > maxActiveBytes) {
          continue;
        }
        if (!_reserveConfigurationBytes(raster.bytes + 512)) continue;
        // 回收缓存可能同时释放刚测量的段落，按当前目标重新取得。
        raster = target.rasters.get(content);
        if (raster == null) continue;
        backing = raster;
        image = target.rasters.rasterize(content, raster)?.clone();
        if (image == null) continue;
        width = raster.width;
        height = raster.height;
      }
      final bytes = image.width * image.height * 4;
      if (target.bytes + bytes > maxActiveBytes) {
        image.dispose();
        continue;
      }
      target.bytes += bytes;
      target.prepared[identity] = (
        image: image,
        width: width,
        height: height,
        specialBounds: bounds,
        backing: backing,
      );
    }
    return true;
  }

  void _commitConfiguration(int mediaUs) {
    final target = _configuration;
    if (target == null ||
        _active.keys.any((id) => !target.prepared.containsKey(id))) {
      return;
    }
    final oldOption = rasters.option;
    final option = target.rasters.option;
    final trackHeight = target.rasters.measureTrackHeight();
    final tracks = target.size.isEmpty || trackHeight <= 0
        ? 0
        : math.max(
            0,
            (target.size.height * option.area / trackHeight).floor() -
                (option.safeArea && option.area == 1 ? 1 : 0),
          );
    final items =
        <DanmakuWindowItem<DanmakuArrangement<DanmakuContentItem<T>>>>[];
    final replacement = <Object, _ActiveRaster<T>>{};
    for (final active in _active.values) {
      final item = active.item;
      final raster = target.prepared.remove(item.identity);
      if (raster == null) continue;
      if (item.endUs <= mediaUs) {
        raster.image.dispose();
        continue;
      }
      final old = item.payload;
      final motion = old.trajectory!;
      final held = _held?.identity == item.identity;
      final velocity = old.scrolling
          ? DanmakuGeometry.scrollVelocity(
              target.size.width,
              raster.width,
              option.durationInMilliseconds,
              fixed: option.scrollFixedVelocity,
            )
          : 0.0;
      final x = motion.xAt(mediaUs / 1000);
      final remaining = old.scrolling
          ? ((x + raster.width) / velocity * 1000).ceil()
          : (held ? _held!.remainingUs : item.endUs - mediaUs) +
                ((option.staticDuration - oldOption.staticDuration) * 1000000)
                    .round();
      final end = active.specialBounds != null
          ? item.endUs
          : held
          ? 0x7fffffffffffffff
          : mediaUs + remaining;
      if (end <= mediaUs) {
        raster.image.dispose();
        continue;
      }
      if (held) {
        _held = (
          identity: item.identity,
          remainingUs: math.max(0, remaining),
          velocity: velocity,
        );
      }
      final candidate = old.candidate;
      final updated = DanmakuWindowItem(
        identity: item.identity,
        sourceUs: item.sourceUs,
        startUs: mediaUs,
        endUs: end,
        estimatedBytes: item.estimatedBytes,
        payload: DanmakuArrangement(
          DanmakuMeasuredCandidate(
            identity: candidate.identity,
            sourceUs: candidate.sourceUs,
            width: raster.width,
            height: raster.height,
            type: candidate.type,
            payload: candidate.payload,
            selfSend: candidate.selfSend,
            specialDurationUs: candidate.specialDurationUs,
            estimatedBytes: candidate.estimatedBytes,
          ),
          DanmakuTrajectory(
            startMs: mediaUs / 1000,
            endMs: end / 1000,
            startX: x,
            y: motion.y,
            width: raster.width,
            height: raster.height,
            velocity: held ? 0 : velocity,
          ),
          trackHeight > 0 ? (motion.y / trackHeight).floor() : old.track,
          old.scrolling,
          suspended: held,
        ),
      );
      items.add(updated);
      replacement[item.identity] = _ActiveRaster(
        updated,
        raster.image,
        specialBounds: raster.specialBounds,
        backing: raster.backing,
      );
    }
    for (final active in _active.values) {
      active.release();
    }
    rasters.clear();
    rasters = target.rasters;
    _size = target.size;
    // 复用窗口实例以保留单调递增的 generation，旧目标无法提交。
    _planner = DanmakuWindowPlanner(
      option: option,
      width: _size.width,
      trackHeight: trackHeight,
      trackCount: tracks,
      padding: 1 / rasters.devicePixelRatio,
      window: _planner.window,
    );
    _planner.window.reset(mediaUs);
    _planner.window.extend(
      items,
      generation: generation,
      preparedUntilUs: mediaUs + 1,
    );
    _active
      ..clear()
      ..addAll(replacement);
    if (!_active.containsKey(_held?.identity)) _held = null;
    for (final raster in target.prepared.values) {
      raster?.image.dispose();
    }
    _configuration = null;
    _unavailable.clear();
  }

  final int maxActiveBytes;
  final int maxWorkingSetBytes;

  /// 图片按 backing 计一次，缓存与活动 clone 之间转移不增加总账。
  int get workingSetBytes {
    final target = _configuration;
    var bytes =
        rasters.bytes +
        (target?.rasters.bytes ?? 0) +
        _planner.window.estimatedBytes +
        (rasters.length + (target?.rasters.length ?? 0)) * 512 +
        (target?.prepared.length ?? 0) * 256;
    final backings = <Object>{};
    void include(Object backing, ui.Image image) {
      if (!backings.add(backing)) return;
      if (backing is DanmakuRaster && backing.image != null) return;
      bytes += image.width * image.height * 4;
    }

    for (final active in _active.values) {
      if (!active.released) include(active.backing, active.image);
    }
    if (target != null) {
      for (final raster in target.prepared.values) {
        if (raster != null) include(raster.backing, raster.image);
      }
    }
    return bytes;
  }

  Map<String, Object?> get statistics => {
    'renderer': 'shared-window',
    'active': activeCount,
    'activeSpecial': activeSpecialCount,
    'activeImageBytes': activeBytes,
    'activeImageLimitBytes': maxActiveBytes,
    'workingSetBytes': workingSetBytes,
    'workingSetLimitBytes': maxWorkingSetBytes,
    'cacheEntries': rasters.length,
    'cacheImageBytes': rasters.bytes,
    'layouts': rasters.layouts,
    'rasterizations': rasters.rasterizations,
    'configurationPending': hasPendingConfiguration,
    'windowItems': _planner.window.length,
    'windowBytes': _planner.window.estimatedBytes,
    'generation': generation,
    'validFromUs': validFromUs,
    'validUntilUs': validUntilUs,
  };

  int _specialBytes(
    SpecialDanmakuContentItem content,
    DanmakuRasterCache cache,
  ) {
    final paragraph = cache.textRenderer.generateParagraph(
      content: content,
      fontSize: content.fontSize,
      fontWeight: cache.option.fontWeight,
    );
    final width = paragraph.maxIntrinsicWidth + cache.option.strokeWidth;
    final height = paragraph.height + cache.option.strokeWidth;
    paragraph.dispose();
    final matrix = content.matrix;
    final cosZ = matrix == null ? math.cos(content.rotateZ) : matrix[5];
    final sinZ = matrix == null ? math.sin(content.rotateZ) : matrix[1];
    final cosY = matrix == null ? 1.0 : matrix[10];
    final xs = [
      0.0,
      width * cosZ * cosY,
      -height * sinZ * cosY,
      width * cosZ * cosY - height * sinZ * cosY,
    ];
    final ys = [0.0, width * sinZ, height * cosZ, width * sinZ + height * cosZ];
    return ((xs.reduce(math.max) - xs.reduce(math.min)) *
                cache.devicePixelRatio)
            .ceil() *
        ((ys.reduce(math.max) - ys.reduce(math.min)) * cache.devicePixelRatio)
            .ceil() *
        4;
  }

  bool _reserveConfigurationBytes(int bytes) {
    if (workingSetBytes + bytes <= maxWorkingSetBytes) return true;
    // 先取消可回收缓存，再逐批释放旧图片；轨迹与选择留到提交帧。
    rasters.clear();
    _configuration?.rasters.clear();
    if (workingSetBytes + bytes <= maxWorkingSetBytes) return true;
    for (final active in _active.values) {
      if (active.released) continue;
      active.release();
      if (workingSetBytes + bytes <= maxWorkingSetBytes) return true;
    }
    return workingSetBytes + bytes <= maxWorkingSetBytes;
  }

  final _active = <Object, _ActiveRaster<T>>{};
  final _unavailable = <Object>{};
  int _mediaUs = 0;
  int get activeBytes {
    final seen = <Object>{};
    return _active.values.fold(
      0,
      (sum, item) =>
          sum + (!item.released && seen.add(item.backing) ? item.bytes : 0),
    );
  }

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
  bool get needsContinuousFrames => _active.values.any(
    (active) =>
        active.specialBounds != null ||
        active.item.payload.trajectory!.velocity > 0,
  );

  int? get nextChangeUs {
    int? next;
    for (final item in _planner.window.preparedItems) {
      if (!item.payload.accepted) continue;
      for (final time in [item.startUs, item.endUs]) {
        if (time > _mediaUs && time != 0x7fffffffffffffff) {
          next = next == null ? time : math.min(time, next);
        }
      }
    }
    return next;
  }

  /// 类别变化立即移除对应活动项，准入规则变化撤回前方编排。
  void updateAdmission({
    required int mediaUs,
    required bool hideTop,
    required bool hideBottom,
    required bool hideScroll,
    required bool hideSpecial,
    required bool massiveMode,
    required bool static2Scroll,
  }) {
    if (_disposed) return;
    if (mediaUs < 0) throw ArgumentError.value(mediaUs);
    final old = rasters.option;
    if (old.hideTop == hideTop &&
        old.hideBottom == hideBottom &&
        old.hideScroll == hideScroll &&
        old.hideSpecial == hideSpecial &&
        old.massiveMode == massiveMode &&
        old.static2Scroll == static2Scroll) {
      return;
    }
    present(mediaUs, allowUnprepared: true);
    final next = old.copyWith(
      hideTop: hideTop,
      hideBottom: hideBottom,
      hideScroll: hideScroll,
      hideSpecial: hideSpecial,
      massiveMode: massiveMode,
      static2Scroll: static2Scroll,
    );
    final retained = [
      for (final active in _active.values)
        if (!next.hideWhat(active.item.payload.candidate.type)) active.item,
    ];
    if (!retained.any((item) => item.identity == _held?.identity)) _held = null;
    rasters.option = _planner.option = next;
    _replaceActiveDomain(retained);
  }

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
        _configuration != null ||
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
    _commitConfiguration(_mediaUs);
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
      raster.release();
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
        if (!_reserveConfigurationBytes(_specialBytes(content, rasters))) {
          _unavailable.add(item.identity);
          continue;
        }
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
        continue;
      }
      var raster = rasters.get(content);
      if (raster == null ||
          activeBytes +
                  (_active.values.any(
                        (active) =>
                            !active.released && active.backing == raster,
                      )
                      ? 0
                      : raster.bytes) >
              maxActiveBytes) {
        _unavailable.add(item.identity);
        continue;
      }
      if (!_reserveConfigurationBytes(
        raster.image == null ? raster.bytes + 512 : 0,
      )) {
        _unavailable.add(item.identity);
        continue;
      }
      raster = rasters.get(content);
      if (raster == null) continue;
      final image = rasters.rasterize(content, raster);
      if (image == null) {
        _unavailable.add(item.identity);
        continue;
      }
      final active = _ActiveRaster(item, image.clone(), backing: raster);
      _active[item.identity] = active;
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
    if (active.released) return null;
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
      selfSend: content.selfSend,
    );
  }

  DanmakuDisplaySnapshot<T>? hitTest(Offset point) {
    if (!_displayClip.contains(point)) return null;
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
    if (active.released) return;
    paint.color = const Color(0xffffffff);
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
      ..clipRect((Offset.zero & size).intersect(_displayClip));
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
      if (frame == null || active.released) continue;
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
    // 数据域失效撤回已准备的资源，最新显示配置继续作为下一帧目标。
    final target = _configuration;
    if (target != null) {
      target.dispose();
      target.prepared.clear();
      target.bytes = 0;
    }
    _interactionEpoch++;
    _held = null;
    for (final active in _active.values) {
      active.release();
    }
    _active.clear();
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
    _configuration?.dispose();
    _configuration = null;
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
