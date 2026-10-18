import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/common/widgets/app_menu_theme.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('弹出菜单文字在 $brightness 主题下继承表面文字色', (tester) async {
      final colors = ColorScheme.fromSeed(
        seedColor: const Color(0xFF5CB67B),
        brightness: brightness,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            colorScheme: colors,
            popupMenuTheme: AppMenuTheme.popupMenuThemeData(colors),
          ),
          home: Scaffold(
            body: PopupMenuButton<int>(
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: 0,
                  child: Text('可用', style: TextStyle(fontSize: 13)),
                ),
                PopupMenuItem(
                  value: 1,
                  enabled: false,
                  child: Text('不可用', style: TextStyle(fontSize: 13)),
                ),
              ],
              child: const Text('打开菜单'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('打开菜单'));
      await tester.pumpAndSettle();

      expect(
        DefaultTextStyle.of(tester.element(find.text('可用'))).style.color,
        colors.onSurface,
      );
      expect(
        DefaultTextStyle.of(tester.element(find.text('不可用'))).style.color,
        colors.onSurface.withValues(alpha: 0.54),
      );
    });
  }
}
