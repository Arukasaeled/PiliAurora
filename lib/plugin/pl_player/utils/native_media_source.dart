import 'dart:convert';

import 'package:media_kit/media_kit.dart';
import 'package:pili_aurora/plugin/pl_player/models/data_source.dart';
import 'package:pili_aurora/plugin/pl_player/playback/playback_contracts.dart';

/// 构造原生播放器可直接加载的 [Media]。
///
/// 视频与独立音轨分开交给 mpv 处理：主 URL 直接作为播放目标，音轨通过
/// `audio-files-append` 追加，无需为 DASH 构建两路 EDL。
/// media_kit 的 `_add` 会把 extras 拼成 loadfile 的逗号分隔
/// key-value 字符串，因此路径中的逗号会被解析为选项分隔符，必须用
/// `%<UTF-8 字节数>%` 定长前缀转义；append 本身不再拆分路径列表。
Media nativeMediaSource({
  required DataSource source,
  bool audioOnly = false,
  Duration? start,
  Map<String, String> extras = const {},
}) {
  final video = source.videoSource;
  final audio = source.audioSource;
  // 外部音轨选项由当前媒体源生成，重建时清除上一份媒体的地址。
  final mediaExtras = Map<String, String>.of(extras)
    ..remove('audio-files-append');
  final hasAudio = audio != null && audio.isNotEmpty;
  if (audioOnly && hasAudio) {
    return Media(
      audio,
      start: start,
      extras: mediaExtras.isEmpty ? null : mediaExtras,
    );
  }
  if (!hasAudio || audioOnly) {
    // audioOnly 且无独立音轨时只能退回原视频源。
    return Media(
      video,
      start: start,
      extras: mediaExtras.isEmpty ? null : mediaExtras,
    );
  }
  mediaExtras['audio-files-append'] = '%${utf8.encode(audio).length}%$audio';
  return Media(video, start: start, extras: mediaExtras);
}

/// Builds media directly from a frozen source selection; candidate indices
/// are never reconstructed through a mutable [DataSource].
Media nativeMediaSourceFromSnapshot({
  required PlaybackSourceSnapshot source,
  bool audioOnly = false,
  Duration? start,
  Map<String, String> extras = const {},
}) {
  final video = source.currentVideoSource;
  final audio = source.currentAudioSource;
  final mediaExtras = Map<String, String>.of(extras)
    ..remove('audio-files-append');
  final hasAudio = audio != null && audio.isNotEmpty;
  if (audioOnly && hasAudio) {
    return Media(
      audio,
      start: start,
      extras: mediaExtras.isEmpty ? null : mediaExtras,
    );
  }
  if (!hasAudio || audioOnly) {
    return Media(
      video,
      start: start,
      extras: mediaExtras.isEmpty ? null : mediaExtras,
    );
  }
  mediaExtras['audio-files-append'] = '%${utf8.encode(audio).length}%$audio';
  return Media(video, start: start, extras: mediaExtras);
}
