import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/app/desktop_theme.dart';
import 'package:pili_aurora/common/assets.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('根主题更新 Windows 窗口图标，不依赖主页或托盘', (tester) async {
    const channel = MethodChannel('window_manager');
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    final brightness = ValueNotifier(Brightness.light);
    addTearDown(brightness.dispose);
    await tester.pumpWidget(
      ValueListenableBuilder(
        valueListenable: brightness,
        builder: (context, value, child) => MaterialApp(
          theme: ThemeData(brightness: value),
          home: const DesktopWindowTheme(child: SizedBox()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (final value in [Brightness.light, Brightness.dark, Brightness.light]) {
      brightness.value = value;
      await tester.pumpAndSettle();
      final icon = calls.lastWhere((call) => call.method == 'setIcon');
      final path = (icon.arguments as Map)['iconPath'] as String;
      expect(
        path.replaceAll('\\', '/'),
        endsWith(Assets.themed(Assets.logoIco, value)),
      );
    }
    final count = calls.length;
    await tester.pump();
    expect(calls.length, count);
    expect(tester.takeException(), isNull);
  }, skip: !Platform.isWindows);
}
