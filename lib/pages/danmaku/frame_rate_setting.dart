import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:hive_ce/hive.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';
import 'package:pili_aurora/utils/storage_pref.dart';

/// 帧率变更需要通知正在播放的弹幕屏幕，保留其控制器和现有弹幕。
class DanmakuFrameRateSetting extends StatefulWidget {
  const DanmakuFrameRateSetting({super.key, required this.builder});

  final Widget Function(BuildContext context, int frameRate) builder;

  @override
  State<DanmakuFrameRateSetting> createState() =>
      _DanmakuFrameRateSettingState();
}

class _DanmakuFrameRateSettingState extends State<DanmakuFrameRateSetting> {
  late final StreamSubscription<BoxEvent> _subscription;

  @override
  void initState() {
    super.initState();
    _subscription = GStorage.setting
        .watch(key: SettingBoxKey.danmakuFrameRate)
        .listen((_) {
          if (mounted) setState(() {});
        });
  }

  @override
  Widget build(BuildContext context) =>
      widget.builder(context, Pref.danmakuFrameRate);

  @override
  void dispose() {
    _subscription.cancel();
    super.dispose();
  }
}
