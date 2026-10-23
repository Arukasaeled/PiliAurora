/// This file is a part of media_kit (https://github.com/media-kit/media-kit).
///
/// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
/// All rights reserved.
/// Use of this source code is governed by MIT license that can be found in the LICENSE file.
import 'dart:async';
import 'dart:io';
import 'package:media_kit_video/src/video_controller/video_frame_sampling.dart';
import 'package:flutter/widgets.dart';

import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/src/video_output_size_policy.dart';
import 'package:media_kit_video/src/video_controller/android_video_controller/android_video_controller.dart';
import 'package:media_kit_video/src/video_controller/native_video_controller/native_video_controller.dart';
import 'package:media_kit_video/src/video_controller/output_operation.dart';

/// {@template platform_video_controller}
///
/// PlatformVideoController
/// -----------------------
///
/// This class provides the interface for platform specific [PlatformVideoController] implementations.
/// The platform specific implementations are expected to implement the methods accordingly.
///
/// The subclasses are then used in composition with the [PlatformVideoController] class, based on the platform the application is running on.
///
/// {@endtemplate}
abstract class PlatformVideoController {
  /// The [Player] instance associated with this instance.
  final Player player;

  /// User defined configuration for [PlatformVideoController].
  final VideoControllerConfiguration configuration;

  /// Texture ID of the video output, registered with Flutter engine by the native implementation.
  final ValueNotifier<int?> id = ValueNotifier<int?>(null);

  /// [Rect] of the video output, received from the native implementation.
  final ValueNotifier<Rect?> rect = ValueNotifier<Rect?>(null);

  final StreamController<VideoOutputProgress> _outputProgressController =
      StreamController<VideoOutputProgress>.broadcast(sync: true);

  /// Batches of frames that the platform texture consumer has acquired.
  Stream<VideoOutputProgress> get outputProgress =>
      _outputProgressController.stream;

  final _frameEvents = StreamController<VideoFrameEvent>.broadcast(sync: true);
  final _frameEventGate = VideoFrameEventGate();
  Stream<VideoFrameEvent> get frameEvents => _frameEvents.stream;
  bool frameTimelineSupported = false;

  Future<VideoFrameSamplingState?> setVideoFrameSampling(
    OutputOperationToken token,
    bool enabled,
  ) async => null;

  @protected
  void bindFrameOutput(OutputOperationToken? output) =>
      _frameEventGate.bind(output);

  @protected
  void emitFrameEvent(VideoFrameEvent event) {
    if (!_frameEvents.isClosed && _frameEventGate.accept(event))
      _frameEvents.add(event);
  }

  /// {@macro platform_video_controller}
  PlatformVideoController(this.player, this.configuration);

  /// Sets the required size of the video output.
  /// This may yield substantial performance improvements if a small [width] & [height] is specified.
  ///
  /// Remember:
  /// * “Premature optimization is the root of all evil”
  /// * “With great power comes great responsibility”
  Future<void>? setSize({int? width, int? height});

  /// 重建 Windows 视频渲染资源；调用者先将 mpv 的 vo 切到 null，完成后恢复。
  Future<void> resetRenderer() =>
      Future.error(UnsupportedError('Renderer reset is unavailable'));

  Future<OutputLoadSelectionResult> prepareForLoad(
    OutputOperationToken token,
    OutputPreparationRequest request,
  ) async => OutputLoadSelectionResult(
    strategy: OutputLoadSelectionStrategy.unknown,
    evidence: OutputLoadSelectionEvidence.unknown,
    outputEpoch: token.outputEpoch,
  );

  Future<OutputPreparationResult> confirmFileLoaded(
    OutputOperationToken token,
    NativeVideoOutputParameters? parameters, {
    required List<NativeVideoTrackMetadata>? videoTracks,
    required String? allowedTrackId,
  }) async => OutputPreparationResult(
    strategy: OutputPreparationStrategy.unknown,
    evidence: OutputPreparationEvidence.unknown,
    outputEpoch: token.outputEpoch,
  );

  /// Stages the token that the next native on-load hook will use.
  Future<void> beginOutputForLoad(OutputOperationToken token) async {}

  /// Waits for this load's current output attachment receipt.
  Future<OutputPreparationResult> waitForOutputAttach(
    OutputOperationToken token,
  ) async => OutputPreparationResult(
    strategy: OutputPreparationStrategy.unknown,
    evidence: OutputPreparationEvidence.unknown,
    outputEpoch: token.outputEpoch,
  );

  Future<void> invalidateOutputGeneration(OutputOperationToken token) async {}

  Future<void> releaseOutput() async {}

  @protected
  void emitOutputProgress(VideoOutputProgress progress) {
    if (!_outputProgressController.isClosed) {
      _outputProgressController.add(progress);
    }
  }

  @protected
  void closeOutputProgress() {
    unawaited(_outputProgressController.close());
    unawaited(_frameEvents.close());
  }

  /// A [Future] that completes when the first video frame has been rendered.
  Future<void> get waitUntilFirstFrameRendered =>
      waitUntilFirstFrameRenderedCompleter.future;

  /// [Completer] used to signal the decoding & rendering of the first video frame.
  /// Use [waitUntilFirstFrameRendered] to wait for the first frame to be rendered.
  @protected
  final waitUntilFirstFrameRenderedCompleter = Completer<void>();

  static Future<PlatformVideoController> create(
    Player player, {
    VideoControllerConfiguration configuration =
        const VideoControllerConfiguration(),
  }) {
    return (NativeVideoController.supported
        ? NativeVideoController.create
        : AndroidVideoController.supported
        ? AndroidVideoController.create
        : throw UnimplementedError(
            '[VideoController] is unavailable for ${Platform.operatingSystem}.',
          ))(player, configuration);
  }
}

/// {@template video_controller_configuration}
///
/// VideoControllerConfiguration
/// ----------------------------
/// Configurable options for customizing the [PlatformVideoController] behavior.
///
/// {@endtemplate}
class VideoControllerConfiguration {
  /// Sets the [`--vo`](https://mpv.io/manual/stable/#options-vo) property on native backend.
  ///
  /// Default: Platform specific.
  /// * Windows, GNU/Linux, macOS & iOS: `libmpv`
  /// * Android: `gpu`
  final String? vo;

  /// Sets the [`--hwdec`](https://mpv.io/manual/stable/#options-hwdec) property on native backend.
  ///
  /// Default: Platform specific.
  /// * Windows, GNU/Linux, macOS & iOS : `auto`
  /// * Android: `auto-safe`
  final String? hwdec;

  /// The fixed width for the video output.
  /// This may be used for performance reasons.
  ///
  /// Default: `null`
  final int? width;

  /// The fixed height for the video output.
  /// This may be used for performance reasons.
  ///
  /// Default: `null`
  final int? height;

  /// Whether to enable hardware acceleration.
  ///
  /// Default: `true`
  final bool enableHardwareAcceleration;

  /// 自动检测的设备物理像素上限。Android 将超限源等比缩小，
  /// 未超限源保持原尺寸；每次加载媒体时确定一次输出。
  final int? androidOutputLimitWidth;
  final int? androidOutputLimitHeight;

  /// 在每份媒体首次配置 Surface 时读取，获取播放器创建后才就绪的设备上限。
  final VideoOutputSize? Function()? androidOutputLimit;

  /// Sparse native surface lifecycle diagnostics; never called per frame.
  final void Function(String event, Map<String, Object?> details)?
  onAndroidDiagnostic;

  /// Whether to attach `android.view.Surface` after video parameters are known.
  ///
  /// The default Android path configures a verified single-track GPU Surface
  /// during the preloaded hook. Setting this to `true` keeps attachment on the
  /// post-load compatibility path.
  final bool? androidAttachSurfaceAfterVideoParameters;

  /// {@macro video_controller_configuration}
  const VideoControllerConfiguration({
    this.vo,
    this.hwdec,
    this.width,
    this.height,
    this.enableHardwareAcceleration = true,
    this.androidAttachSurfaceAfterVideoParameters,
    this.androidOutputLimitWidth,
    this.androidOutputLimitHeight,
    this.androidOutputLimit,
    this.onAndroidDiagnostic,
  });
}
