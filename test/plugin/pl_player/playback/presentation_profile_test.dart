import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/plugin/pl_player/playback/presentation_profile.dart';

void main() {
  test('普通 FVM 入口默认采用标准配置', () {
    initializePresentationEngineConfiguration();
    expect(
      presentationEngineConfiguration.profile,
      PresentationProfile.standard,
    );
    expect(presentationEngineConfiguration.identityDigest, isEmpty);
  });
  test('自编配置须绑定身份摘要，标准配置清除自编身份', () {
    for (final profile in ['androidFramePlan', 'windowsDwmPaced']) {
      expect(
        () => parsePresentationEngineConfiguration(
          profileName: profile,
          identityDigest: '',
        ),
        throwsStateError,
      );
      final configuration = parsePresentationEngineConfiguration(
        profileName: profile,
        identityDigest: 'a' * 64,
      );
      expect(configuration.profile.name, profile);
    }
    expect(
      () => parsePresentationEngineConfiguration(
        profileName: 'standard',
        identityDigest: 'a' * 64,
      ),
      throwsStateError,
    );
    expect(
      () => parsePresentationEngineConfiguration(
        profileName: 'unknown',
        identityDigest: '',
      ),
      throwsArgumentError,
    );
  });
}
