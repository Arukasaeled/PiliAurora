import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/grpc/bilibili/community/service/dm/v1.pb.dart';
import 'package:pili_aurora/pages/danmaku/file_store.dart';

// 按需运行：fvm flutter test --no-pub
// tool/experiments/danmaku/file_order_reuse_test.dart
// --dart-define=DANMAKU_FILE_ORDER_ELEMENTS=12000
// 测量 Flutter 测试宿主 CPU/磁盘耗时；设备 RSS、GPU 由设备实验采集。
const _elementCount = int.fromEnvironment(
  'DANMAKU_FILE_ORDER_ELEMENTS',
  defaultValue: 9000,
);

typedef _Entry = ({int progress, String id, String content});
typedef _Range = ({int start, int end});
typedef _Artifact = ({String path, int bytes, DateTime modified});
typedef _RangeScan = ({int elements, int batches});

DanmakuElem _element(int index) => DanmakuElem(
  progress: ((_elementCount - 1 - index) ~/ 3) * 100,
  mode: 1,
  fontsize: 25,
  color: 0xffffff,
  midHash: 'host-experiment',
  idStr: '$index',
  content: '弹幕$index：文件范围重读成本🙂',
);

_Entry _entry(DanmakuElem element) => (
  progress: element.progress,
  id: element.idStr,
  content: element.content,
);

Future<void> _writeFixture(File file) async {
  final writer = await file.open(mode: FileMode.write);
  try {
    for (var index = 0; index < _elementCount; index++) {
      final encoded = _element(index).writeToBuffer();
      var length = encoded.length;
      final header = <int>[10];
      while (length >= 128) {
        header.add((length & 127) | 128);
        length >>= 7;
      }
      header.add(length);
      await writer.writeFrom(Uint8List.fromList(header));
      await writer.writeFrom(encoded);
    }
  } finally {
    await writer.close();
  }
}

List<_Entry> _expected(_Range range) {
  final selected = <({int sourceIndex, _Entry entry})>[];
  for (var index = 0; index < _elementCount; index++) {
    final element = _element(index);
    if (element.progress >= range.start && element.progress < range.end) {
      selected.add((sourceIndex: index, entry: _entry(element)));
    }
  }
  selected.sort((a, b) {
    final time = a.entry.progress.compareTo(b.entry.progress);
    return time == 0 ? a.sourceIndex.compareTo(b.sourceIndex) : time;
  });
  return [for (final item in selected) item.entry];
}

List<_Artifact> _artifacts(Directory parent) {
  final files = parent.listSync(recursive: true).whereType<File>().toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  return [
    for (final file in files)
      (
        path: file.path,
        bytes: file.statSync().size,
        modified: file.statSync().modified,
      ),
  ];
}

Future<_RangeScan> _measure({
  required String mode,
  required _Range range,
  required int rangeIndex,
  required int inputBytes,
  required Stream<List<DanmakuElem>> batches,
  required List<_Entry> expected,
  required bool reusesSortedArtifact,
}) async {
  final result = <_Entry>[];
  var decodedElements = 0;
  var decodedBatches = 0;
  final watch = Stopwatch()..start();
  await for (final batch in batches) {
    decodedBatches++;
    decodedElements += batch.length;
    for (final element in batch) {
      if (element.progress >= range.start && element.progress < range.end) {
        result.add(_entry(element));
      }
    }
    if (batch.last.progress >= range.end) break;
  }
  watch.stop();
  expect(result, expected, reason: '$mode range $rangeIndex');
  expect(result, isNotEmpty);
  // JSON 标记便于主线摘取，计时不作为通过阈值。
  // ignore: avoid_print
  print(
    'DANMAKU_FILE_ORDER ${jsonEncode({
      'scope': 'flutter_host_cpu_disk',
      'mode': mode,
      'rangeIndex': rangeIndex,
      'startMs': range.start,
      'endMs': range.end,
      'inputElements': _elementCount,
      'inputBytes': inputBytes,
      'returnedElements': result.length,
      'decodedRangeScanElements': decodedElements,
      'decodedRangeScanBatches': decodedBatches,
      'elapsedUs': watch.elapsedMicroseconds,
      'reusesSortedArtifact': reusesSortedArtifact,
    })}',
  );
  return (elements: decodedElements, batches: decodedBatches);
}

void main() {
  test(
    'compare repeated external rebuilds with cold and reused ordered runs',
    () async {
      expect(_elementCount, greaterThanOrEqualTo(1500));
      final root = await Directory.systemTemp.createTemp('pili-order-cost-');
      final parent = await Directory('${root.path}/runs').create();
      final source = File('${root.path}/source.pb');
      final store = OrderedDanmakuFileStore(temporaryParent: parent);
      addTearDown(() async {
        await store.dispose();
        if (source.existsSync()) await source.delete();
        await parent.delete();
        await root.delete();
      });
      await _writeFixture(source);
      final inputBytes = await source.length();
      const ranges = <_Range>[
        (start: 0, end: 20000),
        (start: 20000, end: 40000),
        (start: 10000, end: 30000),
      ];
      final expected = [for (final range in ranges) _expected(range)];
      final rebuiltScans = <_RangeScan>[];
      for (var index = 0; index < ranges.length; index++) {
        final scan = await _measure(
          mode: 'rebuild_each_range',
          range: ranges[index],
          rangeIndex: index,
          inputBytes: inputBytes,
          batches: readOrderedDanmakuFile(source, temporaryParent: parent),
          expected: expected[index],
          reusesSortedArtifact: false,
        );
        rebuiltScans.add(scan);
        expect(parent.listSync(), isEmpty);
      }
      List<_Artifact>? coldArtifacts;
      for (var index = 0; index < ranges.length; index++) {
        final scan = await _measure(
          mode: index == 0 ? 'store_cold' : 'store_reuse',
          range: ranges[index],
          rangeIndex: index,
          inputBytes: inputBytes,
          batches: store.read(source),
          expected: expected[index],
          reusesSortedArtifact: index > 0,
        );
        expect(scan, rebuiltScans[index]);
        final artifacts = _artifacts(parent);
        expect(artifacts, hasLength(1));
        if (coldArtifacts == null) {
          coldArtifacts = artifacts;
        } else {
          expect(artifacts, coldArtifacts);
        }
      }
      await store.dispose();
      expect(parent.listSync(), isEmpty);
      expect(await source.length(), inputBytes);
      // ignore: avoid_print
      print(
        'DANMAKU_FILE_ORDER ${jsonEncode({
          'cleanup': 'complete',
          'sourceBytesUnchanged': true,
          'reusedArtifactCount': coldArtifacts!.length,
        })}',
      );
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
