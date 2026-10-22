import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:synchronized/synchronized.dart';
import 'package:media_kit_video/src/video_controller/output_operation.dart';

const _channel = MethodChannel('com.alexmercerind/media_kit_video');
// 插件的源尺寸重建与应用的视口适配必须共用提交队列；只串行应用请求不够。
// Expando 不持有已销毁播放器，也不需要独立维护全局 handle 清理列表。
final _locks = Expando<Lock>('Android video surface size');
final _frameWaits = Expando<String>('Android video frame wait');
final _frameWaitTokens = Expando<OutputOperationToken>(
  'Android video frame wait token',
);
final _operationTokens = Expando<OutputOperationToken>(
  'Android video output operation token',
);
int _nextFrameWait = 0;
int _nextLegacyEpoch = 0;

OutputOperationToken ensureAndroidOutputOperationToken(
  NativePlayer player, {
  OutputOperationToken? token,
}) {
  if (token != null) {
    _operationTokens[player] = token;
    return token;
  }
  return _operationTokens[player] ??= OutputOperationToken(
    runtimeId: 0,
    loadId: ++_nextLegacyEpoch,
    outputEpoch: _nextLegacyEpoch,
    configRevision: 0,
  );
}

Future<bool> beginAndroidOutputOperation(
  NativePlayer player,
  OutputOperationToken token,
) async {
  _operationTokens[player] = token;
  return await _channel.invokeMethod<bool>(
        'VideoOutputManager.BeginOutputOperation',
        <String, String>{
          'handle': player.handle.toString(),
          ...token.toPlatformArguments(),
        },
      ) ==
      true;
}

Future<bool> invalidateAndroidOutputGeneration(
  NativePlayer player,
  OutputOperationToken token,
) async {
  final invalidated =
      await _channel.invokeMethod<bool>(
        'VideoOutputManager.InvalidateOutputGeneration',
        <String, String>{
          'handle': player.handle.toString(),
          ...token.toPlatformArguments(),
        },
      ) ==
      true;
  return invalidated;
}

Future<int?> createAndroidSurface(
  NativePlayer player,
  OutputOperationToken token,
) async {
  if (!await beginAndroidOutputOperation(player, token)) return null;
  final data = await _channel.invokeMapMethod<String, Object?>(
    'VideoOutputManager.CreateSurface',
    <String, String>{
      'handle': player.handle.toString(),
      ...token.toPlatformArguments(),
    },
  );
  final wid = data?['wid'];
  return wid is int ? wid : null;
}

/// 当前 Surface 配置以来消费的纹理帧；旧图像重绘也可能产生新 buffer。
Future<Map<String, Object?>?> readAndroidSurfaceFrameState(
  NativePlayer player,
) async {
  if (player.disposed) return null;
  final state = await _channel.invokeMapMethod<String, Object?>(
    'VideoOutputManager.FrameState',
    {'handle': player.handle.toString()},
  );
  return state;
}

/// 切源、Surface 重建或页面销毁时解除旧帧等待；请求编号防止取消新交接。
Future<void> cancelAndroidSurfaceFrameWait(NativePlayer player) async {
  final request = _frameWaits[player];
  final token = _frameWaitTokens[player];
  if (request == null || token == null) return;
  await _channel.invokeMethod<void>(
    'VideoOutputManager.CancelSurfaceFrameWait',
    <String, String>{
      'handle': player.handle.toString(),
      'request': request,
      ...token.toPlatformArguments(),
    },
  );
}

/// 串行修改 Android buffer，并同步同一媒体的 mpv 输出尺寸。
///
/// [isCurrent] 只检查 Surface 生命周期，不检查最新视口或播放状态：
/// 平台调用已经改变 buffer 时，不能因新视口请求取消 mpv 同步。
/// [wid] 仅供插件首次挂载/重建 Surface 时更新原生窗口引用。
Future<bool> setAndroidSurfaceSize({
  required NativePlayer player,
  required int width,
  required int height,
  bool Function()? isCurrent,
  int? wid,
  bool waitForFrame = false,
  bool Function()? canStart,
  OutputOperationToken? token,
  void Function(String name, String value)? setOption,
}) {
  if (player.disposed || player.current.isEmpty) return Future.value(false);
  final operationToken = ensureAndroidOutputOperationToken(
    player,
    token: token,
  );
  // 入队前绑定媒体，排队期间切源不能把旧尺寸提交到新媒体。
  final media = player.current.first;
  bool current() =>
      !player.disposed &&
      player.current.isNotEmpty &&
      identical(player.current.first, media) &&
      _operationTokens[player] == operationToken &&
      (isCurrent?.call() ?? true);
  final lock = _locks[player] ??= Lock();
  return lock.synchronized(() async {
    if (!current() || !(canStart?.call() ?? true)) return false;
    if (!await beginAndroidOutputOperation(player, operationToken) ||
        !current()) {
      return false;
    }
    if (waitForFrame) {
      final supported = await _channel.invokeMethod<bool>(
        'VideoOutputManager.CanWaitForSurfaceFrame',
        <String, String>{
          'handle': player.handle.toString(),
          ...operationToken.toPlatformArguments(),
        },
      );
      // 帧时钟 / 消费监听不可用时不改变 buffer，不能用固定延时假装成功。
      if (supported != true || !current() || !(canStart?.call() ?? true)) {
        return false;
      }
    }
    await _channel.invokeMethod<void>(
      'VideoOutputManager.SetSurfaceTextureSize',
      <String, String>{
        'handle': player.handle.toString(),
        'width': width.toString(),
        'height': height.toString(),
        ...operationToken.toPlatformArguments(),
      },
    );
    if (!current()) return false;
    final set = setOption ?? player.setOption;
    set('android-surface-size', '${width}x$height');
    if (wid != null) {
      // 只有挂载/重建源 Surface 才启动 VO。单纯视口调整由
      // android-surface-size 的 EXTERNAL_RESIZE 通知完成，不重新选择 VO。
      set('wid', wid.toString());
      set('vo', 'gpu');
    }
    if (!waitForFrame) {
      await _channel
          .invokeMethod<void>('VideoOutputManager.ConfirmSurfaceConfigured', {
            'handle': player.handle.toString(),
            ...operationToken.toPlatformArguments(),
          });
      return current();
    }
    final request = (++_nextFrameWait).toString();
    _frameWaits[player] = request;
    _frameWaitTokens[player] = operationToken;
    try {
      final consumed = await _channel
          .invokeMethod<bool>('VideoOutputManager.WaitForSurfaceFrame', {
            'handle': player.handle.toString(),
            'width': width.toString(),
            'height': height.toString(),
            'request': request,
            ...operationToken.toPlatformArguments(),
          });
      if (!current()) return false;
      if (consumed != true) {
        throw StateError(
          'Frame handoff cancelled after native geometry changed',
        );
      }
      return true;
    } finally {
      if (_frameWaits[player] == request) _frameWaits[player] = null;
      if (_frameWaitTokens[player] == operationToken) {
        _frameWaitTokens[player] = null;
      }
    }
  });
}
