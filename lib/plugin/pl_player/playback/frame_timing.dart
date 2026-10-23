import 'package:flutter/foundation.dart';
import 'package:media_kit_video/media_kit_video.dart';

export 'package:media_kit_video/src/video_controller/video_frame_sampling.dart';

final class PlaybackFrameState {
  const PlaybackFrameState({
    this.output,
    this.samplingGeneration = 0,
    this.admission = VideoFrameSamplingAdmission.blocked,
    this.epoch = 0,
    this.samplesValidAfterUs = 0,
    this.displaySyncActive = false,
    this.videoSamples,
    this.frameTimelineSupported = false,
  });

  final OutputOperationToken? output;
  final int samplingGeneration;
  final VideoFrameSamplingAdmission admission;
  final int epoch;
  final int samplesValidAfterUs;
  final bool displaySyncActive;
  final VideoFrameBatch? videoSamples;
  final bool frameTimelineSupported;
}

abstract interface class PlaybackFrameSource {
  ValueListenable<PlaybackFrameState> get frameState;
}

/// 无原生视频输出的显示挂载仍使用同一个调度入口。
class EmptyPlaybackFrameSource implements PlaybackFrameSource {
  const EmptyPlaybackFrameSource();

  static final _state = ValueNotifier(const PlaybackFrameState());

  @override
  ValueListenable<PlaybackFrameState> get frameState => _state;
}
