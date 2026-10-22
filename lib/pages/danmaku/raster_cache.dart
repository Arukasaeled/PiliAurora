import 'dart:ui' as ui;
import 'dart:math' as math;

import 'package:flutter/painting.dart' as painting;

import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:canvas_danmaku/text_renderer.dart' as canvas_danmaku;

const danmakuActiveRasterBytes =
    int.fromEnvironment(
      'WINDOWS_DANMAKU_MAX_ACTIVE_BYTES_MIB',
      defaultValue: 96,
    ) *
    1024 *
    1024;

typedef DanmakuRasterKey = (String, int, bool, bool, int?, double, Object?);

class _InlineRasterKey {
  _InlineRasterKey(List<DanmakuInlineImage> images)
    : entries = [
        for (final image in images)
          (image.placeholder, image.width, image.height, image.image),
      ];
  final List<(String, double, double, ui.Image)> entries;
  @override
  int get hashCode => Object.hashAll(entries);
  @override
  bool operator ==(Object other) =>
      other is _InlineRasterKey &&
      entries.length == other.entries.length &&
      entries.indexed.every((entry) => entry.$2 == other.entries[entry.$1]);
}

class DanmakuRaster {
  DanmakuRaster(this.width, this.height, this.bytes, this.paragraph);

  final double width;
  final double height;
  final int bytes;
  ui.Paragraph? paragraph;
  ui.Image? image;

  void dispose() {
    paragraph?.dispose();
    image?.dispose();
    paragraph = null;
    image = null;
  }
}

class DanmakuRasterCache {
  DanmakuRasterCache({
    required this.option,
    required this.devicePixelRatio,
    this.fontFamily,
    this.maxEntries = 512,
    this.maxBytes = 16 * 1024 * 1024,
    this.maxItemBytes = 2 * 1024 * 1024,
  }) : assert(maxEntries > 0),
       assert(maxBytes > 0),
       assert(maxItemBytes > 0);

  DanmakuOption option;
  double devicePixelRatio;
  String? fontFamily;
  canvas_danmaku.DanmakuTextRenderer? _textRenderer;
  canvas_danmaku.DanmakuTextRenderer get textRenderer {
    final current = _textRenderer;
    if (current != null &&
        current.devicePixelRatio == devicePixelRatio &&
        current.fontFamily == fontFamily) {
      return current;
    }
    return _textRenderer = canvas_danmaku.DanmakuTextRenderer(
      devicePixelRatio: devicePixelRatio,
      fontFamily: fontFamily,
    );
  }

  double measureTrackHeight() {
    final painter = painting.TextPainter(
      text: painting.TextSpan(
        text: '弹幕',
        style: painting.TextStyle(
          fontSize: option.fontSize,
          fontWeight: ui.FontWeight.values[option.fontWeight],
          fontFamily: fontFamily,
          height: option.lineHeight,
        ),
      ),
      textDirection: ui.TextDirection.ltr,
    )..layout();
    final paragraph = textRenderer.generateParagraph(
      content: DanmakuContentItem('弹幕'),
      fontSize: option.fontSize,
      fontWeight: option.fontWeight,
    );
    final height = math.max(
      painter.height,
      paragraph.height + option.strokeWidth,
    );
    painter.dispose();
    paragraph.dispose();
    return height;
  }

  final int maxEntries;
  final int maxBytes;
  final int maxItemBytes;
  final _entries = <DanmakuRasterKey, DanmakuRaster>{};
  int bytes = 0;
  int hits = 0;
  int layouts = 0;
  int rasterizations = 0;
  int evictions = 0;
  int evictionsByBytes = 0;
  int evictionsByEntries = 0;
  int evictedLayouts = 0;
  int evictedImages = 0;
  // 淘汰图片的账面字节；共享 backing 的实际释放量另计。
  int evictedImageBytes = 0;

  int get length => _entries.length;

  /// 布局或图片均可直接复用；查询不改变 LRU 顺序。
  bool isPrepared(DanmakuContentItem content) =>
      _entries.containsKey(keyOf(content));

  bool isRasterized(DanmakuContentItem content) =>
      _entries[keyOf(content)]?.image != null;

  static DanmakuRasterKey keyOf(DanmakuContentItem content) => (
    content.text,
    content.color.toARGB32(),
    content.isColorful,
    content.selfSend,
    content.count,
    content.fontSizeScale,
    content.inlineImages.isEmpty
        ? null
        : _InlineRasterKey(content.inlineImages),
  );

  ui.Image? rasterize(DanmakuContentItem content, DanmakuRaster entry) {
    if (entry.image == null) {
      final paragraph = entry.paragraph;
      if (paragraph == null) return null;

      entry.image = textRenderer.recordDanmakuImage(
        contentParagraph: paragraph,
        content: content,
        fontSize: option.fontSize,
        fontWeight: option.fontWeight,
        strokeWidth: option.strokeWidth,
      );
      paragraph.dispose();
      entry.paragraph = null;
      bytes += entry.bytes;
      rasterizations++;
    }
    _trim();
    return entry.image;
  }

  DanmakuRaster? get(DanmakuContentItem content, {bool rasterize = false}) {
    final key = keyOf(content);
    var entry = _entries.remove(key);
    if (entry == null) {
      final paragraph = textRenderer.generateParagraph(
        content: content,
        fontSize: option.fontSize,
        fontWeight: option.fontWeight,
      );
      layouts++;
      final width =
          paragraph.maxIntrinsicWidth +
          option.strokeWidth +
          (content.selfSend ? 4 : 0);
      final height = paragraph.height + option.strokeWidth;
      final pixelWidth = width * devicePixelRatio;
      final pixelHeight = height * devicePixelRatio;
      if (!pixelWidth.isFinite ||
          !pixelHeight.isFinite ||
          pixelWidth <= 0 ||
          pixelHeight <= 0 ||
          pixelWidth > 4096 ||
          pixelHeight > 4096) {
        paragraph.dispose();
        return null;
      }
      final imageBytes = pixelWidth.ceil() * pixelHeight.ceil() * 4;
      if (imageBytes > maxItemBytes || imageBytes > maxBytes) {
        paragraph.dispose();
        return null;
      }
      entry = DanmakuRaster(width, height, imageBytes, paragraph);
    } else {
      hits++;
    }
    _entries[key] = entry;
    if (rasterize) {
      this.rasterize(content, entry);
    } else {
      _trim();
    }
    return entry;
  }

  void _trim() {
    while (_entries.length > maxEntries || bytes > maxBytes) {
      // 两个条件同时超限时分别记录，原因计数不要求互斥。
      if (bytes > maxBytes) evictionsByBytes++;
      if (_entries.length > maxEntries) evictionsByEntries++;
      final oldest = _entries.remove(_entries.keys.first)!;
      if (oldest.image != null) {
        bytes -= oldest.bytes;
        evictedImages++;
        evictedImageBytes += oldest.bytes;
      } else {
        evictedLayouts++;
      }
      oldest.dispose();
      evictions++;
    }
  }

  void clear() {
    for (final entry in _entries.values) {
      entry.dispose();
    }
    _entries.clear();
    bytes = 0;
  }
}
