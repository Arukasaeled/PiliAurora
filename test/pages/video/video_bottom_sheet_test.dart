import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/utils/page_utils.dart';

void main() {
  testWidgets('视频底部面板可覆盖到底部安全区之外', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(bottom: 24);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);
    addTearDown(Get.reset);

    await tester.pumpWidget(
      GetMaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => PageUtils.showVideoBottomSheet(
                  context,
                  child: const ColoredBox(
                    key: ValueKey('sheet'),
                    color: Colors.black,
                  ),
                ),
                child: const Text('打开面板'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开面板'));
    await tester.pumpAndSettle();

    expect(tester.getRect(find.byKey(const ValueKey('sheet'))).bottom, 844);
  });
}
