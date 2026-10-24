import 'dart:async';
import 'dart:io';

import 'package:pili_aurora/models/remote/download/bili_download_entry_info.dart';
import 'package:pili_aurora/services/download/response_adapter.dart';
import 'package:pili_aurora/services/download/stream_writer.dart';
import 'package:pili_aurora/utils/extension/string_ext.dart';
import 'package:dio/dio.dart';

/// 传输单条媒体流，并按已有文件长度请求剩余字节以支持续传。
///
/// 文件 sink 消费速度会反压响应流；调用方负责在暂停、删除和结束时统一
/// 管理任务生命周期。
class DownloadManager {
  final String url;
  final String path;
  final void Function(int, int)? onReceiveProgress;
  final void Function([Object? error]) onDone;

  DownloadStatus _status = DownloadStatus.downloading;

  DownloadStatus get status => _status;
  final _cancelToken = CancelToken();
  late Future<void> task;
  final Dio client;

  DownloadManager({
    required this.url,
    required this.path,
    required this.onReceiveProgress,
    required this.onDone,
    required this.client,
  }) {
    task = _start();
  }

  Future<void> _start() async {
    try {
      await _transfer();
    } catch (error) {
      if (!_cancelToken.isCancelled) _cancelToken.cancel(error);
      if (_status == DownloadStatus.downloading) {
        _status = DownloadStatus.failDownload;
      }
      onDone(error);
    }
  }

  Future<void> _transfer() async {
    int received;

    final file = File(path);
    if (file.existsSync()) {
      received = await file.length();
    } else {
      file.createSync(recursive: true);
      received = 0;
    }

    final sink = file.openWrite(
      mode: received == 0 ? FileMode.writeOnly : FileMode.writeOnlyAppend,
    );

    Future<void> onError(Object e) async {
      // 消费者失败时仅取消 Dio 输出订阅不足以释放底层网络源。
      if (!_cancelToken.isCancelled) _cancelToken.cancel(e);
      try {
        await sink.close();
      } catch (_) {}
      if (_status == DownloadStatus.downloading) {
        _status = DownloadStatus.failDownload;
      }
      onDone(e);
    }

    Response<ResponseBody> response;
    try {
      response = await client.get<ResponseBody>(
        url.http2https,
        options: Options(
          headers: {'range': 'bytes=$received-'},
          extra: {DownloadResponseAdapter.pauseAwareTimeoutKey: true},
          responseType: ResponseType.stream,
          validateStatus: (status) =>
              status != null &&
              (status == 416 || (status >= 200 && status < 300)),
        ),
        cancelToken: _cancelToken,
      );
    } on DioException catch (e) {
      await onError(e);
      return;
    }
    final data = response.data!;
    final range = response.headers.value('content-range');
    // 拒绝忽略 Range 的响应，不能把完整媒体追加到已有片段后。
    // 416 只有在服务端确认本地长度恰好等于总长时才代表完成。
    if ((received > 0 && response.statusCode == 200) ||
        (response.statusCode == 206 &&
            !RegExp('^bytes $received-').hasMatch(range ?? '')) ||
        (response.statusCode == 416 &&
            (received == 0 || range != 'bytes */$received'))) {
      await onError(StateError('服务器未返回匹配的下载范围，已保留本地文件'));
      return;
    }
    if (response.statusCode == 416) {
      try {
        await data.stream.drain<void>();
        await sink.close();
        if (!_cancelToken.isCancelled) {
          _status = DownloadStatus.completed;
          onReceiveProgress?.call(received, received);
          onDone();
        }
      } catch (error) {
        await onError(error);
      }
      return;
    }
    final contentLength = data.contentLength + received;

    onReceiveProgress?.call(received, contentLength);

    try {
      if (onReceiveProgress == null) {
        await sink.addStream(data.stream);
      } else {
        int? last;
        await writeDownloadStream(
          data.stream,
          sink,
          initialBytes: received,
          onProgress: (received) {
            final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
            if (last != now) {
              last = now;
              onReceiveProgress!(received, contentLength);
            }
          },
        );
      }
      await sink.close();
      if (_cancelToken.isCancelled) {
        onDone(
          DioException.requestCancelled(
            requestOptions: response.requestOptions,
            reason: _cancelToken.cancelError,
          ),
        );
        return;
      }
      _status = DownloadStatus.completed;
      onDone();
    } catch (e) {
      await onError(e);
      return;
    }
  }

  Future<void> cancel({required bool isDelete}) {
    if (!isDelete && _status == DownloadStatus.downloading) {
      _status = DownloadStatus.pause;
    }
    if (!_cancelToken.isCancelled) {
      _cancelToken.cancel();
    }
    return task;
  }
}
