import 'package:material_ui/material_ui.dart';

/// 全局菜单表面与选择字段的共用视觉参数。
abstract final class AppMenuTheme {
  static const double menuRadius = 16;
  static const double menuPadding = 6;
  // 内项圆角按外圆角收进一个 padding，保证两层弧线同心。
  static const double itemRadius = menuRadius - menuPadding;
  static const double itemHeight = 37;
  static const double selectWidth = 128;
  static const double selectMenuWidth = 252;
  static const double selectMenuMaxHeight = 360;

  static Color surface(ColorScheme colors) => colors.surfaceContainerHigh;

  static Color border(ColorScheme colors) =>
      colors.outlineVariant.withValues(alpha: 0.64);

  static Color selectedBackground(ColorScheme colors) =>
      colors.primary.withValues(alpha: 0.12);

  static RoundedRectangleBorder menuShape(ColorScheme colors) =>
      RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(menuRadius),
        side: BorderSide(color: border(colors)),
      );

  static PopupMenuThemeData popupMenuThemeData(ColorScheme colors) {
    return PopupMenuThemeData(
      color: surface(colors),
      shape: menuShape(colors),
      menuPadding: const EdgeInsets.all(menuPadding),
      elevation: 8,
      shadowColor: colors.shadow.withValues(alpha: 0.34),
      surfaceTintColor: Colors.transparent,
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final disabled = states.contains(WidgetState.disabled);
        return TextStyle(
          fontSize: 12,
          color: disabled
              ? colors.onSurface.withValues(alpha: 0.54)
              : colors.onSurface,
        );
      }),
    );
  }

  static MenuThemeData menuThemeData(ColorScheme colors) {
    return MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll<Color?>(surface(colors)),
        shadowColor: WidgetStatePropertyAll<Color?>(
          colors.shadow.withValues(alpha: 0.34),
        ),
        surfaceTintColor: const WidgetStatePropertyAll<Color?>(
          Colors.transparent,
        ),
        elevation: const WidgetStatePropertyAll<double?>(8),
        padding: const WidgetStatePropertyAll<EdgeInsetsGeometry?>(
          EdgeInsets.all(menuPadding),
        ),
        shape: WidgetStatePropertyAll<OutlinedBorder?>(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(menuRadius),
          ),
        ),
        side: WidgetStatePropertyAll<BorderSide?>(
          BorderSide(color: border(colors)),
        ),
        alignment: AlignmentDirectional.bottomStart,
      ),
    );
  }

  static MenuStyle selectMenuStyle(
    ColorScheme colors, {
    required double width,
    required double maxHeight,
  }) {
    final style = menuThemeData(colors).style!;
    return style.copyWith(
      minimumSize: WidgetStatePropertyAll<Size?>(Size(width, 0)),
      maximumSize: WidgetStatePropertyAll<Size?>(Size(width, maxHeight)),
    );
  }
}
