import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/common/widgets/app_menu_theme.dart';

/// 设置页统一使用的选择字段，菜单支持当前值标题、选中勾和长列表滚动。
class AppSelectField<T> extends StatefulWidget {
  const AppSelectField({
    super.key,
    required this.value,
    required this.label,
    required this.selectedLabel,
    required this.options,
    required this.onSelected,
    this.enabled = true,
    this.width = AppMenuTheme.selectWidth,
    this.menuWidth = AppMenuTheme.selectMenuWidth,
    this.maxMenuHeight = AppMenuTheme.selectMenuMaxHeight,
    this.tooltip,
    this.selectedWidget,
  });

  final T? value;
  final String label;
  final String selectedLabel;
  final List<(T, String)> options;
  final ValueChanged<T> onSelected;
  final bool enabled;
  final double width;
  final double menuWidth;
  final double maxMenuHeight;
  final String? tooltip;
  final Widget? selectedWidget;

  @override
  State<AppSelectField<T>> createState() => _AppSelectFieldState<T>();
}

class _AppSelectFieldState<T> extends State<AppSelectField<T>> {
  final MenuController _menuController = MenuController();
  final FocusNode _fieldFocusNode = FocusNode(
    debugLabel: 'AppSelectField',
  );
  bool _open = false;

  bool get _enabled => widget.enabled && widget.options.isNotEmpty;

  int get _selectedIndex =>
      widget.options.indexWhere((option) => option.$1 == widget.value);

  @override
  void dispose() {
    _fieldFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = ColorScheme.of(context);
    final selectedIndex = _selectedIndex;
    final autofocusIndex = selectedIndex < 0 ? 0 : selectedIndex;

    return MenuAnchor(
      controller: _menuController,
      childFocusNode: _fieldFocusNode,
      style: AppMenuTheme.selectMenuStyle(
        colors,
        width: widget.menuWidth,
        maxHeight: widget.maxMenuHeight,
      ),
      alignmentOffset: Offset(
        widget.width - widget.menuWidth,
        AppMenuTheme.menuPadding + 1,
      ),
      onOpen: () {
        if (mounted) setState(() => _open = true);
      },
      onClose: () {
        if (mounted) setState(() => _open = false);
      },
      menuChildren: [
        _buildHeader(colors),
        for (var index = 0; index < widget.options.length; index++)
          _buildOption(
            colors,
            widget.options[index],
            autofocus: index == autofocusIndex,
          ),
      ],
      builder: (context, controller, child) {
        return Tooltip(
          message: widget.tooltip ?? '${widget.label}：${widget.selectedLabel}',
          child: SizedBox(
            width: widget.width,
            height: 34,
            child: TextButton(
              focusNode: _fieldFocusNode,
              onPressed: _enabled
                  ? () {
                      if (controller.isOpen) {
                        controller.close();
                      } else {
                        controller.open();
                      }
                    }
                  : null,
              style: _fieldStyle(colors),
              child: Row(
                children: [
                  Expanded(
                    child: DefaultTextStyle(
                      style: TextStyle(
                        fontSize: 11.5,
                        height: 1.2,
                        color: _enabled
                            ? colors.onSurface
                            : colors.onSurface.withValues(alpha: 0.38),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      child:
                          widget.selectedWidget ??
                          Text(
                            widget.selectedLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                    ),
                  ),
                  Icon(
                    Icons.expand_more,
                    size: 16,
                    color: _open ? colors.primary : colors.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildHeader(ColorScheme colors) {
    final smallStyle = TextStyle(
      fontSize: 10,
      color: colors.onSurfaceVariant,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(9, 7, 9, 8),
      child: Row(
        children: [
          Expanded(child: Text(widget.label, style: smallStyle)),
          Flexible(
            child: Text(
              '当前 ${widget.selectedLabel}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.end,
              style: smallStyle,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOption(
    ColorScheme colors,
    (T, String) option, {
    required bool autofocus,
  }) {
    final selected = option.$1 == widget.value;
    return MenuItemButton(
      autofocus: autofocus,
      onPressed: () => widget.onSelected(option.$1),
      style: _optionStyle(colors, selected),
      child: Row(
        children: [
          SizedBox(
            width: 17,
            child: selected
                ? Icon(Icons.check, size: 15, color: colors.primary)
                : null,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              option.$2,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  ButtonStyle _fieldStyle(ColorScheme colors) {
    return TextButton.styleFrom(
      foregroundColor: _enabled
          ? colors.onSurface
          : colors.onSurface.withValues(alpha: 0.38),
      disabledForegroundColor: colors.onSurface.withValues(alpha: 0.38),
      backgroundColor: _open
          ? colors.primary.withValues(alpha: 0.10)
          : Colors.transparent,
      minimumSize: Size(widget.width, 34),
      maximumSize: Size(widget.width, 34),
      padding: const EdgeInsets.fromLTRB(9, 0, 7, 0),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(
          color: _open
              ? colors.primary.withValues(alpha: 0.54)
              : colors.outlineVariant,
        ),
      ),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
    );
  }

  ButtonStyle _optionStyle(ColorScheme colors, bool selected) {
    return ButtonStyle(
      minimumSize: const WidgetStatePropertyAll<Size>(
        Size(0, AppMenuTheme.itemHeight),
      ),
      padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
        EdgeInsets.symmetric(horizontal: 9),
      ),
      shape: WidgetStatePropertyAll<OutlinedBorder>(
        RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppMenuTheme.itemRadius),
        ),
      ),
      backgroundColor: WidgetStateProperty.resolveWith<Color?>((states) {
        if (selected) {
          return AppMenuTheme.selectedBackground(colors);
        }
        if (states.contains(WidgetState.hovered) ||
            states.contains(WidgetState.focused)) {
          return colors.onSurface.withValues(alpha: 0.06);
        }
        return Colors.transparent;
      }),
      foregroundColor: WidgetStatePropertyAll<Color?>(
        selected ? colors.primary : colors.onSurface,
      ),
      overlayColor: WidgetStatePropertyAll<Color?>(
        colors.onSurface.withValues(alpha: 0.04),
      ),
      textStyle: WidgetStatePropertyAll<TextStyle>(
        TextStyle(
          fontSize: 12,
          fontWeight: selected ? FontWeight.w500 : FontWeight.w400,
        ),
      ),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
    );
  }
}
