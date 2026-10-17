import 'dart:convert';
import 'dart:io';
import 'dart:ui' show FrameTiming;

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/services/diagnostics/diagnostics.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late Diagnostics diagnostics;
  var reads = 0;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('pili-diagnostics-test-');
    reads = 0;
    diagnostics = Diagnostics(
      processReader: () {
        reads++;
        return {'rssBytes': 123456, 'privateBytes': null};
      },
    );
    await diagnostics.initialize(directory: directory);
  });
  tearDown(() async {
    diagnostics.dispose();
    await diagnostics.flush();
    await directory.delete(recursive: true);
  });

  test('player traffic preserves runtime warnings and route context', () {
    diagnostics
      ..routeChanged('/video?token=fixture')
      ..log(DiagnosticLogLevel.warning, 'app', 'keep warning');
    for (var i = 0; i < 250; i++) {
      diagnostics.playerLog(DiagnosticLogLevel.info, 'mpv', 'frame $i');
    }
    expect(diagnostics.recentLogs, hasLength(201));
    final warning = diagnostics.recentLogs.last;
    expect(warning['message'], 'keep warning');
    expect(warning['route'], '/video');
    expect(warning['processId'], pid);
  });

  test('pre-initialization records are persisted on initialization', () async {
    final early = Diagnostics()
      ..log(DiagnosticLogLevel.error, 'bootstrap', 'startup failed');
    final target = Directory('${directory.path}/early');
    await early.initialize(directory: target);
    await early.flush();
    expect(
      await File('${target.path}/runtime.jsonl').readAsString(),
      contains('startup failed'),
    );
    expect(early.recentLogs, hasLength(1));
    early.dispose();
  });

  test('forwarded records retain origin and redact private data', () async {
    diagnostics.receiveRecord({
      'channel': 'player',
      'level': 'error',
      'processId': 123,
      'route': '/video',
      'message': 'decoder failed',
      'details': {'deviceId': 'fixture-device', 'token': 'fixture-token'},
    }, windowId: 4);
    await diagnostics.flush();
    final record = diagnostics.recentLogs.single;
    expect(record['processId'], 123);
    expect(record['windowId'], 4);
    final text = await File('${directory.path}/player.jsonl').readAsString();
    expect(text, isNot(contains('fixture-device')));
    expect(text, isNot(contains('fixture-token')));
  });

  test('flush awaits the forwarding acknowledgement', () async {
    var acknowledged = false;
    diagnostics.forwardFlush = () async {
      await Future<void>.delayed(Duration.zero);
      acknowledged = true;
    };
    await diagnostics.flush();
    expect(acknowledged, isTrue);
  });

  test('delayed forwarded records are displayed by origin time', () {
    diagnostics
      ..log(DiagnosticLogLevel.error, 'app', 'newer')
      ..receiveRecord({
        'time': '2000-01-01T00:00:00.000Z',
        'channel': 'runtime',
        'level': 'error',
        'message': 'older',
      }, windowId: 2);
    expect(diagnostics.recentLogs.map((record) => record['message']), [
      'newer',
      'older',
    ]);
  });

  test(
    'forwarding failure preserves local logs and child performance export',
    () async {
      final child = Diagnostics(processReader: () => {'rssBytes': 42});
      await child.initialize(
        directory: Directory('${directory.path}/window-2'),
        childProcess: true,
      );
      child
        ..forwardRecord = ((_) => false)
        ..log(DiagnosticLogLevel.error, 'app', 'offline failure');
      await child.configure(tracing: true);
      child.capture();
      await child.configure(tracing: false);
      await child.flush();
      expect(child.forwardingFailures, 1);
      expect(child.droppedRecords, 0);
      expect(
        await File('${directory.path}/window-2/runtime.jsonl').readAsString(),
        contains('offline failure'),
      );
      expect(
        await File('${directory.path}/window-2/performance.jsonl')
            .readAsString(),
        contains('rssBytes'),
      );
      final archive = await diagnostics.exportArchive();
      try {
        final zip = ZipDecoder().decodeBytes(await archive.readAsBytes());
        expect(
          zip.files.map((file) => file.name),
          containsAll(['window-2-runtime.jsonl', 'window-2-performance.jsonl']),
        );
      } finally {
        await archive.parent.delete(recursive: true);
        child.dispose();
      }
      await diagnostics.clear();
      expect(
        File('${directory.path}/window-2/runtime.jsonl').existsSync(),
        isFalse,
      );
    },
  );

  test(
    'settings changes notify once and expose effective configuration',
    () async {
      var changes = 0;
      diagnostics.onSettingsChanged = () => changes++;
      await diagnostics.configure(
        level: DiagnosticLogLevel.debug,
        playerLevel: DiagnosticLogLevel.error,
        intervalMs: 250,
      );
      expect(changes, 1);
      expect(diagnostics.settings, {
        'level': 'debug',
        'playerLevel': 'error',
        'intervalMs': 250,
        'tracing': false,
      });
    },
  );

  test(
    'export coordinates child flush and includes its forwarding status',
    () async {
      final child = Diagnostics();
      await child.initialize(
        directory: Directory('${directory.path}/window-3'),
        childProcess: true,
        windowId: 3,
      );
      child
        ..forwardRecord = ((_) => false)
        ..log(DiagnosticLogLevel.error, 'app', 'queued before snapshot');
      diagnostics
        ..pauseChildren = () async {
          await child.pauseWrites();
          child.log(DiagnosticLogLevel.error, 'app', 'during snapshot');
        }
        ..resumeChildren = (() => Future<void>.sync(child.resumeWrites));
      final archive = await diagnostics.exportArchive();
      try {
        final zip = ZipDecoder().decodeBytes(await archive.readAsBytes());
        final text = utf8.decode(
          zip.files
                  .firstWhere((f) => f.name == 'window-3-runtime.jsonl')
                  .content
              as List<int>,
        );
        expect(text, contains('queued before snapshot'));
        expect(text, isNot(contains('during snapshot')));
        final manifest = jsonDecode(
          utf8.decode(
            zip.files.firstWhere((f) => f.name == 'manifest.json').content
                as List<int>,
          ),
        ) as Map;
        final status = (manifest['children'] as List).single as Map;
        expect((status['storage'] as Map)['forwardingFailures'], 1);
        await child.flushLocal();
        expect(
          await File('${directory.path}/window-3/runtime.jsonl').readAsString(),
          contains('during snapshot'),
        );
      } finally {
        child.dispose();
        await child.flushLocal();
        await archive.parent.delete(recursive: true);
      }
    },
  );

  test(
    'clear coordinates child queues and retains records created afterward',
    () async {
      final child = Diagnostics();
      await child.initialize(
        directory: Directory('${directory.path}/window-4'),
        childProcess: true,
      );
      child.log(DiagnosticLogLevel.error, 'app', 'old record');
      diagnostics
        ..pauseChildren = child.pauseWrites
        ..clearChildren = () async {
          child.log(DiagnosticLogLevel.error, 'app', 'stale deferred record');
          await child.clearPausedRecords();
          child.log(DiagnosticLogLevel.error, 'app', 'after clear');
        }
        ..resumeChildren = (() => Future<void>.sync(child.resumeWrites));
      await diagnostics.clear();
      await child.flushLocal();
      final text = await File('${directory.path}/window-4/runtime.jsonl')
          .readAsString();
      expect(text, contains('after clear'));
      expect(text, isNot(contains('old record')));
      expect(text, isNot(contains('stale deferred record')));
      child.dispose();
    },
  );

  test('failed child coordination resumes writes and permits retry', () async {
    var resumes = 0;
    diagnostics
      ..pauseChildren = (() => Future<void>.error(StateError('not connected')))
      ..resumeChildren = () async {
        resumes++;
      };
    await expectLater(diagnostics.exportArchive(), throwsStateError);
    expect(resumes, 1);
    diagnostics.log(DiagnosticLogLevel.error, 'app', 'after failure');
    await diagnostics.flushLocal();
    expect(
      await File('${directory.path}/runtime.jsonl').readAsString(),
      contains('after failure'),
    );
    diagnostics.pauseChildren = null;
    final archive = await diagnostics.exportArchive();
    await archive.parent.delete(recursive: true);
  });

  test(
    'closing flush waits for paused records to resume and persist',
    () async {
      await diagnostics.pauseWrites();
      diagnostics.log(DiagnosticLogLevel.error, 'window', 'late cleanup error');
      var flushed = false;
      final flush = diagnostics.flush().then((_) {
        flushed = true;
      });
      await Future<void>.delayed(Duration.zero);
      expect(flushed, isFalse);
      diagnostics.resumeWrites();
      await flush;
      expect(
        await File('${directory.path}/runtime.jsonl').readAsString(),
        contains('late cleanup error'),
      );
    },
  );

  test('paused buffer is byte bounded and prioritizes errors', () async {
    await diagnostics.pauseWrites();
    final chunk = 'x' * 65000;
    for (var i = 0; i < 40; i++) {
      diagnostics.playerLog(
        DiagnosticLogLevel.info,
        'mpv',
        chunk,
        details: {'a': chunk, 'b': chunk, 'c': chunk, 'd': chunk},
      );
    }
    diagnostics.playerLog(DiagnosticLogLevel.error, 'mpv', 'critical failure');
    final status = diagnostics.storageStatus['pausedBuffer'] as Map;
    expect(
      status['pendingBytes'],
      lessThanOrEqualTo(Diagnostics.maxDeferredBytes),
    );
    expect(status['pendingRecords'], lessThan(40));
    expect(diagnostics.droppedRecords, greaterThan(0));
    diagnostics.resumeWrites();
    await diagnostics.flush();
    expect(
      await File('${directory.path}/player.jsonl').readAsString(),
      contains('critical failure'),
    );
  });

  test('full paused queue evicts debug records for errors', () async {
    await diagnostics.configure(level: DiagnosticLogLevel.debug);
    await diagnostics.pauseWrites();
    final first = diagnostics.log(
      DiagnosticLogLevel.debug,
      'app',
      'old debug',
    )!;
    for (var i = 1; i < 400; i++) {
      diagnostics.log(DiagnosticLogLevel.debug, 'app', 'debug $i');
    }
    final error = diagnostics.log(
      DiagnosticLogLevel.error,
      'app',
      'keep error',
    )!;
    expect(await first.accepted, isFalse);
    expect(diagnostics.droppedRecords, 1);
    diagnostics.resumeWrites();
    expect(await error.accepted, isTrue);
    await diagnostics.flush();
    final text = await File('${directory.path}/runtime.jsonl').readAsString();
    expect(text, contains('keep error'));
    expect(text, isNot(contains('old debug')));
  });

  test(
    'uncoordinated child files are preserved and marked in export',
    () async {
      final childDirectory = Directory('${directory.path}/window-9');
      await childDirectory.create();
      final file = File('${childDirectory.path}/runtime.jsonl');
      await file.writeAsString('offline record');
      diagnostics.pauseChildren = () async {
        diagnostics.skippedChildWindows.add(9);
      };
      final archive = await diagnostics.exportArchive();
      try {
        final zip = ZipDecoder().decodeBytes(await archive.readAsBytes());
        expect(
          zip.files.map((file) => file.name),
          isNot(contains('window-9-runtime.jsonl')),
        );
        final manifest = jsonDecode(
          utf8.decode(
            zip.files.firstWhere((file) => file.name == 'manifest.json').content
                as List<int>,
          ),
        ) as Map;
        expect((manifest['storage'] as Map)['skippedChildWindows'], [9]);
        await diagnostics.clear();
        expect(await file.readAsString(), 'offline record');
      } finally {
        await archive.parent.delete(recursive: true);
      }
    },
  );

  test('levels change immediately and recent logs stay bounded', () async {
    diagnostics.log(DiagnosticLogLevel.debug, 'test', 'hidden');
    expect(diagnostics.recentLogs, isEmpty);
    await diagnostics.configure(level: DiagnosticLogLevel.debug);
    for (var i = 0; i < 250; i++) {
      diagnostics.log(DiagnosticLogLevel.debug, 'test', 'record $i');
    }
    expect(diagnostics.recentLogs, hasLength(200));
    expect(diagnostics.recentLogs.first['message'], 'record 249');
    await diagnostics.configure(level: DiagnosticLogLevel.off);
    diagnostics.log(DiagnosticLogLevel.error, 'test', 'hidden error');
    expect(diagnostics.recentLogs.first['message'], 'record 249');
  });

  test('slow frames keep bounded wall times and reset after capture', () async {
    await diagnostics.configure(tracing: true);
    const finish = 1700000000000000;
    final timings = List.generate(
      80,
      (_) => FrameTiming(
        vsyncStart: 0,
        buildStart: 1000,
        buildFinish: 21000,
        rasterStart: 22000,
        rasterFinish: 52000,
        rasterFinishWallTime: finish,
      ),
    );
    TestWidgetsFlutterBinding.instance.platformDispatcher.onReportTimings!(
      timings,
    );
    diagnostics.capture();
    final frames = diagnostics.latest!['frames'] as Map;
    final details = frames['slowFrameDetails'] as List;
    expect(frames['count'], 80);
    expect(frames['slowFrames'], 80);
    expect(details, hasLength(16));
    expect(details.first, containsPair('buildMs', 20.0));
    expect(details.first, containsPair('rasterMs', 30.0));
    expect(
      details.first,
      containsPair(
        'buildStartUtc',
        DateTime.fromMicrosecondsSinceEpoch(
          finish - 51000,
          isUtc: true,
        ).toIso8601String(),
      ),
    );
    diagnostics.capture();
    expect((diagnostics.latest!['frames'] as Map)['slowFrameDetails'], isEmpty);
  });

  test(
    'tracking is opt in and snapshots include current module data',
    () async {
      diagnostics.capture();
      expect(reads, 0);
      final detach = diagnostics.register(
        'player',
        () => {'width': 1920, 'buffering': true},
      );
      await diagnostics.configure(tracing: true, intervalMs: 250);
      diagnostics.begin('http', 'GET')!
        ..finish()
        ..finish();
      diagnostics.capture();
      expect(diagnostics.latest!['process'], containsPair('rssBytes', 123456));
      expect(
        (diagnostics.latest!['operations'] as Map)['http'],
        containsPair('completed', 1),
      );
      expect(
        (diagnostics.latest!['sources'] as Map)['player'],
        containsPair('width', 1920),
      );
      detach();
      diagnostics.capture();
      expect(diagnostics.latest!['sources'], isEmpty);
      await diagnostics.configure(tracing: false);
      final stoppedReads = reads;
      diagnostics.capture();
      expect(reads, stoppedReads);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(reads, stoppedReads);
    },
  );

  test(
    'settings and bounded history survive a restart, then can be cleared',
    () async {
      Map<String, Object?> settings = {};
      final first = Diagnostics(processReader: () => {});
      await first.initialize(
        directory: directory,
        saveSettings: (value) async => settings = value,
      );
      await first.configure(
        tracing: true,
        level: DiagnosticLogLevel.debug,
        intervalMs: 250,
      );
      for (var i = 0; i < 205; i++) {
        first.log(DiagnosticLogLevel.info, 'test', 'history $i');
      }
      first.dispose();
      await first.flush();
      await File('${directory.path}/runtime.jsonl').writeAsString(
        'incomplete record\n',
        mode: FileMode.append,
      );
      final restored = Diagnostics(processReader: () => {});
      try {
        await restored.initialize(
          directory: directory,
          level: DiagnosticLogLevel.parse(settings['level'] as String),
          tracing: settings['tracing'] as bool,
          intervalMs: settings['intervalMs'] as int,
        );
        expect(restored.level, DiagnosticLogLevel.debug);
        expect(restored.tracing, isTrue);
        expect(restored.intervalMs, 250);
        expect(restored.recentLogs, hasLength(200));
        expect(restored.recentLogs.first['message'], 'history 204');
        expect(restored.recentLogs.last['message'], 'history 5');
        await restored.clear();
        expect(restored.tracing, isFalse);
        expect(restored.recentLogs, isEmpty);
        expect(await restored.files(), isEmpty);
        restored.log(DiagnosticLogLevel.error, 'test', 'after clear');
        await restored.flush();
        expect(await restored.files(), hasLength(1));
      } finally {
        restored.dispose();
        await restored.flush();
      }
    },
  );

  test(
    'export contains readable sanitized logs and performance records',
    () async {
      await diagnostics.configure(
        tracing: true,
        level: DiagnosticLogLevel.debug,
      );
      diagnostics.log(
        DiagnosticLogLevel.debug,
        'test',
        "token=export-secret-test\nAudio 'track.m4s?e=export-signed-query&mid=export-user-id' (aac)",
      );
      final file = await diagnostics.exportArchive();
      try {
        final archive = ZipDecoder().decodeBytes(await file.readAsBytes());
        expect(
          archive.files.map((file) => file.name),
          containsAll(['runtime.jsonl', 'performance.jsonl', 'manifest.json']),
        );
        for (final entry in archive.files) {
          final content = utf8.decode(entry.content);
          expect(content, isNot(contains('export-secret-test')));
          expect(content, isNot(contains('export-signed-query')));
          expect(content, isNot(contains('export-user-id')));
          for (final line in const LineSplitter().convert(content)) {
            expect(jsonDecode(line), isA<Map>());
          }
        }
      } finally {
        await file.parent.delete(recursive: true);
      }
    },
  );
}
