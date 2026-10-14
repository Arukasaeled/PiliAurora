import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/models/common/super_resolution_type.dart';
import 'package:pili_aurora/pages/setting/widgets/popup_item.dart';
import 'package:pili_aurora/plugin/pl_player/playback/super_resolution_policy.dart';

class SuperResolutionMenuTile extends StatelessWidget {
  const SuperResolutionMenuTile({
    super.key,
    required this.availability,
    required this.value,
    required this.onSelected,
  });

  final SuperResolutionEligibility availability;
  final SuperResolutionType value;
  final ValueChanged<SuperResolutionType> onSelected;

  @override
  Widget build(BuildContext context) {
    final enabled = availability == SuperResolutionEligibility.allowed;
    final hint = switch (availability) {
      SuperResolutionEligibility.allowed => '超分辨率',
      SuperResolutionEligibility.resolutionTooHigh => '视频分辨率过高，无法开启超分',
      SuperResolutionEligibility.unknownSize => '等待视频和屏幕尺寸，暂无法开启超分',
    };
    final theme = Theme.of(context);
    return Tooltip(
      message: hint,
      child: GestureDetector(
        onTap: enabled ? null : () => SmartDialog.showToast(hint),
        child: PopupListTile<SuperResolutionType>(
          dense: true,
          enabled: enabled,
          leading: const Icon(Icons.stay_current_landscape_outlined, size: 20),
          title: const Text('超分辨率', style: TextStyle(fontSize: 14)),
          titleStyle: theme.textTheme.bodyLarge,
          value: () => (value, enabled ? value.label : hint),
          itemBuilder: (_) => enumItemBuilder(SuperResolutionType.values),
          onSelected: (value, _) => onSelected(value),
          descStyle: const TextStyle(fontSize: 13),
        ),
      ),
    );
  }
}
