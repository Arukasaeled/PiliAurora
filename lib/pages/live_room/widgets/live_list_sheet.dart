import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/utils/theme_utils.dart';

Future<void> showLiveListSheet({
  required BuildContext context,
  required String title,
  required Widget child,
  double heightFactor = 0.7,
}) => showModalBottomSheet<void>(
  context: context,
  useSafeArea: true,
  isScrollControlled: true,
  clipBehavior: Clip.hardEdge,
  backgroundColor: const Color(0xFF16171A),
  constraints: const BoxConstraints(maxWidth: 450),
  builder: (context) => Theme(
    data: ThemeUtils.darkTheme,
    child: Material(
      color: const Color(0xFF16171A),
      child: FractionallySizedBox(
        heightFactor: heightFactor,
        widthFactor: 1,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 20, right: 8, top: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: const TextStyle(fontSize: 17),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(child: child),
          ],
        ),
      ),
    ),
  ),
);
