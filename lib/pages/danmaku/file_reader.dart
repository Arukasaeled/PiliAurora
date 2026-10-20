import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:pili_aurora/grpc/bilibili/community/service/dm/v1.pb.dart';
import 'package:pili_aurora/services/danmaku/work_quota.dart';
import 'package:pili_aurora/pages/danmaku/element_size.dart';

List<DanmakuElem> _decodeElements(List<Uint8List> messages) =>
    messages.map(DanmakuElem.fromBuffer).toList();

/// 按顶层 elems 字段读取下载的 protobuf 文件，不构造整份编码副本。
Stream<List<DanmakuElem>> readDanmakuFile(
  File file, {
  DanmakuWorkToken? token,
  int batchElements = DanmakuProcessingBudget.batchElements,
  int batchBytes = DanmakuProcessingBudget.batchBytes,
}) async* {
  if (batchElements <= 0 || batchBytes <= 0) throw ArgumentError('文件批次预算必须为正数');
  final handle = await file.open();
  try {
    final reader = _FileWireReader(handle, await handle.length());
    var messages = <Uint8List>[];
    var bytes = 0;
    var decodedBytes = 0;
    while (reader.position < reader.length) {
      if (token?.isCancelled ?? false) throw const DanmakuWorkCancelled();
      final tag = await reader.tag();
      if (tag == 10) {
        final length = await reader.varint();
        reader.require(length);
        final limit = math.min(
          batchBytes,
          DanmakuProcessingBudget.maxElementEncodedBytes,
        );
        if (length > limit) throw DanmakuWorkTooLarge(length, limit);
        if (messages.isNotEmpty && bytes + length > batchBytes) {
          yield await compute(_decodeElements, messages);
          messages = [];
          bytes = 0;
          decodedBytes = 0;
        }
        final message = await reader.bytes(length);
        final size = inspectDanmakuProtobuf(message, element: true);
        if (size > batchBytes) throw DanmakuWorkTooLarge(size, batchBytes);
        if (messages.isNotEmpty && decodedBytes + size > batchBytes) {
          yield await compute(_decodeElements, messages);
          messages = [];
          bytes = 0;
          decodedBytes = 0;
        }
        messages.add(message);
        bytes += length;
        decodedBytes += size;
        if (messages.length >= batchElements || bytes >= batchBytes) {
          yield await compute(_decodeElements, messages);
          messages = [];
          bytes = 0;
          decodedBytes = 0;
        }
      } else {
        await reader.skipField(tag);
      }
    }
    if (messages.isNotEmpty) {
      if (token?.isCancelled ?? false) throw const DanmakuWorkCancelled();
      yield await compute(_decodeElements, messages);
    }
  } finally {
    await handle.close();
  }
}

class _FileWireReader {
  _FileWireReader(this.file, this.length);
  final RandomAccessFile file;
  final int length;
  int position = 0;
  Uint8List _buffer = Uint8List(0);
  int _offset = 0;

  void require(int count) {
    if (count < 0 || count > length - position) {
      throw const FormatException('弹幕文件字段长度超出文件范围');
    }
  }

  Future<void> _fill() async {
    if (_offset < _buffer.length) return;
    _buffer = await file.read(64 * 1024);
    _offset = 0;
    if (_buffer.isEmpty) throw const FormatException('弹幕文件意外结束');
  }

  Future<int> varint() async {
    var value = 0;
    for (var shift = 0; shift < 70; shift += 7) {
      require(1);
      await _fill();
      final byte = _buffer[_offset++];
      position++;
      if (shift == 63 && byte > 1) {
        throw const FormatException('弹幕文件 varint 溢出');
      }
      value |= (byte & 0x7f) << shift;
      if (byte < 128) return value;
    }
    throw const FormatException('弹幕文件 varint 过长');
  }

  Future<int> tag() async {
    final value = await varint();
    if (value <= 0 || value > 0xffffffff || value >> 3 == 0) {
      throw const FormatException('弹幕文件字段标识无效');
    }
    return value;
  }

  Future<Uint8List> bytes(int count) async {
    require(count);
    final result = Uint8List(count);
    var copied = 0;
    while (copied < count) {
      await _fill();
      final take = math.min(count - copied, _buffer.length - _offset);
      result.setRange(copied, copied + take, _buffer, _offset);
      copied += take;
      _offset += take;
      position += take;
    }
    return result;
  }

  Future<void> _skip(int count) async {
    require(count);
    final buffered = math.min(count, _buffer.length - _offset);
    _offset += buffered;
    position += count;
    if (buffered < count) {
      await file.setPosition(position);
      _buffer = Uint8List(0);
      _offset = 0;
    }
  }

  Future<void> skipField(int field, [int depth = 0]) async {
    switch (field & 7) {
      case 0:
        await varint();
      case 1:
        await _skip(8);
      case 2:
        await _skip(await varint());
      case 3:
        if (depth >= 64) throw const FormatException('弹幕文件字段嵌套过深');
        while (true) {
          final nested = await tag();
          if (nested & 7 == 4) {
            if (nested >> 3 != field >> 3) {
              throw const FormatException('弹幕文件分组不匹配');
            }
            return;
          }
          await skipField(nested, depth + 1);
        }
      case 5:
        await _skip(4);
      default:
        throw const FormatException('弹幕文件字段类型无效');
    }
  }
}
