import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:pili_aurora/grpc/bilibili/community/service/dm/v1.pb.dart';
import 'package:pili_aurora/pages/danmaku/file_reader.dart';
import 'package:pili_aurora/services/danmaku/work_quota.dart';

/// 原文件是重建依据；排序 run 在本次处理结束后全部释放。
/// 二路归并只保留两个输入批次，run 描述采用二进制进位，数量随文件对数增长。
Stream<List<DanmakuElem>> readOrderedDanmakuFile(
  File source, {
  DanmakuWorkToken? token,
  Directory? temporaryParent,
}) async* {
  final directory = await (temporaryParent ?? Directory.systemTemp).createTemp(
    'pili-danmaku-sort-',
  );
  final ownedFiles = <String>{};
  var nextId = 0;
  File newRun() {
    final file = File('${directory.path}/${nextId++}.pb');
    ownedFiles.add(file.path);
    return file;
  }

  Future<void> removeRun(File file) async {
    if (file.existsSync()) await file.delete();
    ownedFiles.remove(file.path);
  }

  Future<File> merge(File left, File right) async {
    final result = newRun();
    final writer = await result.open(mode: FileMode.write);
    final a = StreamIterator(_elements(left, token));
    final b = StreamIterator(_elements(right, token));
    try {
      var hasA = await a.moveNext();
      var hasB = await b.moveNext();
      while (hasA || hasB) {
        if (token?.isCancelled ?? false) throw const DanmakuWorkCancelled();
        // 左 run 来自较早的原始批次，相同时间戳始终优先选左侧。
        if (!hasB || (hasA && a.current.progress <= b.current.progress)) {
          await _writeElement(writer, a.current);
          hasA = await a.moveNext();
        } else {
          await _writeElement(writer, b.current);
          hasB = await b.moveNext();
        }
      }
    } finally {
      await a.cancel();
      await b.cancel();
      await writer.close();
    }
    await removeRun(left);
    await removeRun(right);
    return result;
  }

  try {
    final levels = <File?>[];
    await for (final batch in readDanmakuFile(source, token: token)) {
      final ordered = batch.indexed.toList()
        ..sort((a, b) {
          final time = a.$2.progress.compareTo(b.$2.progress);
          return time == 0 ? a.$1.compareTo(b.$1) : time;
        });
      var run = newRun();
      final writer = await run.open(mode: FileMode.write);
      try {
        for (final (_, element) in ordered) {
          if (token?.isCancelled ?? false) throw const DanmakuWorkCancelled();
          await _writeElement(writer, element);
        }
      } finally {
        await writer.close();
      }
      var level = 0;
      while (level < levels.length && levels[level] != null) {
        run = await merge(levels[level]!, run);
        levels[level] = null;
        level++;
      }
      if (level == levels.length) levels.add(null);
      levels[level] = run;
    }
    File? result;
    for (final run in levels.reversed) {
      if (run != null) result = result == null ? run : await merge(result, run);
    }
    if (result != null) yield* readDanmakuFile(result, token: token);
  } finally {
    // 仅删除本次创建并登记的文件；外部路径与原始来源不参与清理。
    for (final path in ownedFiles) {
      final file = File(path);
      if (file.existsSync()) await file.delete();
    }
    await directory.delete();
  }
}

Stream<DanmakuElem> _elements(File file, DanmakuWorkToken? token) async* {
  await for (final batch in readDanmakuFile(file, token: token)) {
    yield* Stream.fromIterable(batch);
  }
}

Future<void> _writeElement(RandomAccessFile writer, DanmakuElem element) async {
  final bytes = element.writeToBuffer();
  var length = bytes.length;
  final header = <int>[10];
  while (length >= 128) {
    header.add((length & 0x7f) | 0x80);
    length >>= 7;
  }
  header.add(length);
  await writer.writeFrom(Uint8List.fromList(header));
  await writer.writeFrom(bytes);
}
