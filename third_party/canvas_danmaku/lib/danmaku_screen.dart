import 'dart:math';
import 'dart:ui' show FlutterView;
import 'package:flutter/foundation.dart' show ValueListenable;

import 'package:canvas_danmaku/danmaku_controller.dart';
import 'package:canvas_danmaku/frame_rate_ticker.dart';
import 'package:canvas_danmaku/models/danmaku_content_item.dart';
import 'package:canvas_danmaku/models/danmaku_item.dart';
import 'package:canvas_danmaku/models/danmaku_option.dart';
import 'package:canvas_danmaku/scroll_danmaku_painter.dart';
import 'package:canvas_danmaku/special_danmaku_painter.dart';
import 'package:canvas_danmaku/static_danmaku_painter.dart';
import 'package:canvas_danmaku/utils/utils.dart';
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
  double devicePixelRatio = 1;

  /// 弹幕配置
  late DanmakuOption _option;

  /// 滚动弹幕
  final _scrollDanmakuItems = <List<DanmakuItem<T>>>[];

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

  /// 滚动弹幕速度或时间，负号表示速度
  double _scrollVelocityOrDuration = 0;

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
    if (!_option.scrollFixedVelocity) {
      _scrollVelocityOrDuration = _option.durationInMilliseconds;
    }
    DmUtils.updateSelfSendPaint(_option.strokeWidth);

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
    if (fontFamily != DmUtils.fontFamily) {
      DmUtils.fontFamily = fontFamily;
      final trackHeight = _calculateTrackHeight();
      if (trackHeight != _danmakuHeight) {
        _clearTrackDanmakus();
        _danmakuHeight = trackHeight;
        _calcTracks();
      }
    }

    final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
    DmUtils.devicePixelRatio = devicePixelRatio;
    if (devicePixelRatio > this.devicePixelRatio) {
      for (var i in _scrollDanmakuItems) {
        for (var e in i) {
          e.dispose();
        }
      }
      for (var e in _staticDanmakuItems.value) {
        e?.dispose();
      }
      for (var item in _specialDanmakuItems) {
        item.dispose();
      }
      this.devicePixelRatio = devicePixelRatio;
    }
  }

  int _time = 0;
  void _refreshPaintClocks() {
    _scrollPaintTick.update(
        _notifier.value, _scrollDanmakuItems.any((track) => track.isNotEmpty));
    _specialPaintTick.update(_notifier.value, _specialDanmakuItems.isNotEmpty);
  }

  void _tick(Duration elapsed) {
    _notifier.value = elapsed.inMilliseconds + _lastTick;
    // 新增固定弹幕与运动图层共用本帧；首个 tick 为零时也要发布内容。
    if (_staticDanmakuDirty) _refreshStaticDanmaku();
    if (_time++ > 10) {
      _time = 0;
      _lazyTick(_notifier.value);
    }
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
            fontFamily: DmUtils.fontFamily,
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
          fontFamily: DmUtils.fontFamily,
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

    final paragraph = DmUtils.generateParagraph(
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
      return false;
    }

    DanmakuItem<T> getItem() => DanmakuItem<T>(
        xPosition: _viewWidth,
        width: danmakuWidth,
        height: danmakuHeight,
        content: content,
        image: DmUtils.recordDanmakuImage(
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
          !_overlapsExpandedTrackDanmaku(0, danmakuHeight)) {
        _scrollDanmakuItems[0].add(getItem());
        added = true;
      } else if ((content.type == DanmakuItemType.scroll || scroll) &&
          _option.massiveMode) {
        final availableTracks = [
          for (var index = 0; index <= lastStartIndex; index++)
            if (!_overlapsExpandedTrackDanmaku(index, danmakuHeight)) index,
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
        _specialDanmakuItems.add(
          DanmakuItem<T>(
              width: 0,
              height: 0,
              content: content,
              image: DmUtils.recordSpecialDanmakuImg(
                content: content as SpecialDanmakuContentItem,
                fontWeight: _option.fontWeight,
                strokeWidth: _option.strokeWidth,
              )),
        );
        if (_running && !_ticker.isActive) {
          _ticker.start();
        }
        break;
    }
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
    if (option.durationInMilliseconds != _option.durationInMilliseconds ||
        option.scrollFixedVelocity != _option.scrollFixedVelocity) {
      _scrollVelocityOrDuration = option.scrollFixedVelocity
          ? -_viewWidth / option.durationInMilliseconds
          : option.durationInMilliseconds;
    }

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
        item.dispose();
      }
    }

    // 配置变化更新绘制委托；动画时钟直接触发重绘。
    setState(() => _option = option);
    if (clearParagraph || lineHeightChanged) {
      _danmakuHeight = _calculateTrackHeight();
    }
    if (clearParagraph) {
      DmUtils.updateSelfSendPaint(option.strokeWidth);
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

  /// 确定滚动弹幕是否可以添加
  bool _scrollCanAddToTrack(
    int index,
    double newDanmakuWidth,
    double newDanmakuHeight,
  ) {
    final top = index * _danmakuHeight;
    final bottom = top + newDanmakuHeight;
    final expanded = _isExpanded(newDanmakuHeight);

    for (var track = 0; track < _trackCount; track++) {
      final item = _staticDanmakuItems[track];
      if (item != null &&
          (expanded || _isExpanded(item.height)) &&
          _verticalOverlap(top, bottom, track * _danmakuHeight, item.height)) {
        return false;
      }
    }

    for (var track = 0; track < _trackCount; track++) {
      final trackTop = track * _danmakuHeight;
      final items = _scrollDanmakuItems[track];
      final last = track == index ? items.lastOrNull : null;
      for (final item in items) {
        if (!_verticalOverlap(top, bottom, trackTop, item.height)) continue;
        if ((expanded || _isExpanded(item.height)) &&
            !_scrollItemCanFollow(item, newDanmakuWidth)) {
          return false;
        }
        if (identical(item, last) &&
            !_isExpanded(item.height) &&
            !_scrollItemCanFollow(item, newDanmakuWidth)) {
          return false;
        }
      }
    }
    return true;
  }

  bool _scrollItemCanFollow(DanmakuItem<T> item, double newDanmakuWidth) {
    // 首先保证进入屏幕时不发生重叠
    final right = item.xPosition + item.width;
    if (_viewWidth < right) {
      return false;
    }
    // 其次保证知道移出屏幕前不与速度慢的弹幕(弹幕宽度较小)发生重叠
    if (!_option.scrollFixedVelocity && item.width < newDanmakuWidth) {
      // (1 - ((_viewWidth - item.xPosition) / (item.width + _viewWidth))) > ((_viewWidth) / (_viewWidth + newDanmakuWidth))
      if (right * newDanmakuWidth >
          _viewWidth * (_viewWidth - item.xPosition)) {
        return false;
      }
    }
    return true;
  }

  /// 确定静态弹幕是否可以添加
  bool _staticCanAddToTrack(int index, double _, double newDanmakuHeight) {
    final top = index * _danmakuHeight;
    final bottom = top + newDanmakuHeight;
    final expanded = _isExpanded(newDanmakuHeight);
    for (var track = 0; track < _trackCount; track++) {
      final item = _staticDanmakuItems[track];
      final trackTop = track * _danmakuHeight;
      if (item != null &&
          _verticalOverlap(top, bottom, trackTop, item.height) &&
          (expanded || _isExpanded(item.height) || track == index)) {
        return false;
      }

      for (final scrollItem in _scrollDanmakuItems[track]) {
        if (_verticalOverlap(top, bottom, trackTop, scrollItem.height) &&
            (expanded || _isExpanded(scrollItem.height))) {
          return false;
        }
      }
    }
    return true;
  }

  int _trackSpan(double height) => (height / _danmakuHeight).ceil();

  bool _isExpanded(double height) => height > _danmakuHeight;

  bool _overlapsExpandedTrackDanmaku(int index, double height) {
    final top = index * _danmakuHeight;
    final bottom = top + height;
    for (var track = 0; track < _trackCount; track++) {
      final trackTop = track * _danmakuHeight;
      final staticItem = _staticDanmakuItems[track];
      if (staticItem != null &&
          _isExpanded(staticItem.height) &&
          _verticalOverlap(top, bottom, trackTop, staticItem.height)) {
        return true;
      }
      for (final item in _scrollDanmakuItems[track]) {
        if (_isExpanded(item.height) &&
            _verticalOverlap(top, bottom, trackTop, item.height)) {
          return true;
        }
      }
    }
    return false;
  }

  bool _verticalOverlap(
    double top,
    double bottom,
    double otherTop,
    double otherHeight,
  ) =>
      top < otherTop + otherHeight && otherTop < bottom;

  @pragma("vm:prefer-inline")
  void _lazyTick(int tick) {
    // 移除屏幕外滚动弹幕
    for (var i in _scrollDanmakuItems) {
      i.removeWhereUnsafe((item) => item.needRemove(item.expired ||
          // `paint()` is skipped when `opacity` is `0`, `expired` is always `false`
          (!item.suspend &&
              item.drawTick != null &&
              (tick - item.drawTick!) >= _option.durationInMilliseconds)));
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
      if (_option.scrollFixedVelocity) {
        _scrollVelocityOrDuration =
            -_viewWidth / _option.durationInMilliseconds;
      }
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
                durationInMilliseconds: _scrollVelocityOrDuration,
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
                    staticDurationInMilliseconds:
                        _option.staticDurationInMilliseconds,
                    fontSize: _option.fontSize,
                    fontWeight: _option.fontWeight,
                    strokeWidth: _option.strokeWidth,
                    tick: _notifier.value,
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

  Iterable<(double, DanmakuItem<T>)> findDanmaku(Offset position) sync* {
    for (var index = 0; index < _trackCount; index++) {
      final trackHeight = index * _danmakuHeight;
      final item = _staticDanmakuItems[index];
      if (item != null && _containsPoint(item, trackHeight, position)) {
        yield (trackHeight, item);
      }

      for (final item in _scrollDanmakuItems[index].reversed) {
        if (_containsPoint(item, trackHeight, position)) {
          yield (trackHeight, item);
        }
      }
    }
  }

  (double, DanmakuItem<T>)? findSingleDanmaku(Offset position) {
    for (var index = 0; index < _trackCount; index++) {
      final trackHeight = index * _danmakuHeight;
      final item = _staticDanmakuItems[index];
      if (item != null && _containsPoint(item, trackHeight, position)) {
        return (trackHeight, item);
      }

      for (final item in _scrollDanmakuItems[index].reversed) {
        if (_containsPoint(item, trackHeight, position)) {
          return (trackHeight, item);
        }
      }
    }
    return null;
  }

  bool _containsPoint(
    DanmakuItem<T> item,
    double trackTop,
    Offset position,
  ) =>
      trackTop <= position.dy &&
      position.dy <= trackTop + item.height &&
      item.xPosition <= position.dx &&
      position.dx <= item.xPosition + item.width;
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
