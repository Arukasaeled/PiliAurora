import 'dart:convert';

import 'package:media_kit/media_kit.dart';

/// 依据完整地址找到外部音轨；解码失败后该音轨可能已被 mpv 取消选中。
String? externalAudioTrackId(String? trackList, String audioUrl) {
  if (trackList == null) return null;
  try {
    final tracks = jsonDecode(trackList);
    if (tracks is! List) return null;
    for (final track in tracks) {
      if (track is Map &&
          track['type'] == 'audio' &&
          track['external'] == true &&
          track['external-filename'] == audioUrl &&
          track['id'] is int) {
        return track['id'].toString();
      }
    }
  } on FormatException {
    return null;
  }
  return null;
}

/// mpv 在后台重新打开外部音轨并同步到当前视频位置，无需 open 或 seek。
Future<bool> reloadNativeAudio({
  required NativePlayer player,
  required String audioUrl,
  required String? trackList,
  required bool Function() isCurrent,
}) async {
  if (player.disposed || player.current.isEmpty || !isCurrent()) return false;
  final id = externalAudioTrackId(trackList, audioUrl);
  if (id == null) return false;
  // audio-reload 在 mpv 中异步执行，且绑定播放生命周期；切源会终止旧任务。
  await player.command(['audio-reload', id]);
  return !player.disposed && isCurrent();
}
