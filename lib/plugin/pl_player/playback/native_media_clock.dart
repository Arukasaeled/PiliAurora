import 'package:pili_aurora/plugin/pl_player/playback/media_clock.dart';

/// 属性通知仅触发重新采样，避免将排队的旧位置套在当前速率上。
PlaybackMediaAnchor? sampleNativeMediaClock({
  required String Function(String) readProperty,
  required int playlistEntryId,
  required int continuity,
  required int Function() monotonicNowUs,
  int validForUs = 500000,
}) {
  int? currentEntry() {
    final index = int.tryParse(readProperty('playlist-pos'));
    if (index == null || index < 0) return null;
    return int.tryParse(readProperty('playlist/$index/id'));
  }

  if (currentEntry() != playlistEntryId) return null;
  final rate = double.tryParse(readProperty('speed'));
  final position = double.tryParse(readProperty('time-pos'));
  final observedAt = monotonicNowUs();
  final pause = readProperty('pause');
  final buffering = readProperty('paused-for-cache');
  final seeking = readProperty('seeking');
  final ended = readProperty('eof-reached');
  if (currentEntry() != playlistEntryId ||
      rate == null ||
      !rate.isFinite ||
      rate <= 0 ||
      position == null ||
      !position.isFinite ||
      position < 0 ||
      (pause != 'yes' && pause != 'no') ||
      (buffering != 'yes' && buffering != 'no') ||
      (ended != 'yes' && ended != 'no') ||
      seeking != 'no') {
    return null;
  }
  // 速率可能在读取位置期间变化；该次样本留给下一次通知重新取得。
  if (double.tryParse(readProperty('speed')) != rate ||
      readProperty('seeking') != 'no' ||
      currentEntry() != playlistEntryId) {
    return null;
  }
  return PlaybackMediaAnchor(
    positionUs: (position * Duration.microsecondsPerSecond).round(),
    observedAtUs: observedAt,
    effectiveRate: rate,
    advancing: pause == 'no' && buffering == 'no' && ended == 'no',
    ready: true,
    continuity: continuity,
    validForUs: validForUs,
  );
}
