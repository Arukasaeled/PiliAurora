import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show FramePhase;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:archive/archive_io.dart';
import 'package:pili_aurora/services/diagnostics/history_reader.dart';
import 'package:pili_aurora/services/diagnostics/process_metrics.dart';
import 'package:pili_aurora/services/diagnostics/windows_gpu_metrics.dart';
import 'package:pili_aurora/services/diagnostics/record_store.dart';
import 'package:pili_aurora/services/diagnostics/redact.dart';

enum DiagnosticLogLevel {
  trace('跟踪', '最详细的事件与耗时'),
  debug('调试', '请求、缓存与播放过程'),
  info('信息', '主要状态变化'),
  warning('警告', '异常情况与错误（默认）'),
  error('错误', '仅记录失败'),
  off('关闭', '停止此通道的日志保存');

  const DiagnosticLogLevel(this.label, this.description);
  final String label;
  final String description;

  static DiagnosticLogLevel parse(String? value) =>
      values.where((level) => level.name == value).firstOrNull ?? warning;
}

class DiagnosticLogResult {
  const DiagnosticLogResult({required this.record, required this.queued});
  final Map<String, Object?> record;

  /// 已进入持久化队列；写盘结果需在 flush 后检查存储状态。
  final bool queued;
}

class Diagnostics extends ChangeNotifier with WidgetsBindingObserver {
  Diagnostics({this.processReader});

  static final instance = Diagnostics();
  static const intervals = [250, 1000, 5000];
  final Map<String, Object?> Function()? processReader;
  final _processMetrics = ProcessMetrics();
  final _gpuMetrics = WindowsGpuMetrics();
  final _sources = <String, Map<String, Object?> Function()>{};
  final _operations = <String, _OperationStats>{};
  final _gauges = <String, num>{};
  final _recent = <String, Queue<Map<String, Object?>>>{};
  final _frames = _FrameStats();
  bool Function(Map<String, Object?>)? forwardRecord;
  int forwardingFailures = 0;
  Future<void> Function()? forwardFlush;
  Future<void> Function()? pauseChildren;
  Future<void> Function()? resumeChildren;
  Future<void> Function()? clearChildren;
  Future<void> _maintenanceTail = Future.value();
  bool _writesPaused = false;
  Completer<void>? _writesResumed;
  Timer? _pauseTimeout;
  final _deferred =
      Queue<(DiagnosticRecordStore?, Map<String, Object?>, bool)>();
  int _deferredDrops = 0;
  final _deferredTrace = Queue<Map<String, Object?>>();
  VoidCallback? onSettingsChanged;
  Directory? _directory;
  bool _childProcess = false;
  int? _windowId;
  Map<String, Object?> get settings => {
    'level': _level.name,
    'playerLevel': _playerLevel.name,
    'tracing': _tracing,
    'intervalMs': _intervalMs,
  };
  final _elapsed = Stopwatch();
  DiagnosticRecordStore? _logs;
  DiagnosticRecordStore? _trace;
  DiagnosticRecordStore? _playerLogs;
  // 历史异常文件以只读兼容源保留，新异常统一写入 runtime。
  DiagnosticRecordStore? _legacyReports;
  final _clock = Stopwatch()..start();
  final String _runId = DateTime.now().toUtc().toIso8601String();
  int _logSequence = 0;
  DiagnosticLogLevel _playerLevel = DiagnosticLogLevel.info;
  Timer? _timer;
  Timer? _notification;
  bool _tracing = false;
  bool _observingLifecycle = false;
  DiagnosticLogLevel _level = DiagnosticLogLevel.warning;
  int _intervalMs = 1000;
  int _sequence = 0;
  String _route = '/';
  String? _session;
  Map<String, Object?>? latest;
  Future<void> Function(Map<String, Object?>)? _saveSettings;

  set saveSettings(Future<void> Function(Map<String, Object?>) callback) =>
      _saveSettings = callback;

  void observeLifecycle() {
    if (_observingLifecycle) return;
    WidgetsBinding.instance.addObserver(this);
    _observingLifecycle = true;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(flush());
    }
  }

  bool get tracing => _tracing;
  DiagnosticLogLevel get level => _level;
  DiagnosticLogLevel get playerLevel => _playerLevel;
  Map<String, Object?> get storageStatus => {
    'forwardingFailures': forwardingFailures,
    'runtime': _logs?.status,
    'player': _playerLogs?.status,
    'performance': _trace?.status,
  };
  int get intervalMs => _intervalMs;
  String? get session => _session;
  static int _compareRecords(Map<String, Object?> a, Map<String, Object?> b) {
    final time = '${a['time']}'.compareTo('${b['time']}');
    if (time != 0) return time;
    final run = '${a['runId']}'.compareTo('${b['runId']}');
    if (run != 0) return run;
    return (a['sequence'] as int? ?? 0).compareTo(b['sequence'] as int? ?? 0);
  }

  List<Map<String, Object?>> get recentLogs =>
      _recent.values.expand((queue) => queue).toList()
        ..sort((a, b) => _compareRecords(b, a));
  int get droppedRecords =>
      _deferredDrops +
      (_logs?.dropped ?? 0) +
      (_trace?.dropped ?? 0) +
      (_playerLogs?.dropped ?? 0);
  String? get storageError =>
      _logs?.lastError ?? _trace?.lastError ?? _playerLogs?.lastError;

  Future<void> initialize({
    required Directory directory,
    File? legacyReports,
    bool childProcess = false,
    int? windowId,
    DiagnosticLogLevel level = DiagnosticLogLevel.warning,
    DiagnosticLogLevel playerLevel = DiagnosticLogLevel.info,
    bool tracing = false,
    int intervalMs = 1000,
    Future<void> Function(Map<String, Object?>)? saveSettings,
  }) async {
    _directory = directory;
    _childProcess = childProcess;
    _windowId = windowId;
    _logs = DiagnosticRecordStore(
      File('${directory.path}/runtime.jsonl'),
      maxBytes: childProcess ? 1 << 20 : 8 << 20,
      retainedFiles: childProcess ? 2 : 4,
    );
    _legacyReports = legacyReports == null
        ? null
        : DiagnosticRecordStore(legacyReports);
    _trace = DiagnosticRecordStore(
      File('${directory.path}/performance.jsonl'),
      maxBytes: childProcess ? 4 << 20 : 16 << 20,
    );
    _playerLogs = DiagnosticRecordStore(
      File('${directory.path}/player.jsonl'),
      maxBytes: childProcess ? 4 << 20 : 16 << 20,
      retainedFiles: childProcess ? 2 : 8,
    );
    _playerLevel = playerLevel;
    _saveSettings = saveSettings;
    _level = level;
    _intervalMs = intervals.contains(intervalMs) ? intervalMs : 1000;
    final pending = _recent.values.expand((queue) => queue).toList();
    _recent.clear();
    await _loadHistory();
    for (final record in pending) {
      _remember(record);
      (record['channel'] == 'player' ? _playerLogs : _logs)?.add(record);
    }
    if (tracing) _start();
  }

  Future<void> _loadHistory() async {
    try {
      final records =
          [
            ...await readDiagnosticHistory(await _logs!.files()),
            ...await readDiagnosticHistory(await _playerLogs!.files()),
            for (final report in await readDiagnosticHistory(
              await _legacyReports?.files() ?? const [],
            ))
              {
                'time':
                    DateTime.tryParse('${report['dateTime']}')
                        ?.toUtc()
                        .toIso8601String() ??
                    DateTime.utc(1970).toIso8601String(),
                'channel': 'runtime',
                'level': 'error',
                'category': 'exception',
                'message': report['error'],
                'stack': report['stackTrace'],
                'details': {
                  'device': report['deviceParameters'],
                  'application': report['applicationParameters'],
                  'build': report['customParameters'],
                },
              },
          ]..sort((a, b) {
            final order = (a['time'] as String? ?? '').compareTo(
              b['time'] as String? ?? '',
            );
            if (order != 0) return order;
            return (a['sequence'] as int? ?? 0).compareTo(
              b['sequence'] as int? ?? 0,
            );
          });
      for (final record in records) {
        _remember(record);
      }
    } catch (_) {
      /* 日志读取失败不影响应用启动。 */
    }
  }

  Future<void> configure({
    DiagnosticLogLevel? level,
    DiagnosticLogLevel? playerLevel,
    bool? tracing,
    int? intervalMs,
  }) async {
    if (level != null) _level = level;
    if (playerLevel != null) _playerLevel = playerLevel;
    if (intervalMs != null && intervals.contains(intervalMs)) {
      _intervalMs = intervalMs;
    }
    if (tracing == false && _tracing) _stop();
    if (tracing == true && !_tracing) _start();
    if (_tracing && intervalMs != null) {
      _timer?.cancel();
      _timer = Timer.periodic(
        Duration(milliseconds: _intervalMs),
        (_) => capture(),
      );
    }
    onSettingsChanged?.call();
    notifyListeners();
    await _saveSettings?.call({
      'level': _level.name,
      'playerLevel': _playerLevel.name,
      'tracing': _tracing,
      'intervalMs': _intervalMs,
    });
  }

  bool accepts(DiagnosticLogLevel level) =>
      _level != DiagnosticLogLevel.off && level.index >= _level.index;

  DiagnosticLogResult? log(
    DiagnosticLogLevel level,
    String category,
    Object? message, {
    Object? details,
    StackTrace? stack,
  }) {
    if (!accepts(level)) return null;
    return _writeLog(
      _logs,
      level,
      category,
      message,
      details: details,
      stack: stack,
    );
  }

  bool acceptsPlayer(DiagnosticLogLevel level) =>
      _playerLevel != DiagnosticLogLevel.off &&
      level.index >= _playerLevel.index;

  void playerLog(
    DiagnosticLogLevel level,
    String category,
    Object? message, {
    Object? details,
    StackTrace? stack,
  }) {
    if (!acceptsPlayer(level)) return;
    _writeLog(
      _playerLogs,
      level,
      category,
      message,
      details: details,
      stack: stack,
      player: true,
    );
  }

  DiagnosticLogResult _writeLog(
    DiagnosticRecordStore? store,
    DiagnosticLogLevel level,
    String category,
    Object? message, {
    Object? details,
    StackTrace? stack,
    bool player = false,
  }) {
    final record = <String, Object?>{
      'time': DateTime.now().toUtc().toIso8601String(),
      'runId': _runId,
      'processId': pid,
      if (_windowId != null) 'windowId': _windowId,
      'route': _route,
      'sequence': ++_logSequence,
      'elapsedUs': _clock.elapsedMicroseconds,
      'channel': player ? 'player' : 'runtime',
      'level': level.name,
      'category': category,
      'message': DiagnosticRedactor.text(
        message is Map || message is Iterable
            ? DiagnosticRedactor.clean(message)
            : message,
        maxLength: player ? 65536 : 16384,
      ),
      if (details != null)
        'details': DiagnosticRedactor.clean(
          details,
          maxCharacters: player ? 262144 : 8192,
          maxStringLength: player ? 65536 : 4096,
        ),
      if (stack != null)
        'stack': DiagnosticRedactor.text(
          stack,
          maxLength: player ? 65536 : 4096,
        ),
      if (_tracing) 'session': _session,
    };
    final accepted = _persist(store, record, forward: true);
    return DiagnosticLogResult(record: record, queued: accepted);
  }

  bool _persist(
    DiagnosticRecordStore? store,
    Map<String, Object?> record, {
    bool forward = false,
  }) {
    if (_writesPaused) {
      if (_deferred.length + _deferredTrace.length >= 400) {
        _deferredDrops++;
        return false;
      }
      _deferred.add((store, record, forward));
      return false;
    }
    _remember(record);
    final accepted = store?.add(record) ?? false;
    if (forward) {
      try {
        if (forwardRecord?.call(record) == false) forwardingFailures++;
      } catch (_) {
        forwardingFailures++;
      }
    }
    _notifySoon();
    return accepted;
  }

  Future<void> pauseWrites() async {
    _writesResumed ??= Completer<void>();
    _writesPaused = true;
    _pauseTimeout?.cancel();
    // 主窗口异常退出时，子窗口会自行恢复日志保存。
    _pauseTimeout = Timer(const Duration(seconds: 60), resumeWrites);
    await flushLocal();
  }

  void resumeWrites() {
    _pauseTimeout?.cancel();
    _writesPaused = false;
    while (_deferred.isNotEmpty) {
      final (store, record, forward) = _deferred.removeFirst();
      _persist(store, record, forward: forward);
    }
    while (_deferredTrace.isNotEmpty) {
      _trace?.add(_deferredTrace.removeFirst());
    }
    _writesResumed?.complete();
    _writesResumed = null;
  }

  Future<T> _maintain<T>(Future<T> Function() action) {
    final result = _maintenanceTail.then((_) async {
      await pauseWrites();
      try {
        await pauseChildren?.call();
        return await action();
      } finally {
        try {
          await resumeChildren?.call();
        } finally {
          resumeWrites();
        }
      }
    });
    _maintenanceTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  void _remember(Map<String, Object?> record) {
    final channel = record['channel'] as String? ?? 'runtime';
    final queue = _recent.putIfAbsent(channel, Queue.new)..add(record);
    if (queue.length > 200) queue.removeFirst();
  }

  /// 子进程记录保留其时钟和页面上下文，由主进程统一轮转和导出。
  void receiveRecord(Map<String, Object?> record, {required int windowId}) {
    final player = record['channel'] == 'player';
    final level = DiagnosticLogLevel.parse(record['level'] as String?);
    if (player ? !acceptsPlayer(level) : !accepts(level)) return;
    final safe = Map<String, Object?>.from(
      DiagnosticRedactor.clean(
        record,
        maxCharacters: 524288,
        maxStringLength: 65536,
      ) as Map,
    )..['windowId'] = windowId;
    _persist(player ? _playerLogs : _logs, safe);
  }

  VoidCallback register(String name, Map<String, Object?> Function() reader) {
    _sources[name] = reader;
    return () {
      if (identical(_sources[name], reader)) _sources.remove(name);
    };
  }

  /// 读取指定诊断源，不开启全局性能跟踪；播放器可把 Flutter 几何加入自己的快照。
  Map<String, Object?> readSources({required String prefix}) => {
    for (final entry in _sources.entries.toList())
      if (entry.key.startsWith(prefix)) entry.key: _readSource(entry.value),
  };

  static Object _readSource(Map<String, Object?> Function() reader) {
    try {
      return reader();
    } catch (_) {
      return {'available': false};
    }
  }

  void gauge(String name, num value) => _gauges[name] = value;

  TraceOperation? begin(
    String category,
    String action, {
    Map<String, Object?>? details,
  }) {
    if (!_tracing && !accepts(DiagnosticLogLevel.debug)) return null;
    final stats = _operations.putIfAbsent(category, _OperationStats.new);
    stats.active++;
    return TraceOperation._(this, category, action, details, stats);
  }

  void routeChanged(String? name) {
    _route = DiagnosticRedactor.text((name ?? '/').split('?').first);
    log(
      DiagnosticLogLevel.info,
      'navigation',
      '页面切换',
      details: {'route': _route},
    );
  }

  void _writeTrace(Map<String, Object?> record) {
    if (_writesPaused) {
      if (_deferred.length + _deferredTrace.length >= 400) {
        _deferredDrops++;
      } else {
        _deferredTrace.add(record);
      }
      return;
    }
    _trace?.add(record);
  }

  void _start() {
    _processMetrics.reset();
    unawaited(_gpuMetrics.start());
    _tracing = true;
    _session = DateTime.now().toUtc().toIso8601String();
    _sequence = 0;
    for (final stats in _operations.values) {
      stats.take();
    }
    _elapsed
      ..reset()
      ..start();
    _frames.take();
    SchedulerBinding.instance.addTimingsCallback(_onFrames);
    _writeTrace({
      'type': 'session',
      'session': _session,
      'platform': Platform.operatingSystem,
      'runtime': Platform.version.split(' ').first,
      'notes': 'CPU 为进程用量；图片字节为缓存账面值，不能与 RSS 相加。Windows GPU 为本进程各显卡的引擎负载及显存用量/预算；Dart 堆和各模块独占内存未采集。HTTP 字节仅为服务端声明长度。',
    });
    _timer = Timer.periodic(
      Duration(milliseconds: _intervalMs),
      (_) => capture(),
    );
    capture();
  }

  void _onFrames(List<FrameTiming> timings) {
    if (!_tracing) return;
    final views = WidgetsBinding.instance.platformDispatcher.views;
    final rate = views.firstOrNull?.display.refreshRate ?? 60;
    _frames.add(timings, 1000000 / (rate > 0 ? rate : 60));
  }

  void capture() {
    if (!_tracing || _writesPaused) return;
    final cache = PaintingBinding.instance.imageCache;
    final sources = <String, Object?>{};
    for (final entry in _sources.entries.toList()) {
      try {
        sources[entry.key] = entry.value();
      } catch (_) {
        sources[entry.key] = {'available': false};
      }
    }
    Map<String, Object?> process;
    try {
      process = (processReader ?? _processMetrics.sample)();
    } catch (_) {
      process = {'available': false};
    }
    latest = {
      'type': 'sample',
      'runId': _runId,
      'processId': pid,
      if (_windowId != null) 'windowId': _windowId,
      'session': _session,
      'sequence': ++_sequence,
      'time': DateTime.now().toUtc().toIso8601String(),
      'elapsedMs': _elapsed.elapsedMilliseconds,
      'route': _route,
      'process': process,
      'frames': {
        ..._frames.take(),
        'displayRefreshRate': WidgetsBinding
            .instance
            .platformDispatcher
            .views
            .firstOrNull
            ?.display
            .refreshRate,
      },
      'images': {
        'cacheBytes': cache.currentSizeBytes,
        'cacheEntries': cache.currentSize,
        'liveImages': cache.liveImageCount,
        'pendingImages': cache.pendingImageCount,
        'limitBytes': cache.maximumSizeBytes,
      },
      'operations': {
        for (final entry in _operations.entries) entry.key: entry.value.take(),
      },
      'gauges': Map<String, num>.of(_gauges),
      'sources': sources,
      'diagnostics': {
        'droppedRecords': droppedRecords,
        'storageError': storageError,
      },
    };
    latest = Map<String, Object?>.from(DiagnosticRedactor.clean(latest) as Map);
    // GPU 引擎列表使用独立预算，避免挤占播放器和采集器状态字段。
    if (Platform.isWindows) {
      latest!['gpu'] = DiagnosticRedactor.clean(_gpuMetrics.sample());
    }
    _writeTrace(latest!);
    _notifySoon();
  }

  void _stop() {
    unawaited(_gpuMetrics.stop());
    capture();
    _tracing = false;
    _timer?.cancel();
    _timer = null;
    _elapsed.stop();
    SchedulerBinding.instance.removeTimingsCallback(_onFrames);
    _writeTrace({
      'type': 'stop',
      'session': _session,
      'time': DateTime.now().toUtc().toIso8601String(),
    });
  }

  void _notifySoon() {
    _notification ??= Timer(const Duration(milliseconds: 250), () {
      _notification = null;
      notifyListeners();
    });
  }

  /// 子窗口独立落盘，导出时同时收集断连期间的现场和性能采样。
  Future<List<File>> _childFiles() async {
    final directory = _directory;
    if (_childProcess || directory == null || !directory.existsSync()) {
      return [];
    }
    final files = <File>[];
    await for (final entry in directory.list(followLinks: false)) {
      if (entry is! Directory ||
          !RegExp(
            r'^window-\d+$',
          ).hasMatch(entry.uri.pathSegments.where((s) => s.isNotEmpty).last)) {
        continue;
      }
      await for (final file in entry.list(followLinks: false)) {
        if (file is File &&
            RegExp(
              r'^(?:(runtime|player|performance)\.jsonl(\.[0-9]+)?|status\.json)$',
            ).hasMatch(file.uri.pathSegments.last)) {
          files.add(file);
        }
      }
    }
    return files;
  }

  Future<List<Object?>> _childStatuses() async {
    final statuses = <Object?>[];
    for (final file in await _childFiles()) {
      if (file.uri.pathSegments.last == 'status.json') {
        statuses.add(
          DiagnosticRedactor.clean(jsonDecode(await file.readAsString())),
        );
      }
    }
    return statuses;
  }

  Future<List<String>> _childSnapshots(Directory destination) async {
    final paths = <String>[];
    for (final file in await _childFiles()) {
      final parts = file.uri.pathSegments;
      final name = '${parts[parts.length - 2]}-${parts.last}';
      try {
        paths.add((await file.copy('${destination.path}/$name')).path);
      } on FileSystemException {
        if (file.existsSync()) rethrow;
      }
    }
    return paths;
  }

  Future<List<File>> files() async => [
    ...await _childFiles(),
    ...?await _logs?.files(),
    ...?await _playerLogs?.files(),
    ...?await _trace?.files(),
    ...?await _legacyReports?.files(),
  ];
  Future<void> flushLocal() async {
    await _logs?.flush();
    await _playerLogs?.flush();
    await _trace?.flush();
    if (_childProcess && _directory != null) {
      await _directory!.create(recursive: true);
      await File('${_directory!.path}/status.json').writeAsString(
        jsonEncode(
          DiagnosticRedactor.clean({
            'time': DateTime.now().toUtc().toIso8601String(),
            'runId': _runId,
            'processId': pid,
            'windowId': _windowId,
            'storage': storageStatus,
            'droppedRecords': droppedRecords,
          }),
        ),
      );
    }
  }

  Future<void> flush() async {
    await _writesResumed?.future;
    await flushLocal();
    await forwardFlush?.call();
  }

  Future<void> clear() async {
    await _maintain(() async {
      if (_tracing) await configure(tracing: false);
      await clearChildren?.call();
      await _clear();
    });
  }

  Future<void> clearPausedRecords() {
    if (!_writesPaused) throw StateError('清除子窗口日志前须暂停写入');
    return _clear();
  }

  Future<void> _clear() async {
    _deferred.clear();
    _deferredTrace.clear();
    await _logs?.clear();
    await _playerLogs?.clear();
    await _trace?.clear();
    await _legacyReports?.clear();
    for (final file in await _childFiles()) {
      if (file.existsSync()) await file.delete();
    }
    _recent.clear();
    latest = null;
    notifyListeners();
  }

  /// 文件快照和压缩都使用本地文件，压缩移到后台 isolate。
  Future<File> exportArchive() async {
    final directory = await Directory.systemTemp.createTemp(
      'pili-diagnostics-',
    );
    try {
      final paths = await _maintain(() async {
        final paths = [
          ...?await _logs?.snapshot(directory),
          ...?await _playerLogs?.snapshot(directory),
          ...?await _trace?.snapshot(directory),
          ...await _legacySnapshots(directory),
          ...await _childSnapshots(directory),
        ];
        final manifest = File('${directory.path}/manifest.json');
        await manifest.writeAsString(
          jsonEncode({
            'schema': 2,
            'runId': _runId,
            'storage': storageStatus,
            'children': await _childStatuses(),
            'platform': Platform.operatingSystem,
            'created': DateTime.now().toUtc().toIso8601String(),
            'level': _level.name,
            'playerLevel': _playerLevel.name,
            'intervalMs': _intervalMs,
            'droppedRecords': droppedRecords,
            'app': DiagnosticRedactor.clean(_sources['app']?.call()),
            'notes': '每条 sample 为一个采样周期。RSS/私有提交/缓存值不可相加；null 表示未提供。无 GPU、Dart 堆和各模块独占内存数据。',
          }),
        );
        paths.add(manifest.path);
        return paths;
      });
      final output = '${directory.path}/diagnostics.zip';
      await compute(_zip, (paths, output));
      return File(output);
    } catch (_) {
      try {
        await directory.delete(recursive: true);
      } catch (_) {
        // 清理失败不覆盖真正的导出错误。
      }
      rethrow;
    }
  }

  Future<List<String>> _legacySnapshots(Directory directory) async {
    final paths = <String>[];
    for (final source
        in await _legacyReports?.snapshot(directory) ?? <String>[]) {
      // 早期版本保存过原始报告；导出时重新脱敏，历史文件保持原样。
      final output = File('$source.sanitized');
      final sink = output.openWrite();
      try {
        await for (final line
            in File(source)
                .openRead()
                .transform(const Utf8Decoder(allowMalformed: true))
                .transform(const LineSplitter())) {
          try {
            sink.writeln(
              jsonEncode(DiagnosticRedactor.clean(jsonDecode(line))),
            );
          } on FormatException {
            // 跳过中断写入留下的不完整报告。
          }
        }
      } finally {
        await sink.close();
      }
      await output.rename(source);
      paths.add(source);
    }
    return paths;
  }

  static Future<void> _zip((List<String>, String) args) async {
    final encoder = ZipFileEncoder()..create(args.$2);
    try {
      for (final path in args.$1) {
        await encoder.addFile(File(path));
      }
    } finally {
      await encoder.close();
    }
  }

  String snapshotText() =>
      const JsonEncoder.withIndent('  ').convert(latest ?? {});

  @override
  void dispose() {
    if (_tracing) _stop();
    _notification?.cancel();
    _pauseTimeout?.cancel();
    if (_observingLifecycle) WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}

class TraceOperation {
  TraceOperation._(
    this._owner,
    this._category,
    this._action,
    this._details,
    this._stats,
  );
  final Diagnostics _owner;
  final String _category;
  final String _action;
  final Map<String, Object?>? _details;
  final _OperationStats _stats;
  final _watch = Stopwatch()..start();
  bool _done = false;

  void finish({
    Object? error,
    StackTrace? stack,
    Map<String, Object?>? details,
  }) {
    if (_done) return;
    _done = true;
    final milliseconds = _watch.elapsedMicroseconds / 1000;
    _stats
      ..active -= 1
      ..completed += 1
      ..totalMs += milliseconds;
    if (milliseconds > _stats.maxMs) _stats.maxMs = milliseconds;
    if (error != null) _stats.errors++;
    _owner.log(
      error == null ? DiagnosticLogLevel.debug : DiagnosticLogLevel.error,
      _category,
      _action,
      stack: stack,
      details: {
        ...?_details,
        ...?details,
        'durationMs': milliseconds,
        'error': ?error,
      },
    );
  }
}

class _OperationStats {
  int active = 0, completed = 0, errors = 0;
  double totalMs = 0, maxMs = 0;
  Map<String, Object?> take() {
    final result = <String, Object?>{
      'active': active,
      'completed': completed,
      'errors': errors,
      'averageMs': completed == 0 ? null : totalMs / completed,
      'maxMs': maxMs,
    };
    completed = errors = 0;
    totalMs = maxMs = 0;
    return result;
  }
}

class _FrameStats {
  final _slowDetails = <Map<String, Object?>>[];
  int count = 0, slow = 0, zeroBuild = 0;
  double build = 0, raster = 0, maxBuild = 0, maxRaster = 0;
  void add(List<FrameTiming> timings, double budgetUs) {
    for (final frame in timings) {
      count++;
      if (frame.buildDuration == Duration.zero) zeroBuild++;
      final b = frame.buildDuration.inMicroseconds / 1000;
      final r = frame.rasterDuration.inMicroseconds / 1000;
      build += b;
      raster += r;
      if (b > maxBuild) maxBuild = b;
      if (r > maxRaster) maxRaster = r;
      if (frame.buildDuration.inMicroseconds > budgetUs ||
          frame.rasterDuration.inMicroseconds > budgetUs) {
        slow++;
        if (_slowDetails.length < 16) {
          final finish = frame.timestampInMicroseconds(
            FramePhase.rasterFinishWallTime,
          );
          final start =
              finish -
              (frame.timestampInMicroseconds(FramePhase.rasterFinish) -
                  frame.timestampInMicroseconds(FramePhase.buildStart));
          _slowDetails.add({
            'buildStartUtc': DateTime.fromMicrosecondsSinceEpoch(
              start,
              isUtc: true,
            ).toIso8601String(),
            'rasterFinishUtc': DateTime.fromMicrosecondsSinceEpoch(
              finish,
              isUtc: true,
            ).toIso8601String(),
            'buildMs': b,
            'rasterMs': r,
            'totalMs': frame.totalSpan.inMicroseconds / 1000,
          });
        }
      }
    }
  }

  Map<String, Object?> take() {
    final result = <String, Object?>{
      'count': count,
      'zeroBuildFrames': zeroBuild,
      'slowFrames': slow,
      'averageBuildMs': count == 0 ? null : build / count,
      'averageRasterMs': count == 0 ? null : raster / count,
      'maxBuildMs': maxBuild,
      'maxRasterMs': maxRaster,
      // FrameTiming 会延迟批量回报，使用真实帧时刻对齐导航和请求。
      'slowFrameDetails': List<Map<String, Object?>>.of(_slowDetails),
    };
    count = slow = zeroBuild = 0;
    _slowDetails.clear();
    build = raster = maxBuild = maxRaster = 0;
    return result;
  }
}

class DiagnosticRouteObserver extends NavigatorObserver {
  final _routes = <Route<dynamic>>[];

  void _reportPage() {
    // 弹窗仍属于下方页面，不能把未命名的菜单或对话框记成首页。
    final page = _routes.whereType<PageRoute<dynamic>>().lastOrNull;
    Diagnostics.instance.routeChanged(
      page == null ? '/' : page.settings.name ?? '<unnamed-page>',
    );
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.add(route);
    _reportPage();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    _reportPage();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
    _reportPage();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final index = oldRoute == null ? -1 : _routes.indexOf(oldRoute);
    if (index >= 0) {
      if (newRoute == null) {
        _routes.removeAt(index);
      } else {
        _routes[index] = newRoute;
      }
    }
    _reportPage();
  }
}
