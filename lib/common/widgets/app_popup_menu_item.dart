import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/common/widgets/app_menu_theme.dart';

/// 浮层菜单项：把选中态、悬停水波和背景裁剪在同一套内圆角里。
class AppPopupMenuItem<T> extends PopupMenuItem<T> {
  const AppPopupMenuItem({
    super.key,
    super.value,
    super.onTap,
    super.enabled,
    super.height,
    super.padding,
    super.textStyle,
    super.labelTextStyle,
    super.mouseCursor,
    required super.child,
    this.selected = false,
  });

  final bool selected;

  // 选中态由自身绘制，避免 PopupMenu 再铺一层直角高亮。
  @override
  bool represents(T? value) => false;

  @override
  PopupMenuItemState<T, AppPopupMenuItem<T>> createState() =>
      _AppPopupMenuItemState<T>();
}

class _AppPopupMenuItemState<T>
    extends PopupMenuItemState<T, AppPopupMenuItem<T>> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final states = <WidgetState>{
      if (widget.selected) WidgetState.selected,
      if (!widget.enabled) WidgetState.disabled,
    };
    final style =
        widget.labelTextStyle?.resolve(states) ??
        theme.popupMenuTheme.labelTextStyle?.resolve(states) ??
        theme.textTheme.labelLarge!.copyWith(
          color: widget.enabled
              ? colors.onSurface
              : colors.onSurface.withValues(alpha: 0.54),
        );
    final radius = BorderRadius.circular(AppMenuTheme.itemRadius);

    return MergeSemantics(
      child: Semantics(
        button: true,
        enabled: widget.enabled,
        selected: widget.selected,
        child: Material(
          color: widget.selected
              ? AppMenuTheme.selectedBackground(colors)
              : Colors.transparent,
          shape: RoundedRectangleBorder(borderRadius: radius),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: widget.enabled ? handleTap : null,
            canRequestFocus: widget.enabled,
            mouseCursor: widget.mouseCursor,
            borderRadius: radius,
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: widget.height),
              child: Padding(
                padding:
                    widget.padding ??
                    const EdgeInsets.symmetric(horizontal: 12),
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: AnimatedDefaultTextStyle(
                    style: style,
                    duration: const Duration(milliseconds: 200),
                    child: buildChild() ?? const SizedBox.shrink(),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
