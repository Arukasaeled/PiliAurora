import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter/foundation.dart';
import 'package:pili_aurora/pages/danmaku/danmaku_model.dart';
import 'package:pili_aurora/pages/danmaku/interaction.dart';

/// 挂载处注册显示操作；来源和显示资源仍由各自实例持有。
class DanmakuDisplayBinding {
  const DanmakuDisplayBinding({
    required this.interaction,
    required this.clear,
    this.echo,
    this.seeking,
    this.remove,
  });

  final DanmakuInteractionHandle<DanmakuExtra> Function() interaction;
  final VoidCallback clear;
  final VoidCallback? seeking;
  final void Function(DanmakuContentItem<DanmakuExtra>, int mediaUs)? echo;
  final void Function(Object identity)? remove;
}
