import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:get/get_navigation/src/router_report.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  tearDown(Get.reset);

  for (final management in [
    SmartManagement.full,
    SmartManagement.keepFactory,
  ]) {
    testWidgets('出栈清除路由键并保留永久依赖：${management.name}', (tester) async {
      Get.testMode = true;
      Get.smartManagement = management;
      final navigator = GlobalKey<NavigatorState>();
      final root = _RouteController();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          navigatorObservers: [GetObserver()],
          onGenerateRoute: (_) => GetPageRoute<void>(
            settings: const RouteSettings(name: '/'),
            page: () {
              Get.put<_RouteController>(root, tag: 'root');
              return const SizedBox();
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      final baseline = RouterReportManager.debugRouteKeyCount;
      expect(baseline, 1);

      for (var index = 0; index < 3; index++) {
        final controller = _RouteController();
        final permanent = _RouteController();
        final created = _RouteController();
        final tag = 'detail-$index';
        unawaited(
          navigator.currentState!.push<void>(
            GetPageRoute<void>(
              settings: RouteSettings(
                name: '/detail/$index',
                arguments: <String, Object>{'item': index},
              ),
              page: () {
                Get
                  ..put<_RouteController>(controller, tag: tag)
                  ..put<_RouteController>(
                    permanent,
                    tag: '$tag-permanent',
                    permanent: true,
                  )
                  ..create<_RouteController>(
                    () => created,
                    tag: '$tag-created',
                  )
                  ..find<_RouteController>(tag: '$tag-created');
                return const SizedBox();
              },
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(RouterReportManager.debugRouteKeyCount, baseline + 1);

        navigator.currentState!.pop();
        await tester.pumpAndSettle();

        expect(controller.closeCalls, 1);
        expect(created.closeCalls, 1);
        expect(permanent.closeCalls, 0);
        expect(
          Get.find<_RouteController>(tag: '$tag-permanent'),
          same(permanent),
        );
        expect(root.closeCalls, 0);
        expect(Get.find<_RouteController>(tag: 'root'), same(root));
        expect(
          RouterReportManager.debugRouteKeyCount,
          baseline,
          reason: '已销毁 Route 及其 arguments 必须解除静态路由表引用',
        );
      }

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(root.closeCalls, 1);
      expect(RouterReportManager.debugRouteKeyCount, 0);
      Get.deleteAll(force: true);
    });
  }
}

class _RouteController extends GetxController {
  int closeCalls = 0;

  @override
  void onClose() {
    closeCalls++;
    super.onClose();
  }
}
