enum PresentationProfile { standard, androidFramePlan, windowsDwmPaced }

class PresentationEngineConfiguration {
  const PresentationEngineConfiguration({
    this.profile = PresentationProfile.standard,
    this.identityDigest = '',
  });

  final PresentationProfile profile;
  final String identityDigest;
}
