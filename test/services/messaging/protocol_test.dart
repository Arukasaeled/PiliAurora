import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:pili_aurora/grpc/bilibili/im/interfaces/v1.pb.dart';
import 'package:pili_aurora/grpc/bilibili/im/type.pbenum.dart';
import 'package:pili_aurora/grpc/grpc_req.dart';
import 'package:pili_aurora/grpc/im.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/services/messaging/conversation_adapter.dart';
import 'package:pili_aurora/services/messaging/message_models.dart';
import 'package:pili_aurora/utils/storage.dart';

import 'messaging_test.dart' as helpers;

void main() {
  setUpAll(() async {
    GStorage.setting = await Hive.openBox('setting', bytes: Uint8List(0));
    Request();
  });

  tearDownAll(() async {
    Request.dio.close(force: true);
    await Hive.close();
  });

  setUp(() => Request.dio.interceptors.clear());

  for (final explicitAccount in [false, true]) {
    test('发送${explicitAccount ? '显式' : '默认'}账号请求均关闭自动重试', () async {
      final session = helpers.scope();
      addTearDown(session.dispose);
      RequestOptions? captured;
      Request.dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            captured = options;
            handler.resolve(
              Response(
                requestOptions: options,
                headers: Headers.fromMap({
                  'grpc-status': ['0'],
                }),
                data: GrpcReq.compressProtobuf(RspSendMsg().writeToBuffer()),
              ),
            );
          },
        ),
      );
      final result = await ImGrpc.sendMsg(
        account: explicitAccount ? session.account : null,
        senderUid: 123,
        receiverId: 456,
        content: jsonEncode({'content': 'test'}),
      );
      expect(result.isSuccess, isTrue);
      expect(captured!.extra['noRetry'], isTrue);
      expect(
        captured!.extra['account'],
        explicitAccount ? same(session.account) : isNull,
      );
    });
  }

  for (final kind in [
    MessageContentKind.shareV2,
    MessageContentKind.commonShareCard,
  ]) {
    test('分享卡片 $kind 保留协议字段并绑定账号', () async {
      final session = helpers.scope();
      addTearDown(session.dispose);
      final payload = <String, Object?>{
        'source': kind == MessageContentKind.shareV2 ? 5 : '直播',
        'id': 1234,
        'title': 'test',
        'thumb': 'https://example.invalid/cover.png',
      };
      Request.dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            final request = ReqSendMsg.fromBuffer(
              GrpcReq.decompressProtobuf(options.data as Uint8List),
            );
            expect(options.extra['account'], same(session.account));
            expect(options.extra['noRetry'], isTrue);
            expect(request.msg.senderUid.toInt(), 123);
            expect(request.msg.receiverId.toInt(), 456);
            expect(
              request.msg.msgType,
              kind == MessageContentKind.shareV2
                  ? MsgType.EN_MSG_TYPE_SHARE_V2.value
                  : MsgType.EN_MSG_TYPE_COMMON_SHARE_CARD.value,
            );
            expect(jsonDecode(request.msg.content), payload);
            handler.resolve(
              Response(
                requestOptions: options,
                headers: Headers.fromMap({
                  'grpc-status': ['0'],
                }),
                data: GrpcReq.compressProtobuf(RspSendMsg().writeToBuffer()),
              ),
            );
          },
        ),
      );
      final result = await const GrpcConversationAdapter().send(
        session.account,
        const ConversationTarget(talkerId: 456),
        StructuredMessageContent(kind, payload),
      );
      expect(result.isSuccess, isTrue);
    });
  }
}
