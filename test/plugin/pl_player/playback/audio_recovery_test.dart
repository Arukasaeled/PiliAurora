import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/plugin/pl_player/playback/audio_recovery.dart';

void main() {
  late _Playback playback;
  late PlaybackAudioRecovery recovery;
  late int repairs;
  late int reloads;
  late int notices;
  late int now;
  late List<Object> errors;

  setUp(() {
    playback = _Playback();
    repairs = reloads = notices = now = 0;
    errors = [];
    recovery = PlaybackAudioRecovery(
      readState: () => playback.attached ? playback.state : null,
      repairAudio: () async {
        repairs++;
        return true;
      },
      reload: () async => reloads++,
      onError: errors.add,
      onExhausted: () => notices++,
      elapsedMilliseconds: () => now,
    );
  });
  tearDown(() => recovery.dispose());

  void audioError() => recovery.onLog(
    prefix: 'ad',
    level: 'error',
    message: 'Error decoding audio.',
  );
  Future<void> tick(WidgetTester tester, {bool healthy = false}) async {
    now += 2000;
    playback.position += const Duration(seconds: 2);
    if (healthy) playback.audioPts = playback.position.inSeconds.toDouble();
    await tester.pump(const Duration(seconds: 2));
  }

  testWidgets('网络截断后继续消耗音频缓存，保持画面和声音', (tester) async {
    recovery.onLog(
      prefix: 'ffmpeg/demuxer',
      level: 'error',
      message:
          'mov,mp4,m4a,3gp,3g2,mj2: stream 0, offset 0xeb17ab: partial file',
    );
    for (var i = 0; i < 6; i++) {
      await tick(tester, healthy: true);
    }
    expect(repairs, 0);
    // 音频缓存耗尽后，视频继续前进仍会触发音轨重连。
    await tick(tester);
    expect(repairs, 1);
    expect(reloads, 0);
    expect(notices, 0);
    recovery.dispose();
  });

  testWidgets('单个损坏音频包后解码恢复，取消侵入式兜底', (tester) async {
    audioError();
    for (var i = 0; i < 16; i++) {
      await tick(tester, healthy: true);
    }
    expect(repairs, 0);
    expect(reloads, 0);
    recovery.dispose();
  });

  testWidgets('音频解码失败先修音轨，恢复后持续播放', (tester) async {
    playback.audioPts = null;
    audioError();
    await tick(tester);
    expect(repairs, 1);
    for (var i = 0; i < 16; i++) {
      await tick(tester, healthy: true);
    }
    expect(reloads, 0);
    expect(notices, 0);
    // 连续健康 30 秒后，新故障重新获得轻量恢复预算。
    playback.audioPts = null;
    audioError();
    await tick(tester);
    expect(repairs, 2);
    recovery.dispose();
  });

  testWidgets('音轨重连无效再重载，错误风暴不能反复重开视频', (tester) async {
    playback.audioPts = null;
    for (var i = 0; i < 20; i++) {
      audioError();
    }
    await tick(tester);
    expect(repairs, 1);
    audioError();
    await tick(tester);
    expect(reloads, 1);
    await tick(tester);
    expect(notices, 1);
    for (var i = 0; i < 20; i++) {
      audioError();
      await tick(tester);
    }
    expect(repairs, 1);
    expect(reloads, 1);
    expect(notices, 1);
    recovery.dispose();
  });

  testWidgets('暂停或拖动期间让路，恢复播放后再检查遗留失声', (tester) async {
    playback.audioPts = null;
    audioError();
    playback.playing = false;
    recovery.onPlaybackChanged();
    await tick(tester);
    expect(repairs, 0);
    playback
      ..playing = true
      ..waiting = true;
    recovery.onPlaybackChanged();
    await tick(tester);
    expect(repairs, 0);
    playback.waiting = false;
    recovery.onPlaybackChanged();
    await tick(tester);
    expect(repairs, 1);
    expect(reloads, 0);
    recovery.dispose();
  });

  testWidgets('接近片尾和停止前进的媒体不触发重载', (tester) async {
    playback
      ..duration = const Duration(seconds: 12)
      ..audioPts = null;
    audioError();
    await tick(tester);
    expect(repairs, 0);
    playback.duration = const Duration(seconds: 300);
    recovery
      ..reset()
      ..onLog(
        prefix: 'ffmpeg/demuxer',
        level: 'error',
        message: 'mov,mp4: partial file',
      )
      ..onPlaybackChanged();
    await tester.pump(const Duration(seconds: 2));
    expect(repairs, 0);
    recovery.dispose();
  });

  testWidgets('加载忙时保留预算，音轨命令失败后再升级', (tester) async {
    recovery.dispose();
    var busy = true;
    recovery = PlaybackAudioRecovery(
      readState: () => playback.state,
      repairAudio: () {
        if (busy) return null;
        repairs++;
        return Future.error(StateError('audio reload rejected'));
      },
      reload: () async => reloads++,
      onError: errors.add,
      elapsedMilliseconds: () => now,
    );
    playback.audioPts = null;
    audioError();
    await tick(tester);
    expect(repairs, 0);
    busy = false;
    await tick(tester);
    expect(repairs, 1);
    expect(errors, hasLength(1));
    await tick(tester);
    expect(reloads, 1);
    recovery.dispose();
  });

  testWidgets('切源或关闭后，旧音轨重连收尾不能重开媒体', (tester) async {
    recovery.dispose();
    final pending = Completer<bool>();
    recovery = PlaybackAudioRecovery(
      readState: () => playback.attached ? playback.state : null,
      repairAudio: () => pending.future,
      reload: () async => reloads++,
      onError: errors.add,
    );
    playback.audioPts = null;
    audioError();
    await tick(tester);
    recovery.reset();
    playback.attached = false;
    pending.complete(false);
    await tick(tester);
    expect(reloads, 0);
    recovery.dispose();
    audioError();
    await tick(tester);
    expect(reloads, 0);
  });

  testWidgets('音轨命令等待期间手动暂停，不升级重载或自动播放', (tester) async {
    recovery.dispose();
    final pending = Completer<bool>();
    recovery = PlaybackAudioRecovery(
      readState: () => playback.state,
      repairAudio: () => pending.future,
      reload: () async => reloads++,
      onError: errors.add,
    );
    playback.audioPts = null;
    audioError();
    await tick(tester);
    playback.playing = false;
    recovery.onPlaybackChanged();
    pending.complete(false);
    await tick(tester);
    expect(reloads, 0);
    expect(playback.playing, isFalse);
    recovery.dispose();
  });

  testWidgets('HTTP 403 终止音频恢复，后续解码错误不轮换 CDN', (tester) async {
    playback.audioPts = null;
    audioError();
    recovery.onLog(
      prefix: 'ffmpeg',
      level: 'error',
      message: 'http: HTTP error 403 Forbidden',
    );
    audioError();
    await tick(tester);
    expect(repairs, 0);
    expect(reloads, 0);
    recovery.reset();
    audioError();
    await tick(tester);
    expect(repairs, 1);
    recovery.dispose();
  });
}

class _Playback {
  bool attached = true;
  bool playing = true;
  bool waiting = false;
  bool completed = false;
  Duration position = const Duration(seconds: 10);
  Duration duration = const Duration(seconds: 300);
  double? audioPts = 10;

  AudioRecoveryState get state => (
    playing: playing,
    waiting: waiting,
    completed: completed,
    position: position,
    duration: duration,
    audioPts: audioPts,
    audioDelay: 0,
  );
}
