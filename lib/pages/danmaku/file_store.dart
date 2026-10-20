import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:pili_aurora/grpc/bilibili/community/service/dm/v1.pb.dart';
import 'package:pili_aurora/pages/danmaku/file_reader.dart';
import 'package:pili_aurora/pages/danmaku/element_size.dart';
import 'package:pili_aurora/services/danmaku/work_quota.dart';

/// 两路读取的编码/解码批次、排序索引、写出编码及文件缓冲。
const orderedDanmakuFileWorkBytes =
    8 * DanmakuProcessingBudget.batchBytes +
    DanmakuProcessingBudget.maxElementEncodedBytes +
    DanmakuProcessingBudget.batchElements * 64 +
    128 * 1024;

/// 一次性有序读取；来源长期复用时持有 [OrderedDanmakuFileStore]。
Stream<List<DanmakuElem>> readOrderedDanmakuFile(
  File source, {
  DanmakuWorkToken? token,
  Directory? temporaryParent,
}) async* {
  final store = OrderedDanmakuFileStore(temporaryParent: temporaryParent);
  try {
    yield* store.read(source, token: token);
  } finally {
    await store.dispose();
  }
}

/// 排序产物归来源所有，规则和范围变化仅取消消费。
/// 来源串行调用读取与文件检查；释放等待当前读取关闭句柄。
class OrderedDanmakuFileStore {
  OrderedDanmakuFileStore({this.temporaryParent});

  final Directory? temporaryParent;
  final _lifetime = DanmakuWorkToken();
  ({String path, int size, DateTime modified, DateTime changed})? _identity;
  _OrderedRun? _run;
  Future<_OrderedRun>? _building;
  Future<void>? _disposing;
  int _readers = 0;
  Completer<void>? _idle;

  /// 返回原文件是否变化。调用方在复用已处理范围前也需核对。
  Future<bool> updateSource(File source) async {
    if (_lifetime.isCancelled) throw const DanmakuWorkCancelled();
    final stat = source.statSync();
    if (stat.type != FileSystemEntityType.file) {
      final old = _run;
      _run = null;
      _identity = null;
      await old?.dispose();
      throw FileSystemException('弹幕文件不存在', source.path);
    }
    final identity = (
      path: source.absolute.path,
      size: stat.size,
      modified: stat.modified,
      changed: stat.changed,
    );
    if (_identity == identity) return false;
    final building = _building;
    if (building != null) await building;
    final old = _run;
    _run = null;
    _identity = identity;
    await old?.dispose();
    return true;
  }

  Stream<List<DanmakuElem>> read(
    File source, {
    DanmakuWorkToken? token,
  }) async* {
    if (_lifetime.isCancelled) throw const DanmakuWorkCancelled();
    _readers++;
    try {
      await updateSource(source);
      if (token?.isCancelled ?? false) throw const DanmakuWorkCancelled();
      final identity = _identity;
      final run = _run ??= await (_building ??= _buildOrderedRun(
        source,
        token: _lifetime,
        temporaryParent: temporaryParent,
      ).whenComplete(() => _building = null));
      if (_lifetime.isCancelled || (token?.isCancelled ?? false)) {
        throw const DanmakuWorkCancelled();
      }
      // 原文件在排序过程中变化时不提交旧快照。
      if (await updateSource(source) || identity != _identity) {
        throw const DanmakuWorkCancelled();
      }
      if (run.file != null) {
        await for (final batch in readDanmakuFile(
          run.file!,
          token: _lifetime,
        )) {
          if (token?.isCancelled ?? false) throw const DanmakuWorkCancelled();
          yield batch;
        }
      }
    } finally {
      if (--_readers == 0) {
        _idle?.complete();
        _idle = null;
      }
    }
  }

  Future<void> dispose() => _disposing ??= _dispose();

  Future<void> _dispose() async {
    _lifetime.cancel();
    if (_readers > 0) await (_idle ??= Completer<void>()).future;
    final building = _building;
    if (building != null) {
      try {
        _run ??= await building;
      } on DanmakuWorkCancelled {
        // 构建中的临时文件由构建任务清理。
      }
    }
    final run = _run;
    _run = null;
    await run?.dispose();
  }
}

class _OrderedRun {
  _OrderedRun(this.directory, this.file);
  final Directory directory;
  final File? file;

  Future<void> dispose() async {
    if (file != null && file!.existsSync()) await file!.delete();
    if (directory.existsSync()) await directory.delete();
  }
}

/// 二路归并保留两个输入批次，run 描述采用二进制进位。
Future<_OrderedRun> _buildOrderedRun(
  File source, {
  DanmakuWorkToken? token,
  Directory? temporaryParent,
}) async {
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

  var completed = false;
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
    if (token?.isCancelled ?? false) throw const DanmakuWorkCancelled();
    completed = true;
    return _OrderedRun(directory, result);
  } finally {
    if (!completed) {
      // 仅删除本次创建并登记的文件；外部路径与原始来源不参与清理。
      for (final path in ownedFiles) {
        final file = File(path);
        if (file.existsSync()) await file.delete();
      }
      await directory.delete();
    }
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
