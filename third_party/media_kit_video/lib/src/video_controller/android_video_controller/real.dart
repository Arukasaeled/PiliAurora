/// This file is a part of media_kit (https://github.com/media-kit/media-kit).
///
/// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
/// All rights reserved.
/// Use of this source code is governed by MIT license that can be found in the LICENSE file.
import 'dart:io';
import 'dart:async';
import 'dart:collection';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:synchronized/synchronized.dart';
import 'package:media_kit_video/src/video_controller/android_video_controller/surface_size.dart';
import 'package:media_kit_video/src/video_controller/android_video_controller/fixed_surface_size.dart';
import 'package:media_kit_video/src/video_output_size_policy.dart';
import 'package:media_kit_video/src/video_controller/output_operation.dart';

import 'package:media_kit/media_kit.dart';

import 'package:media_kit_video/src/video_controller/platform_video_controller.dart';

/// {@template android_video_controller}
///
/// AndroidVideoController
/// ----------------------
///
/// The [PlatformVideoController] implementation based on native JNI & C/C++ used on Android.
///
/// {@endtemplate}
class AndroidVideoController extends PlatformVideoController {
  /// Whether [AndroidVideoController] is supported on the current platform or not.
  static bool get supported => Platform.isAndroid;

  /// Fixed width of the video output.
  int? width;

  /// Fixed height of the video output.
  int? height;

  // ----------------------------------------------

  bool get androidAttachSurfaceAfterVideoParameters =>
      configuration.androidAttachSurfaceAfterVideoParameters ?? false;

  /// --vo
  String get vo => configuration.vo ?? 'gpu';

  /// --hwdec
  // Future<String> get hwdec async {
  //   if (_hwdec != null) {
  //     return _hwdec!;
  //   }
  //   bool enableHardwareAcceleration = configuration.enableHardwareAcceleration;
  //   // Enforce software rendering in emulators.
  //   final bool isEmulator = await _channel.invokeMethod('Utils.IsEmulator');
  //   if (isEmulator) {
  //     debugPrint('media_kit: AndroidVideoController: Emulator detected.');
  //     debugPrint('media_kit: AndroidVideoController: Enforcing S/W rendering.');
  //     enableHardwareAcceleration = false;
  //   }
  //   _hwdec =
  //       configuration.hwdec ??
  //       (enableHardwareAcceleration ? 'auto-safe' : 'no');
  //   return _hwdec!;
  // }

  // ----------------------------------------------

  late final _fixedSize = AndroidFixedSurfaceSize(
    limitWidth: configuration.androidOutputLimitWidth,
    limitHeight: configuration.androidOutputLimitHeight,
    readLimit: configuration.androidOutputLimit,
  );
  ({int width, int height})? _appliedSize;
  bool _attached = false;
  int _mediaGeneration = 0;
  int _fallbackOutputEpoch = 0;
  OutputOperationToken? _operationToken;
  OutputOperationToken? _pendingOperationToken;
  OutputOperationToken? _highWaterToken;
  OutputLoadSelectionResult? _loadSelection;
  NativeVideoTrackMetadata? _selectedTrackMetadata;
  OutputOperationToken? _preloadedPreparedToken;
  ({int width, int height, double pixelAspectRatio, int rotation})?
  _preloadedPreparedGeometry;
  bool _runtimeManagedLoads = false;
  final Map<OutputOperationToken, Completer<OutputPreparationResult>>
  _outputAttachWaiters = {};
  OutputPreparationResult? _lastOutputAttachResult;
  OutputOperationToken? _lastOutputAttachToken;
  Future<void>? _disposeFuture;

  OutputPreparationResult _outputResult(
    OutputOperationToken token,
    OutputPreparationStrategy strategy,
    OutputPreparationEvidence evidence, {
    VideoOutputGeometry? geometry,
  }) => OutputPreparationResult(
    strategy: strategy,
    evidence: evidence,
    outputEpoch: token.outputEpoch,
    geometry: geometry,
  );

  OutputLoadSelectionResult _selectionResult(
    OutputOperationToken token,
    OutputLoadSelectionStrategy strategy,
    OutputLoadSelectionEvidence evidence, {
    String? trackId,
  }) => OutputLoadSelectionResult(
    strategy: strategy,
    evidence: evidence,
    outputEpoch: token.outputEpoch,
    trackId: trackId,
  );

  bool _canReplace(OutputOperationToken next, OutputOperationToken current) {
    if (next.runtimeId != current.runtimeId) {
      return next.runtimeId > current.runtimeId;
    }
    if (next.loadId != current.loadId) return next.loadId > current.loadId;
    if (next.outputEpoch != current.outputEpoch) {
      return next.outputEpoch > current.outputEpoch;
    }
    return next.configRevision > current.configRevision;
  }

  void _ensureOutputAttachWaiter(OutputOperationToken token) {
    _outputAttachWaiters.putIfAbsent(
      token,
      () => Completer<OutputPreparationResult>(),
    );
  }

  void _completeOutputAttach(
    OutputOperationToken token,
    OutputPreparationResult result,
  ) {
    if (token != _operationToken) return;
    if (_lastOutputAttachToken == token &&
        _lastOutputAttachResult?.strategy ==
            OutputPreparationStrategy.prepared &&
        result.strategy == OutputPreparationStrategy.legacyAttached) {
      return;
    }
    _lastOutputAttachToken = token;
    _lastOutputAttachResult = result;
    final waiter = _outputAttachWaiters[token];
    if (waiter != null && !waiter.isCompleted) waiter.complete(result);
  }

  void _completeOutputAttachUnknown(
    OutputOperationToken token,
    OutputPreparationEvidence evidence,
  ) {
    if (token == _operationToken || token == _lastOutputAttachToken) {
      _lastOutputAttachToken = token;
      _lastOutputAttachResult = _outputResult(
        token,
        OutputPreparationStrategy.unknown,
        evidence,
      );
    }
    final waiter = _outputAttachWaiters[token];
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete(
        _outputResult(token, OutputPreparationStrategy.unknown, evidence),
      );
    }
  }

  void _diagnostic(String event, [Map<String, Object?> details = const {}]) {
    try {
      configuration.onAndroidDiagnostic?.call(event, {
        'handle': player.handle,
        'textureId': id.value,
        'wid': _wid,
        'mediaGeneration': _mediaGeneration,
        'attached': _attached,
        'outputLimit': switch (_fixedSize.resolvedLimit) {
          final limit? => {'width': limit.width, 'height': limit.height},
          _ => null,
        },
        if (_fixedSize.size case final size?)
          'fixedOutput': {'width': size.width, 'height': size.height},
        ...details,
      });
    } catch (_) {
      /* 诊断回调与播放控制隔离。 */
    }
  }

  /// {@macro android_video_controller}
  AndroidVideoController._(super.player, super.configuration) {
    player.onLoadHooks.add(() {
      return _lock.synchronized(() async {
        _mediaGeneration++;
        final stagedToken = _pendingOperationToken;
        _pendingOperationToken = null;
        if (stagedToken == null && _runtimeManagedLoads) {
          throw StateError(
            'Runtime did not stage an output token for this load',
          );
        }
        final token =
            stagedToken ??
            OutputOperationToken(
              runtimeId: 0,
              loadId: _mediaGeneration,
              outputEpoch: ++_fallbackOutputEpoch,
              configRevision: 0,
            );
        _operationToken = token;
        _loadSelection = null;
        _selectedTrackMetadata = null;
        _preloadedPreparedToken = null;
        _preloadedPreparedGeometry = null;
        _ensureOutputAttachWaiter(token);
        _lastOutputAttachToken = null;
        _lastOutputAttachResult = null;
        _fixedSize.reset();
        _appliedSize = null;
        _attached = false;
        configuration.onAndroidFrameTimings?.call(const []);
        _diagnostic('surface.load');

        // Give every file identity a fresh Android Surface, even when the URI
        // repeats; MediaCodec can retain a previous Surface for the same path.
        _wid = await createAndroidSurface(player, token);
        if (_wid == null || _wid == 0) {
          throw StateError('Could not create Android video Surface');
        }
        _diagnostic('surface.created');

        // By default, android.view.Surface has a size of 1x1. If we assign --wid here, libmpv will internally start rendering & the first frame will be drawn as a solid color: https://github.com/media-kit/media-kit/issues/339
        // The solution is to assign --wid after android.graphics.SurfaceTexture.setDefaultBufferSize has been called & --android-surface-size has been updated (see inside player.stream.videoParams.listen).

        // Assign --wid here if --vo is not "gpu" or "null" i.e. custom vo/hwdec was passed through [VideoControllerConfiguration].
        try {
          // ----------------------------------------------
          if (vo != 'gpu' && !androidAttachSurfaceAfterVideoParameters) {
            player.setOption('wid', _wid.toString());
            player.setOption('vo', vo);
            _attached = true;
          }
          // ----------------------------------------------
        } catch (exception, stacktrace) {
          _diagnostic('surface.error', {
            'error': exception.toString(),
            'stack': stacktrace.toString(),
          });
          debugPrint(exception.toString());
          debugPrint(stacktrace.toString());
        }
      });
    });
    player.onUnloadHooks.add(() {
      return _lock.synchronized(() async {
        _attached = false;
        _appliedSize = null;
        _diagnostic('surface.unload');
        // Release any references to current android.view.Surface.
        //
        // It is important to set --vo=null here for 2 reasons:
        // 1. Allow the native code to drop any references to the android.view.Surface.
        // 2. Resize the android.graphics.SurfaceTexture to next video's resolution before setting --vo=gpu.
        try {
          // ----------------------------------------------
          player.setOption('vo', 'null');
          player.setOption('wid', '0');
          // ----------------------------------------------
        } catch (exception, stacktrace) {
          _diagnostic('surface.error', {
            'error': exception.toString(),
            'stack': stacktrace.toString(),
          });
          debugPrint(exception.toString());
          debugPrint(stacktrace.toString());
        }
        final token = _operationToken;
        if (token != null) {
          _operationToken = null;
          _loadSelection = null;
          _selectedTrackMetadata = null;
          _preloadedPreparedToken = null;
          _preloadedPreparedGeometry = null;
          _completeOutputAttachUnknown(
            token,
            OutputPreparationEvidence.outputMutationUnconfirmed,
          );
          await invalidateAndroidOutputGeneration(player, token);
        }
      });
    });

    _subscription = player.stream.videoParams.listen((event) async {
      // Runtime-managed loads use the identity-bound video-out-params snapshot
      // carried by NativeFileLoaded. A bare property notification has no file
      // identity and must not be relabeled with the newest output token.
      if (_runtimeManagedLoads) return;
      // 排队前绑定媒体与代数，避免切源后使用旧参数确定固定尺寸。
      final media = player.current.firstOrNull;
      final generation = _mediaGeneration;
      final token = _operationToken;
      await _lock.synchronized(() async {
        if (player.disposed ||
            media == null ||
            token == null ||
            token != _operationToken ||
            generation != _mediaGeneration ||
            !identical(player.current.firstOrNull, media)) {
          return;
        }
        final sourceSize = VideoOutputSizePolicy.videoDisplaySize(event);
        if (sourceSize == null || _wid == null) return;
        final width = sourceSize.width;
        final height = sourceSize.height;

        try {
          if (vo == 'gpu') {
            // NOTE: Only required for --vo=gpu
            // With --vo=gpu, we need to update the android.graphics.SurfaceTexture size & notify libmpv to re-create vo.
            // In native Android, this kind of rendering is done with android.view.SurfaceView + android.view.SurfaceHolder, which offers onSurfaceChanged to handle this.
            // 只在媒体加载/挂载时提交固定值；Flutter 视口不再参与此路径。
            final fixed = _fixedSize.resolve(width, height);
            // 无上限时沿用原生源尺寸更新；启用限幅后每份媒体保持固定输出。
            final size = _fixedSize.resolvedLimit == null ? sourceSize : fixed;
            if (!_attached || _appliedSize != size) {
              final watch = Stopwatch()..start();
              _diagnostic('surface.configure.begin', {
                'sourceWidth': width,
                'sourceHeight': height,
                'requestedWidth': size.width,
                'requestedHeight': size.height,
              });
              final accepted = await setAndroidSurfaceSize(
                player: player,
                width: size.width,
                height: size.height,
                wid: _wid,
                token: token,
                isCurrent: () => token == _operationToken,
              );
              _diagnostic('surface.configure.end', {
                'accepted': accepted,
                'durationUs': watch.elapsedMicroseconds,
              });
              if (!accepted) return;
              _appliedSize = size;
              _attached = true;
            }
          } else if (!_attached) {
            player.setOption('wid', _wid.toString());
            player.setOption('vo', vo);
            _attached = true;
          }
          // ----------------------------------------------
        } catch (exception, stacktrace) {
          _diagnostic('surface.error', {
            'error': exception.toString(),
            'stack': stacktrace.toString(),
          });
          debugPrint(exception.toString());
          debugPrint(stacktrace.toString());
          return;
        }
        if (_attached) {
          _completeOutputAttach(
            token,
            _outputResult(
              token,
              OutputPreparationStrategy.legacyAttached,
              OutputPreparationEvidence.legacyVideoParameters,
              geometry: VideoOutputGeometry(width: width, height: height),
            ),
          );
        }
        rect.value = Rect.fromLTRB(
          0.0,
          0.0,
          width.toDouble(),
          height.toDouble(),
        );
      });
    });
  }

  @override
  Future<OutputLoadSelectionResult> prepareForLoad(
    OutputOperationToken token,
    OutputPreparationRequest request,
  ) async {
    OutputLoadSelectionResult result(
      OutputLoadSelectionStrategy strategy,
      OutputLoadSelectionEvidence evidence, {
      String? trackId,
    }) => OutputLoadSelectionResult(
      strategy: strategy,
      evidence: evidence,
      outputEpoch: token.outputEpoch,
      trackId: trackId,
    );

    OutputLoadSelectionResult unknown(OutputLoadSelectionEvidence evidence) {
      final value = result(OutputLoadSelectionStrategy.unknown, evidence);
      if (token == _operationToken) _loadSelection = value;
      return value;
    }

    if (!player.supportsPreloadedHook) {
      return unknown(OutputLoadSelectionEvidence.preloadedHookUnavailable);
    }
    if (!request.nativeApi.isValid || token != _operationToken) {
      return unknown(OutputLoadSelectionEvidence.outputMutationUnconfirmed);
    }

    final List<NativeVideoTrackMetadata> tracks;
    try {
      tracks = request.nativeApi.readVideoTracks();
    } catch (_) {
      return unknown(OutputLoadSelectionEvidence.unknown);
    }
    if (!request.nativeApi.isValid || token != _operationToken) {
      return unknown(OutputLoadSelectionEvidence.outputMutationUnconfirmed);
    }
    if (tracks.isEmpty) {
      final noVideo = result(
        OutputLoadSelectionStrategy.noVideo,
        OutputLoadSelectionEvidence.nativeTrackListNoVideo,
      );
      _loadSelection = noVideo;
      _selectedTrackMetadata = null;
      _preloadedPreparedToken = null;
      _preloadedPreparedGeometry = null;
      return noVideo;
    }
    final allowedTrackId = request.allowedTrackId;
    if (allowedTrackId == null || allowedTrackId.isEmpty) {
      return unknown(OutputLoadSelectionEvidence.trackSelectionUnconfirmed);
    }
    if (tracks.length != 1) {
      final selectedTracks = tracks
          .where(
            (track) => track.selected == true && track.id == allowedTrackId,
          )
          .toList(growable: false);
      final selectedTrack = selectedTracks.length == 1
          ? selectedTracks.single
          : null;
      _loadSelection = result(
        OutputLoadSelectionStrategy.unknown,
        OutputLoadSelectionEvidence.multipleVideoTracks,
        trackId: selectedTrack?.id,
      );
      _selectedTrackMetadata = selectedTrack;
      return _loadSelection!;
    }
    if (tracks.single.id != allowedTrackId) {
      return unknown(OutputLoadSelectionEvidence.trackSelectionUnconfirmed);
    }
    if (tracks.single.selected != true) {
      try {
        request.nativeApi.setOption('vid', allowedTrackId);
      } catch (_) {
        return unknown(OutputLoadSelectionEvidence.trackSelectionUnconfirmed);
      }
      if (!request.nativeApi.isValid) {
        return unknown(OutputLoadSelectionEvidence.outputMutationUnconfirmed);
      }
    }
    final List<NativeVideoTrackMetadata> selectedTracks;
    try {
      selectedTracks = request.nativeApi.readVideoTracks();
    } catch (_) {
      return unknown(OutputLoadSelectionEvidence.unknown);
    }
    if (selectedTracks.length != 1 ||
        selectedTracks.single.id != allowedTrackId ||
        selectedTracks.single.selected != true) {
      return unknown(OutputLoadSelectionEvidence.trackSelectionUnconfirmed);
    }
    final track = selectedTracks.single;
    final width = track.demuxWidth;
    final height = track.demuxHeight;
    final selected = result(
      OutputLoadSelectionStrategy.selectedVideo,
      OutputLoadSelectionEvidence.nativeTrackListSingleVideo,
      trackId: allowedTrackId,
    );
    _loadSelection = selected;
    _selectedTrackMetadata = track;
    _preloadedPreparedToken = null;
    _preloadedPreparedGeometry = null;

    // 单视频轨先挂载 Surface，避免 vo=null 解码后再切 GPU 导致解码器重建。
    // 裁剪、PAR 或旋转未知时，缓冲区尺寸先用 demux 几何，FILE_LOADED 再确认。
    if (vo != 'gpu' || androidAttachSurfaceAfterVideoParameters) {
      return selected;
    }
    if (width == null || height == null || width <= 0 || height <= 0) {
      return result(
        OutputLoadSelectionStrategy.selectedVideo,
        OutputLoadSelectionEvidence.invalidDemuxGeometry,
        trackId: allowedTrackId,
      );
    }
    final sourceWidth = request.sourceWidth;
    final sourceHeight = request.sourceHeight;
    final pixelAspectRatio = track.demuxPar ?? request.pixelAspectRatio;
    final rotation = track.demuxRotate ?? request.rotation;
    final cropKnownNone =
        request.cropKnownNone || track.demuxCropKnownNone == true;
    final geometryConfirmed =
        cropKnownNone &&
        (sourceWidth == null || sourceWidth == width) &&
        (sourceHeight == null || sourceHeight == height) &&
        pixelAspectRatio == 1.0 &&
        rotation == 0 &&
        (track.demuxPar == null ||
            request.pixelAspectRatio == null ||
            track.demuxPar == request.pixelAspectRatio) &&
        (track.demuxRotate == null ||
            request.rotation == null ||
            track.demuxRotate == request.rotation);
    if (!request.nativeApi.isValid || token != _operationToken) {
      return result(
        OutputLoadSelectionStrategy.unknown,
        OutputLoadSelectionEvidence.outputMutationUnconfirmed,
      );
    }
    try {
      if (_wid == null || _wid == 0) {
        _wid = await createAndroidSurface(player, token);
      }
      if (_wid == null || _wid == 0 || !request.nativeApi.isValid) {
        return result(
          OutputLoadSelectionStrategy.unknown,
          OutputLoadSelectionEvidence.outputMutationUnconfirmed,
        );
      }
      final fixed = _fixedSize.resolve(width, height);
      final size = _fixedSize.resolvedLimit == null
          ? (width: width, height: height)
          : fixed;
      final accepted = await setAndroidSurfaceSize(
        player: player,
        width: size.width,
        height: size.height,
        token: token,
        wid: _wid,
        isCurrent: () => request.nativeApi.isValid && token == _operationToken,
        setOption: request.nativeApi.setOption,
      );
      if (!accepted || !request.nativeApi.isValid || token != _operationToken) {
        return result(
          OutputLoadSelectionStrategy.unknown,
          OutputLoadSelectionEvidence.outputMutationUnconfirmed,
        );
      }
      _appliedSize = size;
      _attached = true;
      if (geometryConfirmed) {
        _preloadedPreparedToken = token;
        _preloadedPreparedGeometry = (
          width: width,
          height: height,
          pixelAspectRatio: pixelAspectRatio!,
          rotation: rotation!,
        );
      }
      _diagnostic(
        geometryConfirmed ? 'surface.prepared' : 'surface.provisional',
        {
          'demuxWidth': width,
          'demuxHeight': height,
          'outputWidth': size.width,
          'outputHeight': size.height,
          'outputEpoch': token.outputEpoch,
        },
      );
      return result(
        OutputLoadSelectionStrategy.selectedVideo,
        geometryConfirmed
            ? OutputLoadSelectionEvidence.preloadedSurfaceConfigured
            : cropKnownNone
            ? OutputLoadSelectionEvidence.invalidDemuxGeometry
            : OutputLoadSelectionEvidence.cropUnconfirmed,
        trackId: allowedTrackId,
      );
    } catch (error, stack) {
      _diagnostic('surface.prepare-error', {
        'error': error.toString(),
        'stack': stack.toString(),
      });
      return result(
        OutputLoadSelectionStrategy.unknown,
        OutputLoadSelectionEvidence.outputMutationUnconfirmed,
      );
    }
  }

  @override
  Future<OutputPreparationResult> confirmFileLoaded(
    OutputOperationToken token,
    NativeVideoOutputParameters? parameters, {
    required List<NativeVideoTrackMetadata>? videoTracks,
    required String? allowedTrackId,
  }) async {
    OutputPreparationResult unknown(OutputPreparationEvidence evidence) =>
        _outputResult(token, OutputPreparationStrategy.unknown, evidence);

    if (token != _operationToken || videoTracks == null) {
      return unknown(OutputPreparationEvidence.loadedFileGeometry);
    }
    if (videoTracks.isEmpty) {
      final noVideo = _outputResult(
        token,
        OutputPreparationStrategy.noVideo,
        OutputPreparationEvidence.nativeTrackListNoVideo,
      );
      _completeOutputAttach(token, noVideo);
      return noVideo;
    }
    if (parameters == null) {
      return unknown(OutputPreparationEvidence.loadedFileGeometry);
    }
    final selectedTrackId = _selectedTrackMetadata?.id;
    final selection = _loadSelection;
    final activeTracks = videoTracks
        .where((track) => track.selected == true)
        .toList(growable: false);
    if (activeTracks.length != 1) {
      return unknown(
        videoTracks.length > 1
            ? OutputPreparationEvidence.multipleVideoTracks
            : OutputPreparationEvidence.trackSelectionUnconfirmed,
      );
    }
    final loadedTrack = activeTracks.single;
    final expectedTrackId = selectedTrackId ?? allowedTrackId;
    if (expectedTrackId == null ||
        expectedTrackId.isEmpty ||
        loadedTrack.id != expectedTrackId ||
        (allowedTrackId != null && loadedTrack.id != allowedTrackId)) {
      return unknown(OutputPreparationEvidence.trackSelectionUnconfirmed);
    }
    final selectionCanUseLegacy =
        selection?.strategy == OutputLoadSelectionStrategy.unknown &&
        selection?.evidence ==
            OutputLoadSelectionEvidence.multipleVideoTracks &&
        selection?.trackId == loadedTrack.id;
    final lateLegacySelection =
        selection == null ||
        selection.evidence ==
            OutputLoadSelectionEvidence.preloadedHookUnavailable ||
        selection.evidence == OutputLoadSelectionEvidence.unknown ||
        selection.evidence ==
            OutputLoadSelectionEvidence.trackSelectionUnconfirmed;
    if (selection != null && selection.outputEpoch != token.outputEpoch) {
      return unknown(OutputPreparationEvidence.trackSelectionUnconfirmed);
    }
    if (selection != null &&
        selection.strategy != OutputLoadSelectionStrategy.selectedVideo &&
        !selectionCanUseLegacy &&
        !lateLegacySelection) {
      return unknown(
        selection.evidence == OutputLoadSelectionEvidence.multipleVideoTracks
            ? OutputPreparationEvidence.multipleVideoTracks
            : OutputPreparationEvidence.trackSelectionUnconfirmed,
      );
    }
    if (selectedTrackId != null && selectedTrackId != loadedTrack.id) {
      return unknown(OutputPreparationEvidence.trackSelectionUnconfirmed);
    }
    final preparedTrack = _selectedTrackMetadata;
    if (preparedTrack != null &&
        (preparedTrack.id != loadedTrack.id ||
            preparedTrack.demuxWidth != null &&
                preparedTrack.demuxWidth != loadedTrack.demuxWidth ||
            preparedTrack.demuxHeight != null &&
                preparedTrack.demuxHeight != loadedTrack.demuxHeight ||
            preparedTrack.demuxPar != null &&
                preparedTrack.demuxPar != loadedTrack.demuxPar ||
            preparedTrack.demuxRotate != null &&
                preparedTrack.demuxRotate != loadedTrack.demuxRotate ||
            preparedTrack.demuxCropKnownNone != null &&
                preparedTrack.demuxCropKnownNone !=
                    loadedTrack.demuxCropKnownNone)) {
      return unknown(OutputPreparationEvidence.loadedFileGeometry);
    }
    if (loadedTrack.demuxWidth != null &&
            loadedTrack.demuxWidth != parameters.width ||
        loadedTrack.demuxHeight != null &&
            loadedTrack.demuxHeight != parameters.height) {
      return unknown(OutputPreparationEvidence.loadedFileGeometry);
    }
    _selectedTrackMetadata = loadedTrack;
    if (lateLegacySelection) {
      _loadSelection = _selectionResult(
        token,
        OutputLoadSelectionStrategy.unknown,
        OutputLoadSelectionEvidence.preloadedHookUnavailable,
        trackId: loadedTrack.id,
      );
    }
    final width = parameters.displayWidth;
    final height = parameters.displayHeight;
    final rawWidth = parameters.width;
    final rawHeight = parameters.height;
    final par = parameters.pixelAspectRatio;
    final rotation = parameters.rotation;
    if (width == null ||
        height == null ||
        width <= 0 ||
        height <= 0 ||
        rawWidth == null ||
        rawHeight == null ||
        rawWidth <= 0 ||
        rawHeight <= 0 ||
        par == null ||
        !par.isFinite ||
        par <= 0 ||
        rotation == null) {
      return unknown(OutputPreparationEvidence.invalidDemuxGeometry);
    }
    final normalizedRotation = rotation % 360;
    if (normalizedRotation != 0 &&
        normalizedRotation != 90 &&
        normalizedRotation != 180 &&
        normalizedRotation != 270) {
      return unknown(OutputPreparationEvidence.invalidDemuxGeometry);
    }
    final displaySize = normalizedRotation == 90 || normalizedRotation == 270
        ? (width: height, height: width)
        : (width: width, height: height);

    final preparedGeometry = _preloadedPreparedGeometry;
    if (_preloadedPreparedToken == token &&
        _attached &&
        preparedGeometry != null) {
      final track = _selectedTrackMetadata!;
      if (_requestGeometryMatches(track, preparedGeometry, parameters)) {
        final geometry = _appliedSize ?? displaySize;
        final prepared = _outputResult(
          token,
          OutputPreparationStrategy.prepared,
          OutputPreparationEvidence.preloadedSurfaceConfiguration,
          geometry: VideoOutputGeometry(
            width: geometry.width,
            height: geometry.height,
          ),
        );
        _completeOutputAttach(token, prepared);
        rect.value = Rect.fromLTWH(
          0,
          0,
          displaySize.width.toDouble(),
          displaySize.height.toDouble(),
        );
        return prepared;
      }
    }

    try {
      if (vo == 'gpu') {
        if (_wid == null || _wid == 0) {
          _wid = await createAndroidSurface(player, token);
        }
        if (_wid == null || _wid == 0) {
          return unknown(OutputPreparationEvidence.outputMutationUnconfirmed);
        }
        // 临时缓冲区的宽高比不作为最终输出几何；保持已经挂载的 VO。
        if (_attached && _preloadedPreparedToken != token) _fixedSize.reset();
        final fixed = _fixedSize.resolve(displaySize.width, displaySize.height);
        final size = _fixedSize.resolvedLimit == null ? displaySize : fixed;
        if (!_attached || _appliedSize != size) {
          final accepted = await setAndroidSurfaceSize(
            player: player,
            width: size.width,
            height: size.height,
            token: token,
            wid: _attached ? null : _wid,
            isCurrent: () => token == _operationToken,
          );
          if (!accepted || token != _operationToken) {
            return unknown(OutputPreparationEvidence.outputMutationUnconfirmed);
          }
        }
        _appliedSize = size;
        _attached = true;
      } else if (!_attached) {
        if (_wid == null || _wid == 0) {
          return unknown(OutputPreparationEvidence.outputMutationUnconfirmed);
        }
        player.setOption('wid', _wid.toString());
        player.setOption('vo', vo);
        _attached = true;
      } else if (_wid == null) {
        return unknown(OutputPreparationEvidence.outputMutationUnconfirmed);
      }
      final result = _outputResult(
        token,
        OutputPreparationStrategy.legacyAttached,
        OutputPreparationEvidence.loadedFileGeometry,
        geometry: VideoOutputGeometry(
          width: _appliedSize?.width ?? displaySize.width,
          height: _appliedSize?.height ?? displaySize.height,
        ),
      );
      rect.value = Rect.fromLTWH(
        0,
        0,
        displaySize.width.toDouble(),
        displaySize.height.toDouble(),
      );
      _completeOutputAttach(token, result);
      return result;
    } catch (error, stack) {
      _diagnostic('surface.confirm-error', {
        'error': error.toString(),
        'stack': stack.toString(),
      });
      return unknown(OutputPreparationEvidence.outputMutationUnconfirmed);
    }
  }

  bool _requestGeometryMatches(
    NativeVideoTrackMetadata track,
    ({int width, int height, double pixelAspectRatio, int rotation})
    preparedGeometry,
    NativeVideoOutputParameters parameters,
  ) =>
      track.demuxWidth == preparedGeometry.width &&
      track.demuxHeight == preparedGeometry.height &&
      (track.demuxPar == null ||
          track.demuxPar == preparedGeometry.pixelAspectRatio) &&
      (track.demuxRotate == null ||
          track.demuxRotate == preparedGeometry.rotation) &&
      parameters.width == preparedGeometry.width &&
      parameters.height == preparedGeometry.height &&
      parameters.pixelAspectRatio == preparedGeometry.pixelAspectRatio &&
      parameters.rotation == preparedGeometry.rotation &&
      parameters.displayWidth == preparedGeometry.width &&
      parameters.displayHeight == preparedGeometry.height;

  @override
  Future<void> invalidateOutputGeneration(OutputOperationToken token) async {
    if (token == _pendingOperationToken) _pendingOperationToken = null;
    if (token == _operationToken) {
      _operationToken = null;
      _mediaGeneration++;
      _attached = false;
      _appliedSize = null;
      _loadSelection = null;
      _selectedTrackMetadata = null;
      _preloadedPreparedToken = null;
      _preloadedPreparedGeometry = null;
    }
    _completeOutputAttachUnknown(
      token,
      OutputPreparationEvidence.outputMutationUnconfirmed,
    );
    await invalidateAndroidOutputGeneration(player, token);
  }

  @override
  Future<void> beginOutputForLoad(OutputOperationToken token) async {
    if (token.runtimeId == 0) {
      throw ArgumentError.value(token.runtimeId, 'runtimeId');
    }
    if (_disposeFuture != null) {
      throw StateError('Video output is being released');
    }
    final highWater = _highWaterToken;
    if (highWater != null &&
        token != highWater &&
        !_canReplace(token, highWater)) {
      throw StateError('A stale Android output generation cannot be activated');
    }
    if (highWater == token &&
        _operationToken != token &&
        _pendingOperationToken != token) {
      throw StateError('A revoked Android output generation cannot be reused');
    }
    final previousPendingToken = _pendingOperationToken;
    if (previousPendingToken != null && previousPendingToken != token) {
      _completeOutputAttachUnknown(
        previousPendingToken,
        OutputPreparationEvidence.outputMutationUnconfirmed,
      );
    }
    for (final entry in _outputAttachWaiters.entries.toList()) {
      if (entry.key == token) continue;
      if (!entry.value.isCompleted) {
        entry.value.complete(
          _outputResult(
            entry.key,
            OutputPreparationStrategy.unknown,
            OutputPreparationEvidence.outputMutationUnconfirmed,
          ),
        );
      }
      _outputAttachWaiters.remove(entry.key);
    }
    _runtimeManagedLoads = true;
    _highWaterToken = token;
    _pendingOperationToken = token;
    _ensureOutputAttachWaiter(token);
    _lastOutputAttachToken = null;
    _lastOutputAttachResult = null;
    if (!await beginAndroidOutputOperation(player, token) ||
        _pendingOperationToken != token) {
      _completeOutputAttachUnknown(
        token,
        OutputPreparationEvidence.outputMutationUnconfirmed,
      );
      throw StateError('Android output rejected the load generation');
    }
  }

  @override
  Future<OutputPreparationResult> waitForOutputAttach(
    OutputOperationToken token,
  ) {
    if (_lastOutputAttachToken == token && _lastOutputAttachResult != null) {
      return Future.value(_lastOutputAttachResult);
    }
    if (_disposeFuture != null) {
      return Future.value(
        _outputResult(
          token,
          OutputPreparationStrategy.unknown,
          OutputPreparationEvidence.unknown,
        ),
      );
    }
    return _outputAttachWaiters
        .putIfAbsent(token, () => Completer<OutputPreparationResult>())
        .future;
  }

  @override
  Future<void> releaseOutput() => _dispose();

  /// {@macro android_video_controller}
  static Future<PlatformVideoController> create(
    Player player,
    VideoControllerConfiguration configuration,
  ) async {
    // Retrieve the native handle of the [Player].
    final handle = player.handle;
    // Return the existing [VideoController] if it's already created.
    if (_controllers.containsKey(handle)) {
      return _controllers[handle]!;
    }

    // Creation:
    final controller = AndroidVideoController._(player, configuration);

    // Register [_dispose] for execution upon [Player.dispose].
    player.release.add(controller._dispose);

    // Store the [VideoController] in the [_controllers].
    _controllers[handle] = controller;

    final data = await _channel.invokeMethod('VideoOutputManager.Create', {
      'handle': handle.toString(),
      'reportTimings': configuration.onAndroidFrameTimings != null,
    });
    debugPrint(data.toString());

    final int? id = data['id'];

    // ----------------------------------------------

    final values = {
      // It is necessary to set vo=null here to avoid SIGSEGV, --wid must be assigned before vo=gpu is set.
      'vo': 'null',
      'hwdec':
          configuration.hwdec ??
          (configuration.enableHardwareAcceleration ? 'auto-safe' : 'no'),
      'vid': 'auto',
      'opengl-es': 'yes',
      'force-window': 'yes',
      'gpu-context': 'android',
      'sub-use-margins': 'no',
      'sub-font-provider': 'none',
      'sub-scale-with-window': 'yes',
      'hwdec-codecs': 'h264,hevc,mpeg4,mpeg2video,vp8,vp9,av1',
    };

    for (final entry in values.entries) {
      player.setProperty(entry.key, entry.value);
    }
    // ----------------------------------------------

    controller.id.value = id;

    // Return the [PlatformVideoController].
    return controller;
  }

  /// Sets the required size of the video output.
  /// This may yield substantial performance improvements if a small [width] & [height] is specified.
  ///
  /// Remember:
  /// * “Premature optimization is the root of all evil”
  /// * “With great power comes great responsibility”
  @override
  Future<void>? setSize({int? width, int? height}) {
    throw UnsupportedError(
      '[AndroidVideoController.setSize] is not available on Android',
    );
  }

  /// Disposes the instance. Releases allocated resources back to the system.
  Future<void> _dispose() => _disposeFuture ??= _release();

  Future<void> _release() async {
    _diagnostic('surface.dispose');
    _mediaGeneration++;
    final token = _operationToken;
    final pendingToken = _pendingOperationToken;
    _operationToken = null;
    _pendingOperationToken = null;
    _loadSelection = null;
    _selectedTrackMetadata = null;
    _preloadedPreparedToken = null;
    _preloadedPreparedGeometry = null;
    _attached = false;
    if (token != null) {
      _completeOutputAttachUnknown(
        token,
        OutputPreparationEvidence.outputMutationUnconfirmed,
      );
    }
    if (pendingToken != null && pendingToken != token) {
      _completeOutputAttachUnknown(
        pendingToken,
        OutputPreparationEvidence.outputMutationUnconfirmed,
      );
    }
    closeOutputProgress();
    if (token != null) {
      await invalidateAndroidOutputGeneration(player, token);
    }
    await cancelAndroidSurfaceFrameWait(player);
    // Dispose the [StreamSubscription]s.
    await _subscription?.cancel();
    // Release the native resources.
    final handle = player.handle;
    await _channel.invokeMethod('VideoOutputManager.Dispose', {
      'handle': handle.toString(),
    });
    _controllers.remove(handle);
  }

  /// Pointer address to the global object reference of `android.view.Surface` i.e. `(intptr_t)(*android.view.Surface)`.
  int? _wid;

  /// [Lock] used to synchronize the [_widthStreamSubscription] & [_heightStreamSubscription].
  final _lock = Lock();

  /// [StreamSubscription] for listening to video [Rect] from [_controller].
  StreamSubscription<VideoParams>? _subscription;

  /// Currently created [AndroidVideoController]s.
  static final _controllers = HashMap<int, AndroidVideoController>();

  /// [MethodChannel] for invoking platform specific native implementation.
  static final _channel =
      const MethodChannel(
        'com.alexmercerind/media_kit_video',
      )..setMethodCallHandler((MethodCall call) async {
        try {
          if (call.method != 'VideoOutput.FrameTimings') {
            debugPrint(call.method.toString());
            debugPrint(call.arguments.toString());
          }
          switch (call.method) {
            case 'VideoOutput.ConsumedFrames':
              {
                final arguments = Map<Object?, Object?>.from(
                  call.arguments as Map,
                );
                final handle = int.parse(arguments['handle'].toString());
                final controller = _controllers[handle];
                final tokenData = Map<Object?, Object?>.from(
                  arguments['token'] as Map,
                );
                final token = OutputOperationToken.fromPlatformArguments(
                  tokenData,
                );
                if (controller != null &&
                    controller._disposeFuture == null &&
                    controller._operationToken == token) {
                  controller.emitOutputProgress(
                    VideoOutputProgress(
                      token: token,
                      consumedAtMonotonicUs: List<int>.from(
                        arguments['consumedAtMonotonicUs'] as List,
                      ),
                    ),
                  );
                }
                break;
              }
            case 'VideoOutput.FrameTimings':
              {
                final int handle = call.arguments['handle'];
                final controller = _controllers[handle];
                if (controller != null && controller._attached) {
                  controller.configuration.onAndroidFrameTimings?.call(
                    List<int>.from(call.arguments['frames'] as List),
                  );
                }
                break;
              }
            case 'VideoOutput.Diagnostic':
              {
                final arguments = Map<String, Object?>.from(
                  call.arguments as Map,
                );
                final handle = arguments.remove('handle') as int;
                final event = arguments.remove('event') as String;
                _controllers[handle]?._diagnostic(event, arguments);
                break;
              }
            case 'VideoOutput.WaitUntilFirstFrameRenderedNotify':
              {
                // Notify about updated texture ID & [Rect].
                final int handle = call.arguments['handle'];
                debugPrint(handle.toString());
                // Notify about the first frame being rendered.
                final completer =
                    _controllers[handle]?.waitUntilFirstFrameRenderedCompleter;
                if (!(completer?.isCompleted ?? true)) {
                  completer?.complete();
                }
                break;
              }
            default:
              {
                break;
              }
          }
        } catch (exception, stacktrace) {
          debugPrint(exception.toString());
          debugPrint(stacktrace.toString());
        }
      });
}
