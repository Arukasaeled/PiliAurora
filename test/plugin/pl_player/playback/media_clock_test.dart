import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/plugin/pl_player/playback/media_clock.dart';

void main() {
  test('媒体锚点按观察速率推进，并在采样有效区间终点停止', () {
    const anchor = PlaybackMediaAnchor(
      positionUs: 1000000,
      observedAtUs: 8000000,
      effectiveRate: 2,
      advancing: true,
      ready: true,
      continuity: 1,
      validForUs: 500000,
    );
    expect(anchor.positionAt(7900000), 1000000);
    expect(anchor.positionAt(8250000), 1500000);
    expect(anchor.positionAt(9000000), 2000000);
  });

  test('暂停锚点保持位置，等待落点时没有可用媒体位置', () {
    const paused = PlaybackMediaAnchor(
      positionUs: 7000000,
      observedAtUs: 8000000,
      effectiveRate: 2,
      advancing: false,
      ready: true,
      continuity: 2,
      validForUs: 500000,
    );
    const seeking = PlaybackMediaAnchor(
      positionUs: 7000000,
      observedAtUs: 8000000,
      effectiveRate: 2,
      advancing: false,
      ready: false,
      continuity: 2,
      validForUs: 500000,
    );
    expect(paused.positionAt(20000000), 7000000);
    expect(seeking.positionAt(8250000), isNull);
  });
}
