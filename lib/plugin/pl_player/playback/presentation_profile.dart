enum PresentationProfile { standard, androidFramePlan, windowsDwmPaced }

class PresentationEngineConfiguration {
  const PresentationEngineConfiguration({
    this.profile = PresentationProfile.standard,
    this.identityDigest = '',
  });

  final PresentationProfile profile;
  final String identityDigest;
}

PresentationEngineConfiguration? _current;
PresentationEngineConfiguration get presentationEngineConfiguration {
  if (_current == null) initializePresentationEngineConfiguration();
  return _current!;
}

/// 启动时读取构建入口生成的参数，普通 FVM 入口默认采用标准配置。
void initializePresentationEngineConfiguration() {
  _current = parsePresentationEngineConfiguration(
    profileName: const String.fromEnvironment(
      'PILIAURORA_PRESENTATION_PROFILE',
      defaultValue: 'standard',
    ),
    identityDigest: const String.fromEnvironment('PILIAURORA_ENGINE_IDENTITY'),
  );
}

PresentationEngineConfiguration parsePresentationEngineConfiguration({
  required String profileName,
  required String identityDigest,
}) {
  final profile = PresentationProfile.values.byName(profileName);
  if (profile != PresentationProfile.standard &&
      !RegExp(r'^[a-f0-9]{64}$').hasMatch(identityDigest)) {
    throw StateError(
      'Custom presentation profile has no verified engine identity',
    );
  }
  if (profile == PresentationProfile.standard && identityDigest.isNotEmpty) {
    throw StateError(
      'Standard presentation profile carries a custom engine identity',
    );
  }
  return PresentationEngineConfiguration(
    profile: profile,
    identityDigest: identityDigest,
  );
}
