import 'dart:io';

import 'package:pili_aurora/utils/storage_pref.dart';
import 'package:pili_aurora/services/diagnostics/diagnostics.dart';
import 'package:pili_aurora/services/diagnostics/app_logger.dart';
import 'package:pili_aurora/utils/path_utils.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';
import 'package:pili_aurora/build_config.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

final logger = AppLogger(
  diagnostics: Diagnostics.instance,
  console: kDebugMode ? debugPrint : null,
);

abstract final class LoggerUtils {
  static Future<void> initialize() async {
    Diagnostics.instance.observeLifecycle();
    Diagnostics.instance.register(
      'app',
      () => {
        'version': '${BuildConfig.versionName}+${BuildConfig.versionCode}',
        'commit': BuildConfig.commitHash,
      },
    );
    await Diagnostics.instance.configure(
      level: DiagnosticLogLevel.parse(Pref.diagnosticLogLevel),
      playerLevel: DiagnosticLogLevel.parse(Pref.playerDiagnosticLogLevel),
      tracing: Pref.performanceTracing,
      intervalMs: Pref.performanceIntervalMs,
    );
    Diagnostics.instance.saveSettings = (settings) => GStorage.setting.putAll({
      SettingBoxKey.diagnosticLogLevel: settings['level'],
      SettingBoxKey.playerDiagnosticLogLevel: settings['playerLevel'],
      SettingBoxKey.enableLog: settings['level'] != DiagnosticLogLevel.off.name,
      SettingBoxKey.performanceTracing: settings['tracing'],
      SettingBoxKey.performanceIntervalMs: settings['intervalMs'],
    });
  }

  /// 本地设置读取失败时，也能保存启动错误。
  static Future<void> prepare() async => Diagnostics.instance.initialize(
    directory: Directory(p.join(appSupportDirPath, 'diagnostics')),
    legacyReports: File(
      p.join(
        (await getApplicationDocumentsDirectory()).path,
        '.pili_logs.json',
      ),
    ),
  );
}
