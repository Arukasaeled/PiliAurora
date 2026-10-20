import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:typed_data';

import 'package:pili_aurora/grpc/bilibili/rpc.pb.dart';
import 'package:pili_aurora/grpc/decode_policy.dart';
import 'package:pili_aurora/http/constants.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/services/diagnostics/diagnostics.dart';
import 'package:pili_aurora/services/danmaku/work_quota.dart';
import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kDebugMode, compute;
import 'package:protobuf/protobuf.dart' show GeneratedMessage;

/// 输出在首次展开前按获配上限分配；gzip 尾部长度仅用于预约，
/// 实际解压仍逐块核对，损坏或伪造的长度无法扩大工作集。
class _BoundedDecodeSink implements Sink<List<int>> {
  _BoundedDecodeSink(int limit) : _buffer = Uint8List(limit);

  final Uint8List _buffer;
  int _length = 0;

  Uint8List get bytes => Uint8List.sublistView(_buffer, 0, _length);

  @override
  void add(List<int> data) {
    final next = _length + data.length;
    if (next > _buffer.length) {
      throw DanmakuWorkTooLarge(next, _buffer.length);
    }
    _buffer.setRange(_length, next, data);
    _length = next;
  }

  @override
  void close() {}
}

abstract final class GrpcReq {
  static const _gzipMinLength = 64;

  static final options = Options(
    contentType: 'application/grpc',
    responseType: ResponseType.bytes,
  );

  static Uint8List compressProtobuf(Uint8List proto) {
    final compress = proto.length > _gzipMinLength;
    if (compress) {
      proto = const GZipEncoder().encodeBytes(proto);
    }
    return Uint8List(5 + proto.length)
      ..[0] = compress ? 1 : 0
      ..buffer.asByteData(1, 4).setInt32(0, proto.length, Endian.big)
      ..setAll(5, proto);
  }

  static Uint8List decompressProtobuf(Uint8List data, {int? maxDecodedBytes}) {
    final length = ByteData.sublistView(data, 1, 5).getInt32(0, Endian.big);

    if (data[0] == 1) {
      if (maxDecodedBytes != null) {
        final output = _BoundedDecodeSink(maxDecodedBytes);
        final decoder = gzip.decoder.startChunkedConversion(output);
        // 分片投喂，避免一次输入在底层解码器中积累整份展开结果。
        for (var offset = 5; offset < length + 5; offset += 16384) {
          final end = (offset + 16384).clamp(0, length + 5);
          decoder.add(Uint8List.sublistView(data, offset, end));
        }
        decoder.close();
        return output.bytes;
      }
      return const GZipDecoder().decodeBytes(
        Uint8List.sublistView(data, 5, length + 5),
      );
    } else {
      if (maxDecodedBytes != null && length > maxDecodedBytes) {
        throw DanmakuWorkTooLarge(length, maxDecodedBytes);
      }
      return Uint8List.sublistView(data, 5, length + 5);
    }
  }

  static LoadingState<T> _parse<T>(
    (Uint8List, T Function(Uint8List), int?) args,
  ) {
    try {
      final data = decompressProtobuf(args.$1, maxDecodedBytes: args.$3);
      final grpcResponse = args.$2(data);
      return Success(grpcResponse);
    } catch (e) {
      return Error(e.toString());
    }
  }

  static Future<LoadingState<T>> request<T extends GeneratedMessage>(
    String url,
    GeneratedMessage request,
    T Function(Uint8List) grpcParser, {
    bool isolate = false,
    bool danmakuWork = false,
    DanmakuWorkToken? workToken,
    Future<void> Function(T, DanmakuWorkLease)? consume,
    Account? account,
    bool retry = true,
  }) async {
    final requestOptions = options.copyWith(
      extra: {
        ...?options.extra,
        'account': ?account,
        'noRetry': !retry,
      },
    );
    final response = await (account == null
        ? Request().post<Uint8List>(
            HttpString.appBaseUrl + url,
            data: compressProtobuf(request.writeToBuffer()),
            options: requestOptions,
          )
        : Request.dio.post<Uint8List>(
            HttpString.appBaseUrl + url,
            data: compressProtobuf(request.writeToBuffer()),
            options: requestOptions,
          ));

    if (response.data case final Map map) {
      return Error(map['message']);
    }

    if (response.headers.value('Grpc-Status') == '0') {
      final data = response.data;
      if (data is Uint8List) {
        final background = isolate && GrpcDecodePolicy.shouldUseIsolate(data);
        final operation = Diagnostics.instance.begin(
          'grpcDecode',
          '解析 gRPC 响应',
          details: {'bytes': data.length, 'background': background},
        );
        try {
          final decodedLimit = danmakuWork
              ? GrpcDecodePolicy.estimatedDecodedBytes(data)
              : null;
          Future<LoadingState<T>> decode() async => background
              ? await compute(_parse<T>, (data, grpcParser, decodedLimit))
              : _parse<T>((data, grpcParser, decodedLimit));
          final result = danmakuWork
              ? await DanmakuWorkQuota.instance.runWithLease(
                  data.length +
                      GrpcDecodePolicy.estimatedDecodedBytes(data) * 16,
                  (lease) async {
                    final decoded = await decode();
                    if (!(workToken?.isCancelled ?? false)) {
                      if (decoded case Success(:final response)) {
                        await consume?.call(response, lease);
                      }
                    }
                    return decoded;
                  },
                  token: workToken,
                  waitingBytes: data.length + 256,
                )
              : await decode();
          operation?.finish(error: result is Error ? result.errMsg : null);
          return result;
        } on DanmakuWorkBusy {
          return const Error('弹幕处理等待额度已满');
        } on DanmakuWorkCancelled {
          return const Error('弹幕任务已失效');
        } on DanmakuWorkTooLarge {
          return const Error('弹幕响应超过处理预算');
        } catch (error) {
          operation?.finish(error: error);
          rethrow;
        } finally {
          operation?.finish();
        }
      } else {
        return Error('grpc: ${data.runtimeType} is not Uint8List');
      }
    } else {
      try {
        int? code;
        String msg = response.headers.value('Grpc-Status-Details-Bin') ?? '';
        if (msg.isNotEmpty) {
          final padding = -msg.length & 3;
          if (padding != 0) {
            msg += '=' * padding;
          }
          final msgBytes = base64Decode(msg);
          try {
            final grpcMsg = Status.fromBuffer(msgBytes);
            final details = grpcMsg.details
                .map((e) => Status.fromBuffer(e.value))
                .toList();
            code = details.firstOrNull?.code;
            // UNKNOWN : -400 : msg
            final errMsg = details.map((e) => e.message).join('\n');
            msg = kDebugMode
                ? 'CODE: ${grpcMsg.code}(${grpcMsg.message})\n'
                      'MSG: $errMsg'
                : errMsg;
          } catch (e) {
            msg = utf8.decode(msgBytes, allowMalformed: true);
          }
        }
        return Error(msg, code: code);
      } catch (e) {
        return Error(e.toString());
      }
    }
  }

  // static Future playerOnline({
  //   int aid = 0,
  //   int cid = 0,
  // }) {
  //   return _request(
  //       GrpcUrl.playerOnline,
  //       PlayerOnlineReq(aid: Int64(aid), cid: Int64(cid), playOpen: true),
  //       PlayerOnlineReply.fromBuffer,
  //       onSuccess: (response) => response.totalNumberText);
  // }

  // static Future popular(int idx) {
  //   return _request(GrpcUrl.popular, PopularResultReq(idx: Int64(idx)),
  //       PopularReply.fromBuffer, onSuccess: (response) {
  //     response.items.retainWhere((item) => item.smallCoverV5.base.goto == 'av');
  //     return {'status': true, 'data': response.items};
  //   });
  // }
}
