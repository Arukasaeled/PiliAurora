import 'package:media_kit/media_kit.dart';

final class OutputOperationToken {
  const OutputOperationToken({
    required this.runtimeId,
    required this.loadId,
    required this.outputEpoch,
    required this.configRevision,
  });

  final int runtimeId;
  final int loadId;
  final int outputEpoch;
  final int configRevision;

  Map<String, String> toPlatformArguments() => {
    'runtimeId': runtimeId.toString(),
    'loadId': loadId.toString(),
    'outputEpoch': outputEpoch.toString(),
    'configRevision': configRevision.toString(),
  };

  static OutputOperationToken fromPlatformArguments(
    Map<Object?, Object?> args,
  ) => OutputOperationToken(
    runtimeId: int.parse(args['runtimeId'].toString()),
    loadId: int.parse(args['loadId'].toString()),
    outputEpoch: int.parse(args['outputEpoch'].toString()),
    configRevision: int.parse(args['configRevision'].toString()),
  );

  @override
  bool operator ==(Object other) =>
      other is OutputOperationToken &&
      runtimeId == other.runtimeId &&
      loadId == other.loadId &&
      outputEpoch == other.outputEpoch &&
      configRevision == other.configRevision;

  @override
  int get hashCode =>
      Object.hash(runtimeId, loadId, outputEpoch, configRevision);
}

final class VideoOutputProgress {
  const VideoOutputProgress({
    required this.token,
    required this.consumedAtMonotonicUs,
  });

  final OutputOperationToken token;
  final List<int> consumedAtMonotonicUs;
}

enum OutputPreparationStrategy { prepared, noVideo, legacyAttached, unknown }

enum OutputLoadSelectionStrategy { selectedVideo, noVideo, unknown }

enum OutputLoadSelectionEvidence {
  nativeTrackListSingleVideo,
  preloadedSurfaceConfigured,
  nativeTrackListNoVideo,
  multipleVideoTracks,
  trackSelectionUnconfirmed,
  cropUnconfirmed,
  invalidDemuxGeometry,
  preloadedHookUnavailable,
  outputMutationUnconfirmed,
  unknown,
}

final class OutputLoadSelectionResult {
  const OutputLoadSelectionResult({
    required this.strategy,
    required this.evidence,
    required this.outputEpoch,
    this.trackId,
  });

  final OutputLoadSelectionStrategy strategy;
  final OutputLoadSelectionEvidence evidence;
  final int outputEpoch;
  final String? trackId;
}

enum OutputPreparationEvidence {
  singleTrackDemuxMetadata,
  nativeTrackListNoVideo,
  legacyVideoParameters,
  preloadedSurfaceConfiguration,
  loadedFileGeometry,
  nativeTextureAttachReceipt,
  cropUnconfirmed,
  trackSelectionUnconfirmed,
  multipleVideoTracks,
  invalidDemuxGeometry,
  preloadedHookUnavailable,
  outputMutationUnconfirmed,
  unknown,
}

final class VideoOutputGeometry {
  const VideoOutputGeometry({required this.width, required this.height});

  final int width;
  final int height;
}

final class OutputPreparationRequest {
  const OutputPreparationRequest({
    required this.allowedTrackId,
    required this.cropKnownNone,
    required this.nativeApi,
    this.sourceWidth,
    this.sourceHeight,
    this.pixelAspectRatio,
    this.rotation,
  });

  final String? allowedTrackId;
  final bool cropKnownNone;
  final NativeHookApi nativeApi;
  final int? sourceWidth;
  final int? sourceHeight;
  final double? pixelAspectRatio;
  final int? rotation;
}

final class OutputPreparationResult {
  const OutputPreparationResult({
    required this.strategy,
    required this.evidence,
    required this.outputEpoch,
    this.geometry,
  });

  final OutputPreparationStrategy strategy;
  final OutputPreparationEvidence evidence;
  final int outputEpoch;
  final VideoOutputGeometry? geometry;
}
