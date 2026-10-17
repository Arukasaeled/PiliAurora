/// This file is a part of media_kit (https://github.com/media-kit/media-kit).
///
/// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
/// All rights reserved.
/// Use of this source code is governed by MIT license that can be found in the LICENSE file.
import 'dart:io';
import 'dart:ffi';
import 'dart:async';
import 'dart:collection';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

import 'package:media_kit/media_kit.dart';
// ignore_for_file: unused_import, implementation_imports
import 'package:media_kit/ffi/ffi.dart';
import 'package:media_kit/src/player/native/core/native_library.dart';

import 'package:media_kit/generated/libmpv/bindings.dart';

import 'package:media_kit_video/src/video_controller/video_controller.dart';
import 'package:media_kit_video/src/video_controller/platform_video_controller.dart';
import 'package:media_kit_video/src/video_controller/output_operation.dart';

/// {@template native_video_controller}
///
/// NativeVideoController
/// ---------------------
///
/// The [PlatformVideoController] implementation based on native C/C++ used on:
/// * Windows
/// * GNU/Linux
/// * macOS
/// * iOS
///
/// {@endtemplate}
class NativeVideoController extends PlatformVideoController {
  /// Whether [NativeVideoController] is supported on the current platform or not.
  static bool get supported =>
      Platform.isWindows ||
      Platform.isLinux ||
      Platform.isMacOS ||
      Platform.isIOS;

  /// Fixed width of the video output.
  int? width;

  /// Fixed height of the video output.
  int? height;

  /// {@macro native_video_controller}
  NativeVideoController._(super.player, super.configuration)
    : width = configuration.width,
      height = configuration.height;

  OutputOperationToken? _operationToken;
  OutputOperationToken? _highWaterToken;
  String? _selectedTrackId;
  NativeVideoTrackMetadata? _selectedTrackMetadata;
  OutputLoadSelectionResult? _loadSelection;
  final Map<OutputOperationToken, Completer<OutputPreparationResult>>
  _outputAttachWaiters = {};
  OutputOperationToken? _lastOutputAttachToken;
  OutputPreparationResult? _lastOutputAttachResult;
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

  bool _canReplace(OutputOperationToken token, OutputOperationToken other) {
    if (token.runtimeId != other.runtimeId) {
      return token.runtimeId > other.runtimeId;
    }
    if (token.loadId != other.loadId) return token.loadId > other.loadId;
    if (token.outputEpoch != other.outputEpoch) {
      return token.outputEpoch > other.outputEpoch;
    }
    return token.configRevision > other.configRevision;
  }

  void _completeOutputAttach(
    OutputOperationToken token,
    OutputPreparationResult result,
  ) {
    _lastOutputAttachToken = token;
    _lastOutputAttachResult = result;
    final waiter = _outputAttachWaiters[token];
    if (waiter != null && !waiter.isCompleted) waiter.complete(result);
  }

  void _completeOutputAttachUnknown(OutputOperationToken token) {
    _completeOutputAttach(
      token,
      _outputResult(
        token,
        OutputPreparationStrategy.unknown,
        OutputPreparationEvidence.outputMutationUnconfirmed,
      ),
    );
  }

  void _completeOtherWaitersUnknown(OutputOperationToken current) {
    for (final entry in _outputAttachWaiters.entries.toList()) {
      if (entry.key == current) continue;
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
  }

  @override
  Future<void> beginOutputForLoad(OutputOperationToken token) async {
    if (token.runtimeId <= 0 || token.loadId <= 0 || token.outputEpoch <= 0) {
      throw ArgumentError.value(token, 'token');
    }
    if (_disposeFuture != null) {
      throw StateError('Video output is being released');
    }
    final highWater = _highWaterToken;
    if (highWater != null) {
      if (token == highWater) {
        if (_operationToken == token) return;
        throw StateError('A revoked output generation cannot be reused');
      }
      if (!_canReplace(token, highWater)) {
        throw StateError('A stale output generation cannot be activated');
      }
    }
    final previous = _operationToken;
    if (previous != null && previous != token) {
      _completeOutputAttachUnknown(previous);
    }
    _completeOtherWaitersUnknown(token);
    _highWaterToken = token;
    _operationToken = token;
    _selectedTrackId = null;
    _selectedTrackMetadata = null;
    _loadSelection = null;
    _outputAttachWaiters[token] = Completer<OutputPreparationResult>();
    _lastOutputAttachToken = null;
    _lastOutputAttachResult = null;
    final accepted = await _channel.invokeMethod<bool>(
      'VideoOutputManager.BeginOutputForLoad',
      {
        'handle': player.handle.toString(),
        'token': token.toPlatformArguments(),
      },
    );
    if (accepted != true || _operationToken != token) {
      _completeOutputAttachUnknown(token);
      throw StateError('Native output rejected the load generation');
    }
  }

  @override
  Future<OutputLoadSelectionResult> prepareForLoad(
    OutputOperationToken token,
    OutputPreparationRequest request,
  ) async {
    OutputLoadSelectionResult selection(
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
      final result = selection(OutputLoadSelectionStrategy.unknown, evidence);
      if (_operationToken == token) _loadSelection = result;
      return result;
    }

    if (!player.supportsPreloadedHook) {
      return unknown(OutputLoadSelectionEvidence.preloadedHookUnavailable);
    }
    if (_operationToken != token || !request.nativeApi.isValid) {
      return unknown(OutputLoadSelectionEvidence.outputMutationUnconfirmed);
    }

    final List<NativeVideoTrackMetadata> tracks;
    try {
      tracks = request.nativeApi.readVideoTracks();
    } catch (_) {
      return unknown(OutputLoadSelectionEvidence.unknown);
    }
    if (!request.nativeApi.isValid || _operationToken != token) {
      return unknown(OutputLoadSelectionEvidence.outputMutationUnconfirmed);
    }
    if (tracks.isEmpty) {
      final noVideo = selection(
        OutputLoadSelectionStrategy.noVideo,
        OutputLoadSelectionEvidence.nativeTrackListNoVideo,
      );
      _loadSelection = noVideo;
      _selectedTrackId = null;
      _selectedTrackMetadata = null;
      return noVideo;
    }

    final allowedTrackId = request.allowedTrackId;
    if (allowedTrackId == null || allowedTrackId.isEmpty) {
      return unknown(OutputLoadSelectionEvidence.trackSelectionUnconfirmed);
    }
    if (tracks.length != 1) {
      final selected = tracks
          .where((track) => track.selected == true)
          .toList(growable: false);
      final selectedTrackId =
          selected.length == 1 && selected.single.id == allowedTrackId
          ? selected.single.id
          : null;
      _selectedTrackId = selectedTrackId;
      _selectedTrackMetadata = selected.length == 1 ? selected.single : null;
      final result = selection(
        OutputLoadSelectionStrategy.unknown,
        OutputLoadSelectionEvidence.multipleVideoTracks,
        trackId: selectedTrackId,
      );
      _loadSelection = result;
      return result;
    }

    if (tracks.single.id != allowedTrackId) {
      return unknown(OutputLoadSelectionEvidence.trackSelectionUnconfirmed);
    }
    var selectedTrack = tracks.single;
    if (tracks.single.selected != true) {
      try {
        request.nativeApi.setOption('vid', allowedTrackId);
      } catch (_) {
        return unknown(OutputLoadSelectionEvidence.trackSelectionUnconfirmed);
      }
      if (!request.nativeApi.isValid) {
        return unknown(OutputLoadSelectionEvidence.outputMutationUnconfirmed);
      }
      try {
        final selected = request.nativeApi.readVideoTracks();
        if (selected.length != 1 ||
            selected.single.id != allowedTrackId ||
            selected.single.selected != true) {
          return unknown(OutputLoadSelectionEvidence.trackSelectionUnconfirmed);
        }
        selectedTrack = selected.single;
      } catch (_) {
        return unknown(OutputLoadSelectionEvidence.unknown);
      }
    }

    _selectedTrackId = allowedTrackId;
    _selectedTrackMetadata = selectedTrack;
    final selectedVideo = selection(
      OutputLoadSelectionStrategy.selectedVideo,
      OutputLoadSelectionEvidence.nativeTrackListSingleVideo,
      trackId: allowedTrackId,
    );
    _loadSelection = selectedVideo;
    return selectedVideo;
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

    if (_operationToken != token || videoTracks == null) {
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
    final selection = _loadSelection;
    final previousTrackId = _selectedTrackId;
    final activeTracks = videoTracks
        .where((track) => track.selected == true)
        .toList(growable: false);
    if (activeTracks.length != 1) {
      return unknown(
        videoTracks.length > 1 ||
                selection?.evidence ==
                    OutputLoadSelectionEvidence.multipleVideoTracks
            ? OutputPreparationEvidence.multipleVideoTracks
            : OutputPreparationEvidence.trackSelectionUnconfirmed,
      );
    }
    final loadedTrack = activeTracks.single;
    final trackId = previousTrackId ?? allowedTrackId;
    if (trackId == null ||
        trackId.isEmpty ||
        loadedTrack.id != trackId ||
        (allowedTrackId != null && loadedTrack.id != allowedTrackId)) {
      return unknown(OutputPreparationEvidence.trackSelectionUnconfirmed);
    }
    final lateLegacySelection =
        selection == null ||
        selection.evidence ==
            OutputLoadSelectionEvidence.preloadedHookUnavailable ||
        selection.evidence == OutputLoadSelectionEvidence.unknown ||
        selection.evidence ==
            OutputLoadSelectionEvidence.trackSelectionUnconfirmed;
    final multipleTrackLegacy =
        selection?.strategy == OutputLoadSelectionStrategy.unknown &&
        selection?.evidence ==
            OutputLoadSelectionEvidence.multipleVideoTracks &&
        selection?.trackId == loadedTrack.id;
    if (selection != null && selection.outputEpoch != token.outputEpoch) {
      return unknown(OutputPreparationEvidence.trackSelectionUnconfirmed);
    }
    if (selection != null &&
        selection.strategy != OutputLoadSelectionStrategy.selectedVideo &&
        !lateLegacySelection &&
        !multipleTrackLegacy) {
      return unknown(
        selection.evidence == OutputLoadSelectionEvidence.multipleVideoTracks
            ? OutputPreparationEvidence.multipleVideoTracks
            : OutputPreparationEvidence.trackSelectionUnconfirmed,
      );
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
    _selectedTrackId = loadedTrack.id;
    _selectedTrackMetadata = loadedTrack;
    if (lateLegacySelection) {
      _loadSelection = OutputLoadSelectionResult(
        strategy: OutputLoadSelectionStrategy.unknown,
        evidence: OutputLoadSelectionEvidence.preloadedHookUnavailable,
        outputEpoch: token.outputEpoch,
        trackId: loadedTrack.id,
      );
    }
    final rotation = parameters.rotation;
    final par = parameters.pixelAspectRatio;
    final displayWidth = parameters.displayWidth;
    final displayHeight = parameters.displayHeight;
    final rawWidth = parameters.width;
    final rawHeight = parameters.height;
    if (rotation == null || par == null || !par.isFinite || par <= 0) {
      return unknown(OutputPreparationEvidence.invalidDemuxGeometry);
    }
    final int? width;
    final int? height;
    if (displayWidth != null &&
        displayHeight != null &&
        displayWidth > 0 &&
        displayHeight > 0) {
      final normalizedRotation = rotation % 360;
      if (normalizedRotation == 90 || normalizedRotation == 270) {
        width = displayHeight;
        height = displayWidth;
      } else if (normalizedRotation == 0 || normalizedRotation == 180) {
        width = displayWidth;
        height = displayHeight;
      } else {
        return unknown(OutputPreparationEvidence.invalidDemuxGeometry);
      }
    } else if (par == 1.0 &&
        rotation % 360 == 0 &&
        rawWidth != null &&
        rawHeight != null) {
      width = rawWidth;
      height = rawHeight;
    } else {
      return unknown(OutputPreparationEvidence.invalidDemuxGeometry);
    }
    if (width < 1 || height < 1) {
      return unknown(OutputPreparationEvidence.invalidDemuxGeometry);
    }

    try {
      final response = await _channel.invokeMapMethod<Object?, Object?>(
        'VideoOutputManager.PrepareForLoad',
        {
          'handle': player.handle.toString(),
          'token': token.toPlatformArguments(),
          'trackId': trackId,
          'width': width,
          'height': height,
        },
      );
      if (_operationToken != token) {
        await invalidateOutputGeneration(token);
        return unknown(OutputPreparationEvidence.outputMutationUnconfirmed);
      }
      if (response?['accepted'] != true) {
        return unknown(OutputPreparationEvidence.outputMutationUnconfirmed);
      }
      final outputWidth = int.tryParse(response?['width'].toString() ?? '');
      final outputHeight = int.tryParse(response?['height'].toString() ?? '');
      if (outputWidth == null ||
          outputHeight == null ||
          outputWidth < 1 ||
          outputHeight < 1) {
        return unknown(OutputPreparationEvidence.outputMutationUnconfirmed);
      }
      return _outputResult(
        token,
        OutputPreparationStrategy.legacyAttached,
        OutputPreparationEvidence.loadedFileGeometry,
        geometry: VideoOutputGeometry(width: outputWidth, height: outputHeight),
      );
    } catch (_) {
      return unknown(OutputPreparationEvidence.outputMutationUnconfirmed);
    }
  }

  @override
  Future<OutputPreparationResult> waitForOutputAttach(
    OutputOperationToken token,
  ) {
    if (_lastOutputAttachToken == token && _lastOutputAttachResult != null) {
      return Future.value(_lastOutputAttachResult);
    }
    if (_disposeFuture != null || _operationToken != token) {
      return Future.value(unknownOutputResult(token));
    }
    return _outputAttachWaiters
        .putIfAbsent(token, () => Completer<OutputPreparationResult>())
        .future;
  }

  OutputPreparationResult unknownOutputResult(OutputOperationToken token) =>
      _outputResult(
        token,
        OutputPreparationStrategy.unknown,
        OutputPreparationEvidence.unknown,
      );

  @override
  Future<void> invalidateOutputGeneration(OutputOperationToken token) async {
    if (_operationToken == token) _operationToken = null;
    _completeOutputAttachUnknown(token);
    final acknowledged = await _channel.invokeMethod<bool>(
      'VideoOutputManager.InvalidateOutputGeneration',
      {
        'handle': player.handle.toString(),
        'token': token.toPlatformArguments(),
      },
    );
    if (acknowledged != true) {
      throw StateError('Native output did not acknowledge generation revoke');
    }
  }

  @override
  Future<void> releaseOutput() => _dispose();

  /// {@macro native_video_controller}
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
    final controller = NativeVideoController._(player, configuration);

    // Register [_dispose] for execution upon [Player.dispose].
    player.release.add(controller._dispose);

    // Store the [NativeVideoController] in the [_controllers].
    _controllers[handle] = controller;

    // ----------------------------------------------
    final values = {
      'vo': configuration.vo ?? 'libmpv',
      'hwdec': configuration.hwdec ?? 'auto',
      'vid': 'auto',
    };
    final mpv = NativePlayer.mpv;
    final ctx = player.ctx;
    for (final entry in values.entries) {
      final property = entry.key.toNativeUtf8();
      final value = entry.value.toNativeUtf8();
      mpv.mpv_set_property_string(ctx, property, value);
      calloc.free(property);
      calloc.free(value);
    }
    // ----------------------------------------------

    // Wait until first texture ID is received i.e. render context & EGL/D3D surface is created.
    // We are not waiting on the native-side itself because it will block the UI thread.
    // Background platform channels are not a thing yet.
    final completer = Completer<void>();
    void listener() {
      if (controller.id.value != null) {
        debugPrint('NativeVideoController: Texture ID: ${controller.id.value}');
        completer.complete();
      }
    }

    controller.id.addListener(listener);

    await _channel.invokeMethod('VideoOutputManager.Create', {
      'handle': handle.toString(),
      'configuration': {
        'width': configuration.width.toString(),
        'height': configuration.height.toString(),
        'enableHardwareAcceleration': configuration.enableHardwareAcceleration,
      },
    });

    await completer.future;
    controller.id.removeListener(listener);

    if (Platform.isWindows) {
      // 复用 mpv 已观察到的输出尺寸，避免渲染线程同步查询并等待 mpv 核心。
      controller._sourceSizeSubscription = player.stream.size.listen(
        controller._updateSourceSize,
      );
      controller._updateSourceSize((player.state.width, player.state.height));
    }

    // Return the [VideoController].
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
    if (this.width == width &&
        this.height == height &&
        (_sizeReady || _pendingSize != null)) {
      // A pending resize is not yet a first-frame acknowledgement.
      return _pendingSize;
    }
    final revision = ++_sizeRevision;
    final previousWidth = this.width;
    final previousHeight = this.height;
    this.width = width;
    this.height = height;
    _sizeReady = false;
    Future<void> submit() async {
      try {
        await _channel.invokeMethod<void>('VideoOutputManager.SetSize', {
          'handle': player.handle.toString(),
          'width': width.toString(),
          'height': height.toString(),
        });
        if (revision == _sizeRevision) _sizeReady = true;
      } catch (error, stack) {
        if (revision == _sizeRevision) {
          this.width = previousWidth;
          this.height = previousHeight;
          // Native geometry may already have changed. The restored values are
          // unknown, not applied: an old-size recovery must still be submitted.
          _sizeReady = false;
        }
        Error.throwWithStackTrace(error, stack);
      } finally {
        if (revision == _sizeRevision) _pendingSize = null;
      }
    }

    return _pendingSize = submit();
  }

  bool _sizeReady = true;

  @override
  Future<void> resetRenderer() async {
    if (!Platform.isWindows) return super.resetRenderer();
    await _channel.invokeMethod<void>('VideoOutputManager.ResetRenderer', {
      'handle': player.handle.toString(),
    });
  }

  int _sizeRevision = 0;
  Future<void>? _pendingSize;

  StreamSubscription<(int, int)>? _sourceSizeSubscription;

  void _updateSourceSize((int, int) size) {
    final (width, height) = size;
    if (width < 1 || height < 1) return;
    unawaited(
      _channel
          .invokeMethod<void>('VideoOutputManager.SetSourceSize', {
            'handle': player.handle.toString(),
            'width': width,
            'height': height,
            if (_operationToken case final token?)
              'token': token.toPlatformArguments(),
          })
          .catchError((Object error, StackTrace stack) {
            debugPrint(
              'NativeVideoController: source size update failed: $error',
            );
          }),
    );
  }

  /// Disposes the instance. Releases allocated resources back to the system.
  Future<void> _dispose() => _disposeFuture ??= _disposeInternal();

  Future<void> _disposeInternal() async {
    closeOutputProgress();
    final activeToken = _operationToken;
    _operationToken = null;
    if (activeToken != null) _completeOutputAttachUnknown(activeToken);
    for (final entry in _outputAttachWaiters.entries) {
      if (!entry.value.isCompleted) {
        entry.value.complete(
          _outputResult(
            entry.key,
            OutputPreparationStrategy.unknown,
            OutputPreparationEvidence.unknown,
          ),
        );
      }
    }
    _outputAttachWaiters.clear();
    await _sourceSizeSubscription?.cancel();
    final handle = player.handle;
    await _channel.invokeMethod<void>('VideoOutputManager.Dispose', {
      'handle': handle.toString(),
    });
    _controllers.remove(handle);
  }

  /// Currently created [NativeVideoController]s.
  /// This is used to notify about updated texture IDs & [Rect]s through [_channel].
  static final _controllers = HashMap<int, NativeVideoController>();

  /// [MethodChannel] for invoking platform specific native implementation.
  static final _channel =
      const MethodChannel('com.alexmercerind/media_kit_video')
        ..setMethodCallHandler((MethodCall call) {
          try {
            final Map args = call.arguments;
            debugPrint(call.method.toString());
            debugPrint(args.toString());
            switch (call.method) {
              case 'VideoOutput.Resize':
                {
                  // Notify about updated texture ID & [Rect].
                  final int handle = args['handle'];
                  final Map rectArgs = args['rect'];
                  final Rect rect = Rect.fromLTWH(
                    (rectArgs['left'] as num).toDouble(),
                    (rectArgs['top'] as num).toDouble(),
                    (rectArgs['width'] as num).toDouble(),
                    (rectArgs['height'] as num).toDouble(),
                  );
                  final int id = args['id'];
                  _controllers[handle]?.rect.value = rect;
                  _controllers[handle]?.id.value = id;
                  // Notify about the first frame being rendered.
                  if (rect.width > 0 && rect.height > 0) {
                    final completer = _controllers[handle]
                        ?.waitUntilFirstFrameRenderedCompleter;
                    if (!(completer?.isCompleted ?? true)) {
                      completer?.complete();
                    }
                  }
                  break;
                }
              case 'VideoOutput.Attach':
                {
                  final int handle = args['handle'];
                  final controller = _controllers[handle];
                  final token = OutputOperationToken.fromPlatformArguments(
                    Map<Object?, Object?>.from(args['token'] as Map),
                  );
                  final id = args['id'] as int;
                  final rectArgs = Map<Object?, Object?>.from(
                    args['rect'] as Map,
                  );
                  final width = (rectArgs['width'] as num).toInt();
                  final height = (rectArgs['height'] as num).toInt();
                  if (controller != null &&
                      controller._operationToken == token &&
                      width > 0 &&
                      height > 0) {
                    controller.id.value = id;
                    controller.rect.value = Rect.fromLTWH(
                      0,
                      0,
                      width.toDouble(),
                      height.toDouble(),
                    );
                    controller._completeOutputAttach(
                      token,
                      controller._outputResult(
                        token,
                        OutputPreparationStrategy.legacyAttached,
                        OutputPreparationEvidence.nativeTextureAttachReceipt,
                        geometry: VideoOutputGeometry(
                          width: width,
                          height: height,
                        ),
                      ),
                    );
                    final completer =
                        controller.waitUntilFirstFrameRenderedCompleter;
                    if (!completer.isCompleted) completer.complete();
                  }
                  break;
                }
              case 'VideoOutput.Progress':
                {
                  final int handle = args['handle'];
                  final controller = _controllers[handle];
                  final token = OutputOperationToken.fromPlatformArguments(
                    Map<Object?, Object?>.from(args['token'] as Map),
                  );
                  if (controller != null &&
                      controller._disposeFuture == null &&
                      controller._operationToken == token) {
                    controller.emitOutputProgress(
                      VideoOutputProgress(
                        token: token,
                        consumedAtMonotonicUs: List<int>.from(
                          args['consumedAtMonotonicUs'] as List,
                        ),
                      ),
                    );
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
          return Future.value();
        });
}
