import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/services/desktop_playback_windows.dart';
import 'package:pili_aurora/services/diagnostics/diagnostics.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'window applies serialized settings and persists performance locally',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'pili-window-log-',
      );
      final diagnostics = Diagnostics.instance;
      await diagnostics.initialize(directory: directory, childProcess: true);
      try {
        await DesktopPlaybackWindows.instance.applyDiagnosticSettings(
          jsonDecode(
            jsonEncode({
              'level': 'debug',
              'playerLevel': 'trace',
              'tracing': true,
              'intervalMs': 250,
            }),
          ) as Map<String, dynamic>,
        );
        expect(diagnostics.accepts(DiagnosticLogLevel.debug), isTrue);
        expect(diagnostics.acceptsPlayer(DiagnosticLogLevel.trace), isTrue);
        expect(diagnostics.intervalMs, 250);
        diagnostics.capture();
        await DesktopPlaybackWindows.instance.applyDiagnosticSettings({
          'level': 'off',
          'playerLevel': 'off',
          'tracing': false,
          'intervalMs': 1000,
        });
        expect(diagnostics.accepts(DiagnosticLogLevel.error), isFalse);
        expect(diagnostics.acceptsPlayer(DiagnosticLogLevel.error), isFalse);
        expect(diagnostics.tracing, isFalse);
        await diagnostics.flush();
        expect(
          await File('${directory.path}/performance.jsonl').readAsString(),
          contains('sample'),
        );
      } finally {
        diagnostics.dispose();
        await diagnostics.flush();
        await directory.delete(recursive: true);
      }
    },
  );
}
