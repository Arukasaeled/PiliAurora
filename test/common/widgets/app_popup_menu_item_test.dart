import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/common/widgets/app_menu_theme.dart';
import 'package:pili_aurora/common/widgets/app_popup_menu_item.dart';

void main() {
  testWidgets('浮层菜单与内部选项保持同心圆角', (tester) async {
    final colors = ColorScheme.fromSeed(
      seedColor: const Color(0xFF5CB67B),
    );
    int? selected;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: colors,
          popupMenuTheme: AppMenuTheme.popupMenuThemeData(colors),
        ),
        home: Scaffold(
          body: PopupMenuButton<int>(
            onSelected: (value) => selected = value,
            itemBuilder: (_) => const [
              AppPopupMenuItem(
                value: 0,
                selected: true,
                child: Text('关闭字幕'),
              ),
              AppPopupMenuItem(value: 1, child: Text('English')),
            ],
            child: const Text('打开菜单'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开菜单'));
    await tester.pumpAndSettle();

    final roundedMaterials = tester
        .widgetList<Material>(find.byType(Material))
        .where((material) => material.shape is RoundedRectangleBorder)
        .toList();
    final radii = roundedMaterials
        .map(
          (material) =>
              (material.shape! as RoundedRectangleBorder).borderRadius,
        )
        .toList();

    expect(
      radii,
      contains(BorderRadius.circular(AppMenuTheme.menuRadius)),
    );
    expect(
      radii,
      contains(BorderRadius.circular(AppMenuTheme.itemRadius)),
    );
    expect(
      AppMenuTheme.itemRadius,
      AppMenuTheme.menuRadius - AppMenuTheme.menuPadding,
    );
    expect(
      roundedMaterials.any(
        (material) => material.color == AppMenuTheme.selectedBackground(colors),
      ),
      isTrue,
    );

    await tester.tap(find.text('English'));
    await tester.pumpAndSettle();
    expect(selected, 1);
  });
}
