import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/grpc/decode_policy.dart';
import 'package:pili_aurora/grpc/grpc_req.dart';
import 'package:pili_aurora/services/danmaku/work_quota.dart';

Uint8List _frame(Uint8List bytes, {bool compressed = false}) {
  final payload = compressed ? const GZipEncoder().encodeBytes(bytes) : bytes;
  return Uint8List(5 + payload.length)
    ..[0] = compressed ? 1 : 0
    ..buffer.asByteData(1, 4).setUint32(0, payload.length, Endian.big)
    ..setAll(5, payload);
}

void main() {
  test('gzip output obeys the admitted byte limit before protobuf decode', () {
    final bytes = Uint8List(1024 * 1024);
    final data = _frame(bytes, compressed: true);
    expect(
      GrpcReq.decompressProtobuf(data, maxDecodedBytes: bytes.length),
      bytes,
    );
    expect(
      () => GrpcReq.decompressProtobuf(data, maxDecodedBytes: 1024),
      throwsA(isA<DanmakuWorkTooLarge>()),
    );
  });

  test('uncompressed output obeys the same admitted byte limit', () {
    expect(
      () => GrpcReq.decompressProtobuf(
        _frame(Uint8List(100)),
        maxDecodedBytes: 99,
      ),
      throwsA(isA<DanmakuWorkTooLarge>()),
    );
  });

  test('a small gzip frame with a large expanded payload uses an isolate', () {
    final data = _frame(Uint8List(1 << 20), compressed: true);
    expect(data.length, lessThan(GrpcDecodePolicy.isolateSize));
    expect(GrpcDecodePolicy.shouldUseIsolate(data), isTrue);
  });

  test('small payloads stay on the calling isolate', () {
    expect(GrpcDecodePolicy.shouldUseIsolate(_frame(Uint8List(100))), isFalse);
    expect(
      GrpcDecodePolicy.shouldUseIsolate(
        _frame(Uint8List(100), compressed: true),
      ),
      isFalse,
    );
  });

  test('large uncompressed frames retain the existing background policy', () {
    expect(
      GrpcDecodePolicy.shouldUseIsolate(_frame(Uint8List(1 << 20))),
      isTrue,
    );
  });

  test('truncated and invalid frames cannot break the scheduling decision', () {
    for (var length = 0; length < 24; length++) {
      final data = Uint8List(length);
      if (length > 0) data[0] = 1;
      expect(GrpcDecodePolicy.shouldUseIsolate(data), isFalse);
    }
    final truncated = _frame(Uint8List(1 << 20), compressed: true);
    truncated.buffer.asByteData(1, 4).setUint32(0, 0xffffffff, Endian.big);
    expect(GrpcDecodePolicy.shouldUseIsolate(truncated), isFalse);
  });
}
