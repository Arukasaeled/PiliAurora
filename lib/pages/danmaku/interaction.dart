import 'package:flutter/painting.dart';

class DanmakuDisplaySnapshot<T> {
  const DanmakuDisplaySnapshot({
    required this.identity,
    required this.text,
    required this.extra,
    required this.bounds,
    required this.selectable,
    required this.selected,
  });
  final Object identity;
  final String text;
  final T? extra;
  final Rect bounds;
  final bool selectable;
  final bool selected;
}

/// 句柄绑定显示实例的生命周期，活动对象和图片由显示模块持有。
/// 选择与解除在最近一次呈现的媒体时刻生效。
abstract interface class DanmakuInteractionHandle<T> {
  bool get isValid;
  List<DanmakuDisplaySnapshot<T>> get snapshot;
  DanmakuDisplaySnapshot<T>? hitTest(Offset point);
  bool select(Object identity);
  bool clearSelection();
}
