import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/grpc/bilibili/community/service/dm/v1.pb.dart';
import 'package:pili_aurora/pages/danmaku/file_reader.dart';
import 'package:pili_aurora/services/danmaku/work_quota.dart';

Future<File> _fixture(List<int> bytes) async {
  final directory = await Directory.systemTemp.createTemp(
    'pili-danmaku-reader-',
  );
  final file = File('${directory.path}/danmaku.pb');
  addTearDown(() async {
    await file.delete();
    await directory.delete();
  });
  await file.writeAsBytes(bytes);
  return file;
}

void main() {
  test(
    'field-wise reading matches protobuf across buffers and batch boundaries',
    () async {
      final reply = DmSegMobileReply(
        elems: [
          DanmakuElem(content: '长' * 35000, progress: 360100, mode: 7),
          for (var i = 0; i < 8; i++) DanmakuElem(content: '条目$i', progress: i),
        ],
        state: 1,
        contextSrc: 'metadata' * 10000,
      );
      final encoded = reply.writeToBuffer();
      final file = await _fixture(encoded);
      final batches = await readDanmakuFile(
        file,
        batchElements: 2,
        batchBytes: 2048,
      ).toList();
      expect(batches.every((batch) => batch.length <= 2), isTrue);
      expect(
        batches.expand((b) => b).map((e) => e.writeToBuffer()),
        DmSegMobileReply.fromBuffer(encoded).elems
            .map((e) => e.writeToBuffer()),
      );
    },
  );

  test(
    'unknown scalar, fixed and group fields do not change elements',
    () async {
      final message = DmSegMobileReply(elems: [DanmakuElem(content: 'keep')])
          .writeToBuffer();
      final file = await _fixture([
        0x48,
        1,
        0x51,
        ...List.filled(8, 0),
        0x5a,
        3,
        1,
        2,
        3,
        0x65,
        ...List.filled(4, 0),
        0x6b,
        0x70,
        1,
        0x6c,
        ...message,
      ]);
      final batches = await readDanmakuFile(file).toList();
      expect(batches.single.single.content, 'keep');
    },
  );

  test(
    'truncated and malformed fields fail rather than return partial success',
    () async {
      for (final bytes in <List<int>>[
        [10, 5, 1],
        [0],
        [0x48, 0x80],
        [0x51, 1],
        [0x6b, 0x74],
        [0x4e],
        [10, ...List.filled(10, 0xff)],
      ]) {
        final file = await _fixture(bytes);
        await expectLater(
          readDanmakuFile(file).drain<void>(),
          throwsFormatException,
        );
      }
    },
  );

  test('empty file and cancellation terminate reading', () async {
    final empty = await _fixture([]);
    expect(await readDanmakuFile(empty).toList(), isEmpty);
    final file = await _fixture(
      DmSegMobileReply(
        elems: [
          DanmakuElem(content: 'first'),
          DanmakuElem(content: 'second'),
        ],
      ).writeToBuffer(),
    );
    final token = DanmakuWorkToken();
    await expectLater(() async {
      await for (final _ in readDanmakuFile(
        file,
        token: token,
        batchElements: 1,
      )) {
        token.cancel();
      }
    }(), throwsA(isA<DanmakuWorkCancelled>()));
  });
}
