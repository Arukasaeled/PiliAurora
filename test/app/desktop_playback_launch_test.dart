import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/app/desktop_playback_launch.dart';
import 'package:pili_aurora/plugin/pl_player/widgets/player_loading.dart';
import 'package:pili_aurora/services/desktop_playback_request.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('小窗显示与路由不等待播放流就绪', (tester) async {
    final calls = <String>[];
    const channel = MethodChannel('window_manager');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          ..setMockMethodCallHandler(channel, (call) async {
            calls.add(call.method);
            if (call.method == 'isMinimized') return false;
            return null;
          });
    addTearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      Get.reset();
    });

    await tester.pumpWidget(
      GetMaterialApp(
        home: const DesktopPlaybackLaunch(request: DesktopPlaybackRequest.live(1)),
        getPages: [
          GetPage(
            name: '/liveRoom',
            page: () => const Scaffold(body: PlayerLoadingPanel()),
          ),
        ],
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(calls, containsAllInOrder(['show', 'focus']));
    expect(Get.currentRoute, '/liveRoom');
    expect(find.text('加载中...'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
