import 'dart:io' show Platform;

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:pili_aurora/plugin/pl_player/utils/hardware_video_configuration.dart';
import 'package:pili_aurora/plugin/pl_player/models/hwdec_type.dart';

void main() {
  test('Windows starts 4K playback at the display-limited output size', () {
    final configuration = hardwareVideoConfiguration(
      enabled: true,
      configured: 'auto-copy',
      windowsSourceSize: (width: 3840, height: 2160),
      windowsOutputLimit: (width: 2560, height: 1440),
    );
    expect(configuration.width, 2560);
    expect(configuration.height, 1440);
  });

  test('Windows retains smaller sources and unknown sizes stay automatic', () {
    final small = hardwareVideoConfiguration(
      enabled: true,
      configured: 'auto-copy',
      windowsSourceSize: (width: 1920, height: 1080),
      windowsOutputLimit: (width: 2560, height: 1440),
    );
    expect(small.width, 1920);
    expect(small.height, 1080);
    for (final size in [null, (width: 0, height: 0)]) {
      final unknown = hardwareVideoConfiguration(
        enabled: true,
        configured: 'auto-copy',
        windowsSourceSize: size,
        windowsOutputLimit: (width: 2560, height: 1440),
      );
      expect(unknown.width, isNull);
      expect(unknown.height, isNull);
    }
  });

  test(
    'disabling hardware acceleration falls back to software decoding only',
    () {
      final configuration = hardwareVideoConfiguration(
        enabled: false,
        configured: HwDecType.kHwdec,
      );

      expect(configuration.enableHardwareAcceleration, isFalse);
      expect(configuration.hwdec, 'no');
    },
  );
  test('Windows auto-copy does not append incompatible direct backends', () {
    final configuration = hardwareVideoConfiguration(
      enabled: true,
      configured: 'auto-copy',
    );

    expect(configuration.hwdec, 'auto-copy,no');
    expect(configuration.androidAttachSurfaceAfterVideoParameters, isTrue);
  }, skip: !Platform.isWindows);

  test('defers output detection through the native fixed-size policy', () {
    VideoOutputSize? limit;
    var reads = 0;
    final configuration = hardwareVideoConfiguration(
      enabled: true,
      configured: 'mediacodec',
      androidOutputLimit: () {
        reads++;
        return limit;
      },
    );
    final output = AndroidFixedSurfaceSize(
      limitWidth: configuration.androidOutputLimitWidth,
      limitHeight: configuration.androidOutputLimitHeight,
      readLimit: configuration.androidOutputLimit,
    );
    expect(reads, 0);
    limit = (width: 2510, height: 1156);
    expect(output.resolve(3794, 2160), (width: 2030, height: 1156));
    expect(reads, 1);
  });
}
