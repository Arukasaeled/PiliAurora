import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/plugin/pl_player/playback/native_media_clock.dart';

void main() {
  late Map<String, String> properties;
  setUp(() {
    properties = {
      'playlist-pos': '0',
      'playlist/0/id': '42',
      'time-pos': '1.25',
      'speed': '2',
      'pause': 'no',
      'paused-for-cache': 'no',
      'seeking': 'no',
      'eof-reached': 'no',
    };
  });

  test('从原生属性取得位置、实际速率和单调接收时刻', () {
    final anchor = sampleNativeMediaClock(
      readProperty: (name) => properties[name] ?? '',
      playlistEntryId: 42,
      continuity: 3,
      monotonicNowUs: () => 9000000,
    )!;
    expect(anchor.positionUs, 1250000);
    expect(anchor.observedAtUs, 9000000);
    expect(anchor.effectiveRate, 2);
    expect(anchor.continuity, 3);
    expect(anchor.positionAt(9100000), 1450000);
  });

  test('暂停、缓冲和播放结束的实际状态各自冻结锚点', () {
    for (final flag in ['pause', 'paused-for-cache', 'eof-reached']) {
      properties[flag] = 'yes';
      final anchor = sampleNativeMediaClock(
        readProperty: (name) => properties[name] ?? '',
        playlistEntryId: 42,
        continuity: 3,
        monotonicNowUs: () => 9000000,
      )!;
      expect(anchor.advancing, isFalse);
      expect(anchor.positionAt(10000000), 1250000);
      properties[flag] = 'no';
    }
  });

  test('切文件、seek 期间和缺失属性不发布可用锚点', () {
    for (final entry in {
      'playlist/0/id': '43',
      'seeking': 'yes',
      'time-pos': '',
      'speed': 'NaN',
      'pause': '',
    }.entries) {
      final original = properties[entry.key]!;
      properties[entry.key] = entry.value;
      expect(
        sampleNativeMediaClock(
          readProperty: (name) => properties[name] ?? '',
          playlistEntryId: 42,
          continuity: 3,
          monotonicNowUs: () => 9000000,
        ),
        isNull,
        reason: entry.key,
      );
      properties[entry.key] = original;
    }
  });

  test('读取位置期间发生速率或文件变化时丢弃混合采样', () {
    for (final changed in ['speed', 'playlist/0/id']) {
      final original = properties[changed]!;
      expect(
        sampleNativeMediaClock(
          readProperty: (name) {
            if (name == 'time-pos') properties[changed] = '99';
            return properties[name] ?? '';
          },
          playlistEntryId: 42,
          continuity: 3,
          monotonicNowUs: () => 9000000,
        ),
        isNull,
      );
      properties[changed] = original;
    }
  });
}
