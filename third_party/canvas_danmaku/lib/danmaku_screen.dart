import 'package:canvas_danmaku/display_limits.dart';
import 'package:canvas_danmaku/hit_test.dart';
import 'dart:math';
import 'dart:ui' show FlutterView;
import 'package:flutter/foundation.dart' show ValueListenable;

import 'package:canvas_danmaku/geometry.dart';
import 'package:canvas_danmaku/danmaku_controller.dart';
import 'package:canvas_danmaku/frame_rate_ticker.dart';
import 'package:canvas_danmaku/models/danmaku_content_item.dart';
import 'package:canvas_danmaku/models/danmaku_item.dart';
import 'package:canvas_danmaku/models/danmaku_option.dart';
import 'package:canvas_danmaku/scroll_danmaku_painter.dart';
import 'package:canvas_danmaku/special_danmaku_painter.dart';
import 'package:canvas_danmaku/static_danmaku_painter.dart';
import 'package:canvas_danmaku/text_renderer.dart';
import 'package:material_ui/material_ui.dart';

class DanmakuScreen<T> extends StatefulWidget {
  // 创建Screen后返回控制器
  final ValueChanged<DanmakuController<T>> createdController;
  final DanmakuOption option;
  final Size size;
  final int frameRate;
  final ValueListenable<List<int>>? videoFrameTimings;
  final ValueListenable<bool>? videoDisplaySyncActive;

  const DanmakuScreen({
    super.key,
    required this.createdController,
    required this.option,
    required this.size,
    this.frameRate = 0,
    this.videoFrameTimings,
    this.videoDisplaySyncActive,
  });

  @override
  State<DanmakuScreen<T>> createState() => _DanmakuScreenState<T>();
}

class _DanmakuScreenState<T> extends State<DanmakuScreen<T>> {
  /// 视图宽度
  double _viewWidth = 0;
  double _viewHeight = 0;
  var _textRenderer = const DanmakuTextRenderer();

  /// 弹幕配置
  late DanmakuOption _option;

  /// 滚动弹幕
  final _scrollDanmakuItems = <List<DanmakuItem<T>>>[];
  final _scrollMotions = <DanmakuItem<T>, DanmakuTrajectory>{};

  /// 静态弹幕
  final _staticDanmakuItems = ListValueNotifier(<DanmakuItem<T>?>[]);
  bool _staticDanmakuDirty = false;

  /// 高级弹幕
  final _specialDanmakuItems = <DanmakuItem<T>>[];

  bool get _isEmpty =>
      _scrollDanmakuItems.every((list) => list.isEmpty) &&
      _staticDanmakuItems.value.nonNulls.isEmpty &&
      _specialDanmakuItems.isEmpty;

  /// 弹幕高度
  double _danmakuHeight = 0;

  /// 弹幕轨道数
  int _trackCount = 0;

  late final _random = Random();

  late final FrameRateTicker _ticker;
  FlutterView? _view;
  late final ValueNotifier<int> _notifier;
  final _scrollPaintTick = _PaintClock();
  final _specialPaintTick = _PaintClock();
  late int _lastTick = 0;

  /// 运行状态
  bool _running = true;

  @override
  void initState() {
    super.initState();
    _option = widget.option;

    _danmakuHeight = _calculateTrackHeight();

    _ticker = FrameRateTicker(_tick,
        frameRate: widget.frameRate,
        videoFrameTimings: widget.videoFrameTimings,
        videoDisplaySyncActive: widget.videoDisplaySyncActive,
        screenRefreshRate: () => _view?.display.refreshRate ?? 0);
    _notifier = ValueNotifier(0)..addListener(_refreshPaintClocks);

    widget.createdController(DanmakuController<T>(
      addDanmaku: _addDanmaku,
      updateOption: _updateOption,
      pause: _pause,
      resume: _resume,
      clear: _clear,
      getOption: () => _option,
      isRunning: () => _running,
      findDanmaku: findDanmaku,
      findSingleDanmaku: findSingleDanmaku,
      getTrackCount: () => _trackCount,
      getSchedulerDiagnostics: () => _ticker.diagnostics,
      scrollDanmaku: _scrollDanmakuItems,
      staticDanmaku: _staticDanmakuItems.value,
      specialDanmaku: _specialDanmakuItems,
    ));

    _init(widget.size);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _view = View.of(context);
    _ticker.muted = !TickerMode.valuesOf(context).enabled;
    final fontFamily = DefaultTextStyle.of(context).style.fontFamily;
    final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
    final fontChanged = fontFamily != _textRenderer.fontFamily;
    final densityChanged = devicePixelRatio != _textRenderer.devicePixelRatio;
    _textRenderer = DanmakuTextRenderer(
      fontFamily: fontFamily,
      devicePixelRatio: devicePixelRatio,
    );
    if (fontChanged || densityChanged) {
      for (final track in _scrollDanmakuItems) {
        for (final item in track) {
          item.invalidateImage();
        }
      }
      for (final item in _staticDanmakuItems.value.nonNulls) {
        item.invalidateImage();
      }
      for (final item in _specialDanmakuItems) {
        item.invalidateImage();
      }
    }
    if (fontChanged) {
      final trackHeight = _calculateTrackHeight();
      if (trackHeight != _danmakuHeight) {
        _clearTrackDanmakus();
        _danmakuHeight = trackHeight;
        _calcTracks();
      }
    }
    _updateNormalDanmaku(_notifier.value);
    if (fontChanged || densityChanged) {
      _refreshPaintClocks();
      _refreshStaticDanmaku();
    }
  }

  int _time = 0;
  int _normalTick = 0;
  void _refreshPaintClocks() {
    _scrollPaintTick.update(
        _notifier.value, _scrollDanmakuItems.any((track) => track.isNotEmpty));
    _specialPaintTick.update(_notifier.value, _specialDanmakuItems.isNotEmpty);
  }

  void _tick(Duration elapsed) {
    final tick = elapsed.inMilliseconds + _lastTick;
    _updateNormalDanmaku(tick);
    _notifier.value = tick;
    // 新增固定弹幕与运动图层共用本帧；首个 tick 为零时也要发布内容。
    if (_staticDanmakuDirty) _refreshStaticDanmaku();
    if (_time++ > 10) {
      _time = 0;
      _lazyTick(_notifier.value);
    }
  }

  void _updateNormalDanmaku(int tick) {
    for (var track = 0; track < _scrollDanmakuItems.length; track++) {
      for (final item in _scrollDanmakuItems[track]) {
        if (item.expired) continue;
        item.drawParagraphIfNeeded(_option.fontSize, _option.fontWeight,
            _option.strokeWidth, _textRenderer);
        final velocity = DanmakuGeometry.scrollVelocity(
            _viewWidth, item.width, _option.durationInMilliseconds,
            fixed: _option.scrollFixedVelocity);
        if (item.suspend) {
          _scrollMotions.remove(item);
          item.drawTick = tick;
          continue;
        }
        var motion = _scrollMotions[item];
        if (motion == null ||
            motion.velocity != velocity ||
            motion.width != item.width ||
            motion.height != item.height) {
          final start = (item.drawTick ?? tick).toDouble();
          motion = DanmakuTrajectory(
            startMs: start,
            endMs: start + (item.xPosition + item.width) / velocity,
            startX: item.xPosition,
            y: track * _danmakuHeight,
            width: item.width,
            height: item.height,
            velocity: velocity,
          );
          _scrollMotions[item] = motion;
        }
        item.xPosition = motion.xAt(tick.toDouble());
        item.expired =
            item.xPosition < -item.width || item.xPosition > _viewWidth;
        item.drawTick = tick;
      }
    }
    for (final item in _staticDanmakuItems.value.nonNulls) {
      item.drawParagraphIfNeeded(_option.fontSize, _option.fontWeight,
          _option.strokeWidth, _textRenderer);
      item.xPosition = (_viewWidth - item.width) / 2;
      if (item.suspend && item.drawTick != null) {
        item.drawTick = item.drawTick! + max(0, tick - _normalTick);
      }
      item.drawTick ??= tick;
    }
    _normalTick = tick;
  }

  void _refreshStaticDanmaku() {
    _staticDanmakuDirty = false;
    _staticDanmakuItems.refresh();
  }

  TextPainter get _textPainter => TextPainter(
        text: TextSpan(
          text: '弹幕',
          style: TextStyle(
            fontSize: _option.fontSize,
            fontWeight: FontWeight.values[_option.fontWeight],
            fontFamily: _textRenderer.fontFamily,
            height: _option.lineHeight,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

  double _calculateTrackHeight() {
    final configuredPainter = _textPainter;
    final configuredHeight = configuredPainter.height;
    configuredPainter.dispose();

    final normalPainter = TextPainter(
      text: TextSpan(
        text: '弹幕',
        style: TextStyle(
          fontSize: _option.fontSize,
          fontWeight: FontWeight.values[_option.fontWeight],
          fontFamily: _textRenderer.fontFamily,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final normalHeight = normalPainter.height + _option.strokeWidth;
    normalPainter.dispose();
    return max(configuredHeight, normalHeight);
  }

  @override
  void dispose() {
    _running = false;
    _ticker.dispose();
    _clearDanmakus();
    _notifier.dispose();
    _scrollPaintTick.dispose();
    _specialPaintTick.dispose();
    _staticDanmakuItems.dispose();
    super.dispose();
  }

  bool _handleNormalDanmaku(
    DanmakuContentItem<T> content,
    bool Function(int, double, double) canAdd, {
    bool scroll = false,
  }) {
    bool added = false;

    final paragraph = _textRenderer.generateParagraph(
      content: content,
      fontSize: _option.fontSize,
      fontWeight: _option.fontWeight,
    );

    final danmakuWidth = (content.selfSend
            ? paragraph.maxIntrinsicWidth + 4
            : paragraph.maxIntrinsicWidth) +
        _option.strokeWidth;
    final danmakuHeight = paragraph.height + _option.strokeWidth;
    final trackSpan = _trackSpan(danmakuHeight);
    final lastStartIndex = _trackCount - trackSpan;

    if (!scroll &&
        content.type != DanmakuItemType.scroll &&
        _option.static2Scroll &&
        danmakuWidth > _viewWidth) {
      paragraph.dispose();
      return false;
    }

    DanmakuItem<T> getItem() => DanmakuItem<T>(
        xPosition: _viewWidth,
        width: danmakuWidth,
        height: danmakuHeight,
        content: content,
        image: _textRenderer.recordDanmakuImage(
          contentParagraph: paragraph,
          content: content,
          fontSize: _option.fontSize,
          fontWeight: _option.fontWeight,
          strokeWidth: _option.strokeWidth,
        ));

    for (var i = 0; i <= lastStartIndex; i++) {
      final index =
          content.type == DanmakuItemType.bottom ? lastStartIndex - i : i;

      if (added = canAdd(index, danmakuWidth, danmakuHeight)) {
        final item = getItem();
        if (content.type == DanmakuItemType.scroll || scroll) {
          _scrollDanmakuItems[index].add(item);
        } else {
          item.xPosition = (_viewWidth - item.width) / 2;
          _staticDanmakuItems.value[index]?.dispose();
          _staticDanmakuItems.value[index] = item;
          _staticDanmakuDirty = true;
        }
        break;
      }
    }

    if (added) {
      if (_running && !_ticker.isActive) {
        _ticker.start();
      }
    } else if (trackSpan == 1 && lastStartIndex >= 0) {
      if (content.selfSend &&
          !_overlapsExpandedTrackDanmaku(0, danmakuWidth, danmakuHeight)) {
        _scrollDanmakuItems[0].add(getItem());
        added = true;
      } else if ((content.type == DanmakuItemType.scroll || scroll) &&
          _option.massiveMode) {
        final availableTracks = [
          for (var index = 0; index <= lastStartIndex; index++)
            if (!_overlapsExpandedTrackDanmaku(
                index, danmakuWidth, danmakuHeight))
              index,
        ];
        if (availableTracks.isNotEmpty) {
          _scrollDanmakuItems[
                  availableTracks[_random.nextInt(availableTracks.length)]]
              .add(getItem());
          added = true;
        }
      }
    }

    paragraph.dispose();
    return added;
  }

  /// 添加弹幕
  bool _addDanmaku(DanmakuContentItem<T> content) {
    if (!mounted) {
      return false;
    }

    if (!DanmakuDisplayLimits.canAdd(
      _specialDanmakuItems.length +
          _staticDanmakuItems.value.nonNulls.length +
          _scrollDanmakuItems.fold(0, (count, track) => count + track.length),
      _specialDanmakuItems.length,
      isSpecial: content.type == DanmakuItemType.special,
    )) {
      return false;
    }

    bool added;
    switch (content.type) {
      case DanmakuItemType.scroll:
        if (_option.hideScroll) return false;
        added = _handleNormalDanmaku(content, _scrollCanAddToTrack);
        break;
      case DanmakuItemType.top:
      case DanmakuItemType.bottom:
        if (_option.hideWhat(content.type)) return false;
        added = _handleNormalDanmaku(content, _staticCanAddToTrack);
        if (!added && _option.static2Scroll && !_option.hideScroll) {
          added =
              _handleNormalDanmaku(content, _scrollCanAddToTrack, scroll: true);
        }
        break;
      case DanmakuItemType.special:
        if (_option.hideSpecial) return false;
        added = true;
        final raster = _textRenderer.rasterizeSpecial(
          content: content as SpecialDanmakuContentItem,
          fontWeight: _option.fontWeight,
          strokeWidth: _option.strokeWidth,
        );
        _specialDanmakuItems.add(DanmakuItem<T>(
          width: raster.bounds.width,
          height: raster.bounds.height,
          content: content,
          image: raster.image,
          specialBounds: raster.bounds,
        ));
        if (_running && !_ticker.isActive) {
          _ticker.start();
        }
        break;
    }
    if (added && !_running) _updateNormalDanmaku(_notifier.value);
    return added;
  }

  /// 暂停
  void _pause() {
    if (!mounted) return;
    _running = false;
    if (_staticDanmakuDirty) _refreshStaticDanmaku();
    if (_ticker.isActive) {
      _lastTick = _notifier.value;
      _ticker.stop();
    }
  }

  /// 恢复
  void _resume() {
    if (!mounted) return;
    _running = true;
    if (!_isEmpty && !_ticker.isActive) {
      _ticker.start();
    }
    _refreshStaticDanmaku();
  }

  /// 清空弹幕
  void _clear() {
    if (!mounted) return;
    _clearDanmakus();
    if (_ticker.isActive) {
      // SchedulerBinding.instance.addPostFrameCallback(
      //   (_) => _ticker.stop(),
      // );
    } else {
      _notifier.refresh();
    }
  }

  /// 更新弹幕设置
  void _updateOption(DanmakuOption option) {
    final lineHeightChanged = option.lineHeight != _option.lineHeight;
    final fontSizeChanged = option.fontSize != _option.fontSize;
    final areaChanged = option.area != _option.area;
    final safeAreaChanged = option.safeArea != _option.safeArea;

    final clearScroll = option.hideScroll && !_option.hideScroll;

    final clearParagraph = fontSizeChanged ||
        option.fontWeight != _option.fontWeight ||
        option.strokeWidth != _option.strokeWidth;
    final clearTrackDanmakus = lineHeightChanged ||
        fontSizeChanged ||
        areaChanged ||
        safeAreaChanged ||
        clearParagraph;

    final needRestart = _ticker.isActive && clearScroll && clearParagraph;
    if (needRestart) {
      _lastTick = _notifier.value;
      _ticker.stop();
    }

    /// 需要隐藏弹幕时清理已有弹幕
    if (clearScroll) {
      for (var i in _scrollDanmakuItems) {
        for (var e in i) {
          _scrollMotions.remove(e);
          e.dispose();
        }
        i.clear();
      }
    }

    final clearTop = option.hideTop && !_option.hideTop;
    final clearBottom = option.hideBottom && !_option.hideBottom;
    if (clearTop || clearBottom) {
      _staticDanmakuItems.removeWhere((e) => e.needRemove(
            (clearTop && e.content.type == DanmakuItemType.top) ||
                (clearBottom && e.content.type == DanmakuItemType.bottom),
          ));
    }
    if (option.hideSpecial && !_option.hideSpecial) {
      for (var e in _specialDanmakuItems) {
        e.dispose();
      }
      _specialDanmakuItems.clear();
    }

    if (clearTrackDanmakus) {
      _clearTrackDanmakus();
    }

    /// 清理已经存在的 Paragraph 缓存
    if (clearParagraph) {
      for (var item in _specialDanmakuItems) {
        item.invalidateImage();
      }
    }

    // 配置变化更新绘制委托；动画时钟直接触发重绘。
    setState(() => _option = option);
    if (clearParagraph || lineHeightChanged) {
      _danmakuHeight = _calculateTrackHeight();
    }
    if (clearParagraph || lineHeightChanged || areaChanged || safeAreaChanged) {
      _calcTracks();
    }

    if (needRestart) {
      _ticker.start();
    } else {
      _notifier.refresh();
      _refreshStaticDanmaku();
    }
  }

  void _clearDanmakus() {
    _clearTrackDanmakus();
    for (var e in _specialDanmakuItems) {
      e.dispose();
    }
    _specialDanmakuItems.clear();
  }

  void _clearTrackDanmakus() {
    _scrollMotions.clear();
    for (var i in _scrollDanmakuItems) {
      for (var e in i) {
        e.dispose();
      }
      i.clear();
    }
    for (int i = 0; i < _trackCount; i++) {
      final item = _staticDanmakuItems[i];
      if (item != null) {
        item.dispose();
        _staticDanmakuItems[i] = null;
      }
    }
    _refreshStaticDanmaku();
  }

  DanmakuTrajectory _placement(
      double width, double height, int track, bool scrolling,
      {DanmakuItem<T>? item}) {
    final now = _notifier.value.toDouble();
    final frozen = item?.suspend ?? false;
    final velocity = scrolling && !frozen
        ? DanmakuGeometry.scrollVelocity(
            _viewWidth, width, _option.durationInMilliseconds,
            fixed: _option.scrollFixedVelocity)
        : 0.0;
    final x =
        item?.xPosition ?? (scrolling ? _viewWidth : (_viewWidth - width) / 2);
    final end = frozen
        ? double.infinity
        : scrolling
            ? now + (x + width) / velocity
            : (item?.drawTick?.toDouble() ?? now) +
                _option.staticDurationInMilliseconds;
    return DanmakuTrajectory(
        startMs: now,
        endMs: end,
        startX: x,
        y: track * _danmakuHeight,
        width: width,
        height: height,
        velocity: velocity);
  }

  bool _canPlace(int index, double width, double height, bool scrolling,
      {bool allowNormalOverlap = false}) {
    final candidate = _placement(width, height, index, scrolling);
    for (var track = 0; track < _trackCount; track++) {
      final fixed = _staticDanmakuItems[track];
      if (fixed != null &&
          !fixed.expired &&
          DanmakuGeometry.blocks(candidate,
              _placement(fixed.width, fixed.height, track, false, item: fixed),
              trackHeight: _danmakuHeight,
              viewWidth: _viewWidth,
              candidateScrolling: scrolling,
              existingScrolling: false,
              sameTrack: index == track,
              allowNormalOverlap: allowNormalOverlap,
              padding: 1 / _textRenderer.devicePixelRatio)) {
        return false;
      }
      for (final item in _scrollDanmakuItems[track]) {
        if (item.expired) continue;
        if (DanmakuGeometry.blocks(candidate,
            _placement(item.width, item.height, track, true, item: item),
            trackHeight: _danmakuHeight,
            viewWidth: _viewWidth,
            candidateScrolling: scrolling,
            existingScrolling: true,
            sameTrack: index == track,
            allowNormalOverlap: allowNormalOverlap,
            padding: 1 / _textRenderer.devicePixelRatio)) {
          return false;
        }
      }
    }
    return true;
  }

  bool _scrollCanAddToTrack(int index, double width, double height) =>
      _canPlace(index, width, height, true);

  bool _staticCanAddToTrack(int index, double width, double height) =>
      _canPlace(index, width, height, false);

  int _trackSpan(double height) =>
      DanmakuGeometry.trackSpan(height, _danmakuHeight);

  bool _overlapsExpandedTrackDanmaku(int index, double width, double height) =>
      !_canPlace(index, width, height, true, allowNormalOverlap: true);

  @pragma("vm:prefer-inline")
  void _lazyTick(int tick) {
    for (final track in _scrollDanmakuItems) {
      track.removeWhereUnsafe((item) {
        if (!item.expired) return false;
        _scrollMotions.remove(item);
        item.dispose();
        return true;
      });
    }
    // 移除静态弹幕
    _staticDanmakuItems.removeWhere((item) => item.needRemove(!item.suspend &&
        item.drawTick != null &&
        (tick - item.drawTick!) >= _option.staticDurationInMilliseconds));
    // 移除高级弹幕
    _specialDanmakuItems.removeWhereUnsafe((item) => item.needRemove(
        item.expired ||
            (item.drawTick != null &&
                (tick - item.drawTick!) >=
                    (item.content as SpecialDanmakuContentItem).duration)));
    // 暂停动画
    if (_isEmpty && _ticker.isActive) {
      _lastTick = tick;
      _ticker.stop();
    }
  }

  void _calcTracks() {
    final area = _viewHeight * _option.area;
    int newTrackCount = max(0, area ~/ _danmakuHeight);

    /// 为字幕留出余量
    if (_option.safeArea && _option.area == 1.0) {
      newTrackCount = max(0, newTrackCount - 1);
    }
    if (newTrackCount != _trackCount) {
      if (_trackCount > 0) {
        _clearTrackDanmakus();
      }
      // 丢弃超出屏幕范围的弹幕
      _staticDanmakuItems.value.length = newTrackCount;
      _scrollDanmakuItems.changeLength(newTrackCount);
      _trackCount = newTrackCount;
    }
  }

  @override
  void didUpdateWidget(DanmakuScreen<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    _ticker.frameRate = widget.frameRate;
    _ticker.videoFrameTimings = widget.videoFrameTimings;
    _ticker.videoDisplaySyncActive = widget.videoDisplaySyncActive;
    if (oldWidget.size != widget.size) {
      _init(widget.size);
    }
  }

  void _init(Size size) {
    final viewWidth = size.width;
    final viewHeight = size.height;
    if (_viewWidth != viewWidth) {
      _viewWidth = viewWidth;
    }
    if (_viewHeight != viewHeight) {
      _viewHeight = viewHeight;
      _calcTracks();
    }
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Stack(
        children: [
          RepaintBoundary.wrap(
            CustomPaint(
              willChange: _running,
              painter: ScrollDanmakuPainter(
                length:
                    _scrollDanmakuItems.fold<int>(0, (p, n) => p + n.length),
                trackHeight: _danmakuHeight,
                danmakuItems: _scrollDanmakuItems,
                fontSize: _option.fontSize,
                fontWeight: _option.fontWeight,
                strokeWidth: _option.strokeWidth,
                running: _running,
                tick: _notifier.value,
                tickSource: _scrollPaintTick,
              ),
              size: widget.size,
            ),
            0,
          ),
          RepaintBoundary.wrap(
            ValueListenableBuilder(
              valueListenable: _staticDanmakuItems,
              builder: (context, value, child) {
                return CustomPaint(
                  painter: StaticDanmakuPainter(
                    // 同帧等数量替换也需要通过列表通知重绘内容。
                    repaint: _staticDanmakuItems,
                    count: value.nonNulls.length,
                    trackHeight: _danmakuHeight,
                    danmakuItems: value,
                    fontSize: _option.fontSize,
                    fontWeight: _option.fontWeight,
                    strokeWidth: _option.strokeWidth,
                  ),
                  size: widget.size,
                );
              },
            ),
            1,
          ),
          RepaintBoundary.wrap(
            CustomPaint(
              willChange: _running,
              painter: SpecialDanmakuPainter(
                length: _specialDanmakuItems.length,
                danmakuItems: _specialDanmakuItems,
                textRenderer: _textRenderer,
                fontSize: _option.fontSize,
                fontWeight: _option.fontWeight,
                strokeWidth: _option.strokeWidth,
                running: _running,
                tick: _notifier.value,
                tickSource: _specialPaintTick,
              ),
              size: widget.size,
            ),
            2,
          ),
        ],
      ),
    );
  }

  Iterable<(double, DanmakuItem<T>)> findDanmaku(Offset position) =>
      hitTestDanmaku(
          position: position,
          trackHeight: _danmakuHeight,
          fixed: _staticDanmakuItems.value,
          scrolling: _scrollDanmakuItems);

  (double, DanmakuItem<T>)? findSingleDanmaku(Offset position) =>
      findDanmaku(position).firstOrNull;
}

typedef ListValueNotifier<T extends Object> = ValueNotifier<List<T?>>;

/// 空图层停止逐帧重绘；内容清空时再通知一次以擦除上一帧。
class _PaintClock extends ValueNotifier<int> {
  _PaintClock() : super(0);
  bool _hadItems = false;

  void update(int tick, bool hasItems) {
    if (hasItems || _hadItems) {
      if (value == tick) {
        notifyListeners();
      } else {
        value = tick;
      }
    }
    _hadItems = hasItems;
  }
}

extension<T extends Object> on ListValueNotifier<T> {
  @pragma("vm:prefer-inline")
  T? operator [](int index) {
    return value[index];
  }

  @pragma("vm:prefer-inline")
  void operator []=(int index, T? item) {
    value[index] = item;
  }

  void removeWhere(bool Function(T element) test) {
    bool remove = false;
    for (int i = 0; i < value.length; i++) {
      final item = value[i];
      if (item != null && test(item)) {
        value[i] = null;
        remove = true;
      }
    }
    if (remove) {
      refresh();
    }
  }
}

extension ValueNotifierExt<T> on ValueNotifier<T> {
  @pragma("vm:prefer-inline")
  void refresh() {
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    notifyListeners();
  }
}

extension<E> on List<E> {
  bool removeWhereUnsafe(bool Function(E) test) {
    int write = 0;
    final length = this.length;
    for (int read = 0; read < length; read++) {
      final element = this[read];
      if (!test(element)) {
        if (write < read) this[write] = element;
        write++;
      }
    }
    if (length != write) {
      this.length = write;
      return true;
    }
    return false;
  }
}

extension<T> on List<List<T>> {
  @pragma("vm:prefer-inline")
  void changeLength(int length) {
    if (length > this.length) {
      addAll(Iterable.generate(length - this.length, (_) => <T>[]));
    } else {
      this.length = length;
    }
  }
}
