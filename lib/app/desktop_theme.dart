import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/common/assets.dart';
import 'package:window_manager/window_manager.dart';

/// 根节点同步窗口外观，主窗口和独立播放窗口共用。
class DesktopWindowTheme extends StatefulWidget {
  const DesktopWindowTheme({super.key, required this.child});

  final Widget child;

  @override
  State<DesktopWindowTheme> createState() => _DesktopWindowThemeState();
}

class _DesktopWindowThemeState extends State<DesktopWindowTheme> {
  Brightness? _brightness;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final brightness = Theme.of(context).brightness;
    if (_brightness == brightness) return;
    _brightness = brightness;
    unawaited(windowManager.setBrightness(brightness));
    if (Platform.isWindows) {
      unawaited(
        windowManager.setIcon(Assets.themed(Assets.logoIco, brightness)),
      );
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
