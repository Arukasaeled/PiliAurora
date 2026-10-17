import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/services/diagnostics/diagnostics.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(
    () => Diagnostics.instance.configure(level: DiagnosticLogLevel.info),
  );
  tearDownAll(Diagnostics.instance.dispose);

  String? recordedRoute() =>
      (Diagnostics.instance.recentLogs.first['details'] as Map)['route']
          as String?;
  Route<void> page(String name) => PageRouteBuilder<void>(
    settings: RouteSettings(name: name),
    pageBuilder: (_, _, _) => const SizedBox.shrink(),
  );
  Route<void> popup() => RawDialogRoute<void>(
    pageBuilder: (_, _, _) => const SizedBox.shrink(),
  );

  test('未命名弹窗及嵌套弹窗保留播放器页面路由', () {
    final observer = DiagnosticRouteObserver();
    final home = page('/');
    final video = page('/videoV');
    final first = popup();
    final second = popup();
    observer
      ..didPush(home, null)
      ..didPush(video, home)
      ..didPush(first, video);
    expect(recordedRoute(), '/videoV');
    observer.didPush(second, first);
    expect(recordedRoute(), '/videoV');
    observer.didPop(second, first);
    expect(recordedRoute(), '/videoV');
    observer.didPop(first, video);
    expect(recordedRoute(), '/videoV');
    observer.didPop(video, home);
    expect(recordedRoute(), '/');
  });

  test('移除和替换非顶部页面时仍记录当前页面', () {
    final observer = DiagnosticRouteObserver();
    final home = page('/');
    final video = page('/videoV');
    final live = page('/liveRoom');
    final replaced = page('/setting');
    observer
      ..didPush(home, null)
      ..didPush(video, home)
      ..didPush(live, video)
      ..didReplace(oldRoute: video, newRoute: replaced);
    expect(recordedRoute(), '/liveRoom');
    observer.didRemove(replaced, home);
    expect(recordedRoute(), '/liveRoom');
    observer.didPop(live, home);
    expect(recordedRoute(), '/');
  });
}
