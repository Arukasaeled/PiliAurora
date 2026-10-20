import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/grpc/bilibili/community/service/dm/v1.pb.dart';
import 'package:pili_aurora/pages/danmaku/file_store.dart';
import 'package:pili_aurora/pages/danmaku/merge.dart';
import 'package:pili_aurora/pages/danmaku/processing_rules.dart';
import 'package:pili_aurora/services/danmaku/work_quota.dart';

void main() {
  test(
    'external runs preserve stable order, merge counts and clean up',
    () async {
      final directory = Directory.systemTemp.createTempSync('pili-sort-test-');
      final file = File('${directory.path}/source.pb');
      final elements = [
        for (var i = 0; i < 900; i++)
          DanmakuElem(
            content: 'text${i % 13}',
            mode: 1,
            progress: (899 - i) % 37 * 1000,
          ),
      ];
      await file.writeAsBytes(
        DmSegMobileReply(elems: elements).writeToBuffer(),
      );
      addTearDown(() {
        file.deleteSync();
        directory.deleteSync();
      });
      final expected = elements.indexed.toList()
        ..sort((a, b) {
          final time = a.$2.progress.compareTo(b.$2.progress);
          return time == 0 ? a.$1.compareTo(b.$1) : time;
        });
      final actual = await readOrderedDanmakuFile(
        file,
        temporaryParent: directory,
      ).expand((b) => b).toList();
      expect(
        actual.map((e) => e.writeToBuffer()),
        expected.map((e) => e.$2.writeToBuffer()),
      );
      final additions = <DanmakuElem>[];
      await DanmakuWorkQuota.instance.runWithLease(
        64 * 1024 * 1024,
        (lease) => processOrderedDanmakuBatches(
          readOrderedDanmakuFile(file, temporaryParent: directory),
          rules: DanmakuProcessingRules(),
          lease: lease,
          consume: (delta) {
            additions.addAll(delta.additions);
            for (final entry in delta.counts.entries) {
              additions[entry.key].count = entry.value;
            }
          },
        ),
      );
      final merged = DanmakuMerger().merge(elements);
      expect(
        additions.map((e) => (e.progress, e.content, e.count)),
        merged.map((e) => (e.progress, e.content, e.count)),
      );
      expect(directory.listSync(), hasLength(1));
    },
  );

  test('cancellation releases sorted runs and keeps original file', () async {
    final directory = Directory.systemTemp.createTempSync('pili-sort-cancel-');
    final file = File('${directory.path}/source.pb');
    await file.writeAsBytes(
      DmSegMobileReply(
        elems: [
          for (var i = 0; i < 600; i++)
            DanmakuElem(content: '$i', progress: 600 - i),
        ],
      ).writeToBuffer(),
    );
    addTearDown(() {
      file.deleteSync();
      directory.deleteSync();
    });
    final token = DanmakuWorkToken();
    await expectLater(() async {
      await for (final _ in readOrderedDanmakuFile(
        file,
        token: token,
        temporaryParent: directory,
      )) {
        token.cancel();
      }
    }(), throwsA(isA<DanmakuWorkCancelled>()));
    expect(directory.listSync(), hasLength(1));
  });
}
