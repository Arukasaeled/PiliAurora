import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:pili_aurora/plugin/pl_player/playback/super_resolution_policy.dart';

void main() {
  const phone = (width: 2510, height: 1156);
  test('日志中的 4K 源超过手机分辨率，拒绝超分', () {
    expect(
      superResolutionEligibility(
        source: (width: 3840, height: 2160),
        display: phone,
      ),
      SuperResolutionEligibility.resolutionTooHigh,
    );
  });
  test('原尺寸和更小的视频可开启，横竖屏使用相同判定', () {
    for (final source in [
      phone,
      (width: 1920, height: 1080),
      (width: 1080, height: 1920),
    ]) {
      for (final display in [
        phone,
        (width: phone.height, height: phone.width),
      ]) {
        expect(
          superResolutionEligibility(source: source, display: display),
          SuperResolutionEligibility.allowed,
        );
      }
    }
  });
  test('任一边超过设备均拒绝，不能用像素面积掩盖超宽或超高', () {
    for (final source in [
      (width: 2560, height: 1080),
      (width: 1920, height: 1200),
      (width: 1200, height: 1920),
    ]) {
      expect(
        superResolutionEligibility(source: source, display: phone),
        SuperResolutionEligibility.resolutionTooHigh,
      );
    }
  });
  test('当前显示器可容纳 4K 时允许，换到 1080p 显示器时拒绝', () {
    const source = (width: 3840, height: 2160);
    expect(
      superResolutionEligibility(source: source, display: source),
      SuperResolutionEligibility.allowed,
    );
    expect(
      superResolutionEligibility(
        source: source,
        display: (width: 1920, height: 1080),
      ),
      SuperResolutionEligibility.resolutionTooHigh,
    );
  });
  test('源或设备尺寸未知时等待有效尺寸，避免提前加载 CNN', () {
    for (final VideoOutputSize? size in [null, (width: 0, height: 1080)]) {
      expect(
        superResolutionEligibility(source: size, display: phone),
        SuperResolutionEligibility.unknownSize,
      );
      expect(
        superResolutionEligibility(source: phone, display: size),
        SuperResolutionEligibility.unknownSize,
      );
    }
  });
}
