import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:pili_aurora/plugin/pl_player/utils/native_audio_recovery.dart';

void main() {
  const audio = 'https://cdn.example/audio.m4s?signature=fixture';
  final tracks = jsonEncode([
    {'type': 'video', 'id': 1},
    {'type': 'audio', 'id': 1, 'selected': true},
    {
      'type': 'audio',
      'id': 2,
      'external': true,
      'external-filename': audio,
      'selected': false,
    },
  ]);

  test('外部音轨被取消选中后仍能重连，保持位置、音量和暂停状态', () async {
    final player = _Player()
      ..state.position = const Duration(milliseconds: 658858)
      ..state.volume = 37;
    expect(
      await reloadNativeAudio(
        player: player,
        audioUrl: audio,
        trackList: tracks,
        isCurrent: () => true,
      ),
      isTrue,
    );
    expect(player.commands, [
      ['audio-reload', '2'],
    ]);
    expect(player.state.position, const Duration(milliseconds: 658858));
    expect(player.state.volume, 37);
    expect(player.state.playing, isFalse);
  });

  test('错误地址、无外部音轨和过期媒体不发送命令', () async {
    final player = _Player();
    for (final list in [null, 'bad json', '[]', '{}']) {
      expect(
        await reloadNativeAudio(
          player: player,
          audioUrl: audio,
          trackList: list,
          isCurrent: () => true,
        ),
        isFalse,
      );
    }
    expect(externalAudioTrackId(tracks, '$audio-different'), isNull);
    expect(
      await reloadNativeAudio(
        player: player,
        audioUrl: audio,
        trackList: tracks,
        isCurrent: () => false,
      ),
      isFalse,
    );
    player.disposed = true;
    expect(
      await reloadNativeAudio(
        player: player,
        audioUrl: audio,
        trackList: tracks,
        isCurrent: () => true,
      ),
      isFalse,
    );
    expect(player.commands, isEmpty);
  });

  test('后台命令完成时校验媒体代次，不恢复旧媒体播放', () async {
    var current = true;
    final player = _Player()..pending = Completer<void>();
    final result = reloadNativeAudio(
      player: player,
      audioUrl: audio,
      trackList: tracks,
      isCurrent: () => current,
    );
    current = false;
    player.pending!.complete();
    expect(await result, isFalse);
    expect(player.commands, [
      ['audio-reload', '2'],
    ]);
  });
}

class _Player implements NativePlayer {
  @override
  bool disposed = false;
  @override
  final List<Media> current = [const Media('https://cdn.example/video.m4s')];
  @override
  final PlayerState state = PlayerState();
  final commands = <List<String>>[];
  Completer<void>? pending;

  @override
  Future<void> command(List<String> args) async {
    commands.add(args);
    await pending?.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected player operation: ${invocation.memberName}');
}
