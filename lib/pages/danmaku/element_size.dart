import 'package:pili_aurora/grpc/bilibili/community/service/dm/v1.pb.dart';
import 'package:pili_aurora/services/danmaku/work_quota.dart';
import 'package:protobuf/protobuf.dart' show UnknownFieldSet;

/// 这些是逻辑存储计费单位；VM 对象头、GC 与 isolate 堆容量不属于 RSS 承诺。
abstract final class DanmakuProcessingBudget {
  static const maxElementEncodedBytes = 64 * 1024;
  static const maxElementFields = 128;
  static const batchElements = 256;
  static const batchBytes = 512 * 1024;
  static const groupBytes = 8 * 1024 * 1024;
  static const normalizedBytes = 4 * 1024 * 1024;
  static const cursorBytes = groupBytes + normalizedBytes + 4096;
  // 单条最多 64Ki code units；归一化串、rune 槽位与语义特征串共用临时区。
  static const normalizationScratchBytes = 2 * 1024 * 1024;
  static const maxDecodedBytes = 8 * 1024 * 1024;
  static const rulesBytes = 1024 * 1024;
}

/// 对象和列表开销加 UTF-16 字段的保守估算，供缓存与处理预算共用。
int estimateDanmakuElementBytes(DanmakuElem element) =>
    512 +
    _unknownBytes(element.unknownFields, 0) +
    2 *
        (element.content.length +
            element.midHash.length +
            element.action.length +
            element.idStr.length +
            element.animation.length +
            element.extra.length);

int _unknownBytes(UnknownFieldSet fields, int depth) {
  if (depth > 16) throw const FormatException('弹幕未知字段嵌套过深');
  var bytes = 0;
  for (final field in fields.asMap().values) {
    bytes +=
        128 +
        32 *
            (field.varints.length +
                field.fixed32s.length +
                field.fixed64s.length);
    for (final value in field.lengthDelimited) {
      bytes += 64 + value.length;
    }
    for (final group in field.groups) {
      bytes += 128 + _unknownBytes(group, depth + 1);
    }
  }
  return bytes;
}

/// 解析前扫描 wire，不分配字段值。已知元素的字段槽位包含在 512 字节基数内，
/// 另计字符串、重复消息列表与未知字段，保持与缓存的元素计费口径一致。
/// schema: 0=reply, 1=element, 2=AI flags, 3=flag, 4=colorful, 5=unknown group。
int inspectDanmakuProtobuf(List<int> data, {bool element = false}) {
  if (element && data.length > DanmakuProcessingBudget.maxElementEncodedBytes) {
    throw DanmakuWorkTooLarge(
      data.length,
      DanmakuProcessingBudget.maxElementEncodedBytes,
    );
  }
  var offset = 0;
  int varint(int end) {
    var value = 0;
    for (var shift = 0; shift < 70; shift += 7) {
      if (offset >= end) throw const FormatException('弹幕字段意外结束');
      final byte = data[offset++];
      if (shift == 63 && byte > 1) throw const FormatException('弹幕 varint 溢出');
      value |= (byte & 127) << shift;
      if (byte < 128) return value;
    }
    throw const FormatException('弹幕 varint 过长');
  }

  int scan(int end, int schema, int depth, [int? group]) {
    if (depth > 16) throw const FormatException('弹幕字段嵌套过深');
    var bytes = 512;
    var fields = 0;
    while (offset < end) {
      final tag = varint(end);
      final number = tag >> 3;
      final wire = tag & 7;
      if (number <= 0 || tag > 0xffffffff) {
        throw const FormatException('弹幕字段标识无效');
      }
      if (wire == 4) {
        if (number != group) throw const FormatException('弹幕分组不匹配');
        return bytes;
      }
      fields++;
      if (schema == 1 && fields > DanmakuProcessingBudget.maxElementFields) {
        throw DanmakuWorkTooLarge(
          fields,
          DanmakuProcessingBudget.maxElementFields,
        );
      }
      switch (wire) {
        case 0:
          final value = varint(end);
          final known =
              schema == 1 &&
              switch (number) {
                1 ||
                2 ||
                3 ||
                4 ||
                5 ||
                8 ||
                9 ||
                11 ||
                13 ||
                15 ||
                25 ||
                26 ||
                100 ||
                101 => true,
                24 => DmColorfulType.valueOf(value) != null,
                27 => DmFromType.valueOf(value) != null,
                _ => false,
              };
          if (!known) bytes += 160;
        case 1:
          offset += 8;
          bytes += 160;
        case 2:
          final length = varint(end);
          if (length < 0 || length > end - offset) {
            throw const FormatException('弹幕字段长度越界');
          }
          final nested = schema == 0 && number == 1
              ? 1
              : schema == 0 && number == 3
              ? 2
              : schema == 0 && number == 5
              ? 4
              : schema == 2 && number == 1
              ? 3
              : null;
          if (nested != null) {
            if (nested == 1 &&
                length > DanmakuProcessingBudget.maxElementEncodedBytes) {
              throw DanmakuWorkTooLarge(
                length,
                DanmakuProcessingBudget.maxElementEncodedBytes,
              );
            }
            bytes +=
                (schema == 0 && number == 1 ? 8 : 128) +
                scan(offset + length, nested, depth + 1);
          } else {
            final knownString =
                schema == 1 &&
                (number == 6 ||
                    number == 7 ||
                    number == 10 ||
                    number == 12 ||
                    number == 22 ||
                    number == 23);
            // packed int64 每字节最多一个值；字符串每字节最多一个 UTF-16 code unit。
            bytes += knownString
                ? 2 * length
                : 128 +
                      (schema == 0 && number == 4
                          ? 32 * length
                          : 64 + 2 * length);
            offset += length;
          }
        case 3:
          bytes += 128 + scan(end, 5, depth + 1, number);
        case 5:
          offset += 4;
          bytes += 160;
        default:
          throw const FormatException('弹幕字段类型无效');
      }
      if (offset > end) throw const FormatException('弹幕字段长度越界');
    }
    if (group != null) throw const FormatException('弹幕分组意外结束');
    return bytes;
  }

  return scan(data.length, element ? 1 : 0, 0);
}
