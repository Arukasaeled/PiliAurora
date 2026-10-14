import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/models/common/super_resolution_type.dart';
import 'package:pili_aurora/pages/setting/widgets/popup_item.dart';
import 'package:pili_aurora/plugin/pl_player/playback/super_resolution_policy.dart';
import 'package:pili_aurora/plugin/pl_player/widgets/super_resolution_menu_tile.dart';

void main() {
  for (final availability in [
    SuperResolutionEligibility.resolutionTooHigh,
    SuperResolutionEligibility.unknownSize,
  ]) {
    testWidgets('侧边超分入口在 $availability 时置灰并保留提示', (tester) async {
      final selected = <SuperResolutionType>[];
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [FlutterSmartDialog.observer],
          builder: FlutterSmartDialog.init(),
          home: Scaffold(
            body: SuperResolutionMenuTile(
              availability: availability,
              value: SuperResolutionType.disable,
              onSelected: selected.add,
            ),
          ),
        ),
      );
      final tile = tester.widget<PopupListTile<SuperResolutionType>>(
        find.byType(PopupListTile<SuperResolutionType>),
      );
      expect(tile.enabled, isFalse);
      final hint = tester.widget<Tooltip>(find.byType(Tooltip)).message!;
      expect(find.text(hint), findsOneWidget);
      await tester.tap(find.text('超分辨率'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text(hint), findsNWidgets(2));
      expect(find.byType(PopupMenuItem<SuperResolutionType>), findsNothing);
      expect(selected, isEmpty);
      unawaited(SmartDialog.dismiss(status: SmartStatus.toast));
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
    });
  }

  testWidgets('可用时侧边菜单允许选择超分', (tester) async {
    final selected = <SuperResolutionType>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SuperResolutionMenuTile(
            availability: SuperResolutionEligibility.allowed,
            value: SuperResolutionType.disable,
            onSelected: selected.add,
          ),
        ),
      ),
    );
    await tester.tap(find.text('超分辨率'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('效率'));
    await tester.pumpAndSettle();
    expect(selected, [SuperResolutionType.efficiency]);
  });
}
