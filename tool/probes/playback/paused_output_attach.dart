import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// Checks the load/output protocol while the player remains paused.
///
/// The probe deliberately does not initialize application services or call
/// play(). Point it at a local video file with PAUSED_OUTPUT_MEDIA.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!Platform.isWindows && !Platform.isAndroid) {
    throw UnsupportedError('Paused output probe supports Windows and Android');
  }
  const source = String.fromEnvironment('PAUSED_OUTPUT_MEDIA');
  if (source.isEmpty) {
    throw ArgumentError('Set PAUSED_OUTPUT_MEDIA to a local video URI/path');
  }
  const reportPath = String.fromEnvironment('PAUSED_OUTPUT_REPORT');
  final report = File(
    reportPath.isEmpty
        ? 'build/player-refactor-validation/paused-output-${Platform.operatingSystem}.json'
        : reportPath,
  );
  await report.parent.create(recursive: true);

  MediaKit.ensureInitialized();
  runApp(const MaterialApp(home: ColoredBox(color: Colors.black)));

  Player? player;
  PlatformVideoController? video;
  NativeHookRegistration? hookRegistration;
  StreamSubscription<NativePlayerEvent>? eventSubscription;
  var failed = false;
  var operationStage = 'createPlayer';
  var hookStage = 'notInvoked';
  final observedHooks = <String>[];
  final nativeLifecycleEvents = <Map<String, Object?>>[];
  final geometryByEntryId = <int, NativeVideoOutputParameters>{};
  final geometryWaiters = <int, Completer<NativeVideoOutputParameters>>{};
  final result = <String, Object?>{
    'platform': Platform.operatingSystem,
    'playCalls': 0,
    'sourcePathRecorded': false,
  };

  bool hasUsableGeometry(NativeVideoOutputParameters? parameters) {
    if (parameters == null ||
        parameters.rotation == null ||
        parameters.pixelAspectRatio == null ||
        !parameters.pixelAspectRatio!.isFinite ||
        parameters.pixelAspectRatio! <= 0) {
      return false;
    }
    final rotation = parameters.rotation! % 360;
    if (parameters.displayWidth != null &&
        parameters.displayHeight != null &&
        parameters.displayWidth! > 0 &&
        parameters.displayHeight! > 0) {
      return rotation == 0 ||
          rotation == 90 ||
          rotation == 180 ||
          rotation == 270;
    }
    return parameters.pixelAspectRatio == 1.0 &&
        rotation == 0 &&
        parameters.width != null &&
        parameters.height != null &&
        parameters.width! > 0 &&
        parameters.height! > 0;
  }

  try {
    operationStage = 'createPlayer';
    player = await Player.create(
      configuration: const PlayerConfiguration(
        logLevel: .error,
        options: {'ao': 'null'},
      ),
    );
    operationStage = 'createVideoController';
    video = await VideoController.create(
      player,
      configuration: VideoControllerConfiguration(
        hwdec: Platform.isWindows ? 'd3d11va' : 'auto-safe',
      ),
    );
    result['preloadedHookSupported'] = player.supportsPreloadedHook;

    runApp(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 640,
              height: 360,
              child: SimpleVideo(controller: video),
            ),
          ),
        ),
      ),
    );
    await WidgetsBinding.instance.endOfFrame;

    const token = OutputOperationToken(
      runtimeId: 1,
      loadId: 1,
      outputEpoch: 1,
      configRevision: 0,
    );
    operationStage = 'beginOutputForLoad';
    await video.beginOutputForLoad(token).timeout(const Duration(seconds: 10));

    final loaded = Completer<NativeFileLoaded>();
    int? latestStartFileId;
    eventSubscription = player.nativeEvents.listen((event) {
      if (event is NativeStartFile) {
        latestStartFileId = event.playlistEntryId;
        nativeLifecycleEvents.add({
          'type': 'startFile',
          'playlistEntryId': event.playlistEntryId,
        });
      } else if (event is NativeFileLoaded) {
        nativeLifecycleEvents.add({
          'type': 'fileLoaded',
          'playlistEntryId': event.playlistEntryId,
        });
        if (event.playlistEntryId != null &&
            event.playlistEntryId == latestStartFileId &&
            !loaded.isCompleted) {
          loaded.complete(event);
        }
      } else if (event is NativeVideoOutputParametersChanged) {
        final parameters = event.videoOutputParameters;
        nativeLifecycleEvents.add({
          'type': 'videoOutputParametersChanged',
          'playlistEntryId': event.playlistEntryId,
          'geometryKnown': parameters != null,
          'width': parameters?.width,
          'height': parameters?.height,
        });
        final entryId = event.playlistEntryId;
        if (entryId != null && hasUsableGeometry(parameters)) {
          geometryByEntryId[entryId] = parameters!;
          final waiter = geometryWaiters[entryId];
          if (waiter != null && !waiter.isCompleted) {
            waiter.complete(parameters);
          }
        }
      } else if (event is NativeEndFile) {
        nativeLifecycleEvents.add({
          'type': 'endFile',
          'playlistEntryId': event.playlistEntryId,
          'reason': event.reason.name,
        });
      } else if (event is NativeTracksChanged) {
        nativeLifecycleEvents.add({
          'type': 'tracksChanged',
          'playlistEntryId': event.playlistEntryId,
        });
      } else if (event is NativeEventBatchDrained) {
        nativeLifecycleEvents.add({
          'type': 'batchDrained',
          'batchId': event.batchId,
        });
      } else if (event is NativeEventQueueOverflow) {
        nativeLifecycleEvents.add({'type': 'queueOverflow'});
      }
    });

    OutputLoadSelectionResult? selection;
    hookRegistration = player.registerLifecycleHookHandler((
      request,
      api,
    ) async {
      observedHooks.add(request.name.name);
      if (request.name != NativeHookName.onPreloaded) return;

      hookStage = 'readVideoTracks';
      final tracks = api.readVideoTracks();
      final selected = tracks.where((track) => track.selected == true).toList();
      final NativeVideoTrackMetadata? candidate;
      if (tracks.length == 1) {
        candidate = tracks.single;
      } else if (selected.length == 1) {
        candidate = selected.single;
      } else {
        candidate = null;
      }
      result.addAll({
        'preloadedVideoTrackCount': tracks.length,
        'preloadedSelectedVideoTrackCount': selected.length,
        'preloadedCandidatePresent': candidate != null,
        'preloadedCandidateSelected': candidate?.selected,
        'preloadedCandidateGeometryKnown':
            candidate?.demuxWidth != null && candidate?.demuxHeight != null,
      });
      hookStage = 'prepareForLoad';
      selection = await video!.prepareForLoad(
        token,
        OutputPreparationRequest(
          allowedTrackId: candidate?.id.isNotEmpty == true
              ? candidate!.id
              : null,
          cropKnownNone: candidate?.demuxCropKnownNone == true,
          nativeApi: api,
          sourceWidth: candidate?.demuxWidth,
          sourceHeight: candidate?.demuxHeight,
          pixelAspectRatio: candidate?.demuxPar,
          rotation: candidate?.demuxRotate,
        ),
      );
      result['preloadedSelection'] = selection!.strategy.name;
      result['preloadedEvidence'] = selection!.evidence.name;
      hookStage = 'completed';
    });

    operationStage = 'openPaused';
    await player
        .open(const Media(source), play: false)
        .timeout(const Duration(seconds: 30));
    operationStage = 'awaitMatchingFileLoaded';
    final fileLoaded = await loaded.future.timeout(const Duration(seconds: 20));
    operationStage = 'confirmFileLoaded';
    final tracks = fileLoaded.videoTracks;
    final selected = tracks
        ?.where((track) => track.selected == true)
        .toList(growable: false);
    final allowedTrackId =
        selection?.trackId ??
        (selected?.length == 1 ? selected!.single.id : null) ??
        (tracks?.length == 1 ? tracks!.single.id : null);
    var outputParameters = fileLoaded.videoOutputParameters;
    var outputGeometrySource = 'fileLoaded';
    if (!hasUsableGeometry(outputParameters)) {
      final entryId = fileLoaded.playlistEntryId!;
      outputParameters = geometryByEntryId[entryId];
      outputGeometrySource = 'videoOutParamsChange';
      if (!hasUsableGeometry(outputParameters)) {
        operationStage = 'awaitMatchingOutputGeometry';
        final waiter = geometryWaiters.putIfAbsent(
          entryId,
          Completer<NativeVideoOutputParameters>.new,
        );
        outputParameters = await waiter.future.timeout(
          const Duration(seconds: 20),
        );
      }
    }
    result.addAll({
      'fileLoadedEntryId': fileLoaded.playlistEntryId,
      'fileLoadedTrackSnapshotKnown': tracks != null,
      'videoTrackCount': tracks?.length,
      'selectedVideoTrackCount': tracks
          ?.where((track) => track.selected == true)
          .length,
      'fileLoadedGeometryKnown': fileLoaded.videoOutputParameters != null,
      'fileLoadedGeometry': fileLoaded.videoOutputParameters == null
          ? null
          : {
              'width': fileLoaded.videoOutputParameters!.width,
              'height': fileLoaded.videoOutputParameters!.height,
              'displayWidth': fileLoaded.videoOutputParameters!.displayWidth,
              'displayHeight': fileLoaded.videoOutputParameters!.displayHeight,
              'rotation': fileLoaded.videoOutputParameters!.rotation,
            },
      'allowedTrackIdPresent': allowedTrackId != null,
      'confirmationGeometrySource': outputGeometrySource,
      'geometryChangeEntryId': fileLoaded.playlistEntryId,
      'confirmationGeometryUsable': hasUsableGeometry(outputParameters),
    });
    operationStage = 'confirmFileLoaded';
    final confirmed = await video
        .confirmFileLoaded(
          token,
          outputParameters,
          videoTracks: tracks,
          allowedTrackId: allowedTrackId,
        )
        .timeout(const Duration(seconds: 20));
    result.addAll({
      'confirmedStrategy': confirmed.strategy.name,
      'confirmedEvidence': confirmed.evidence.name,
      'textureIdPresentBeforeAttach': video.id.value != null,
    });
    OutputPreparationResult? attached;
    if (confirmed.strategy == OutputPreparationStrategy.prepared ||
        confirmed.strategy == OutputPreparationStrategy.legacyAttached) {
      operationStage = 'waitForOutputAttach';
      attached = await video
          .waitForOutputAttach(token)
          .timeout(const Duration(seconds: 20));
    }

    await Future<void>.delayed(const Duration(milliseconds: 500));
    final stillPaused = !player.state.playing;
    final videoTrackCount = tracks?.length;
    final hasVideo = videoTrackCount != null && videoTrackCount > 0;
    final attachConfirmed =
        attached != null &&
        (attached.strategy == OutputPreparationStrategy.prepared ||
            attached.strategy == OutputPreparationStrategy.legacyAttached);
    result.addAll({
      'playlistEntryIdPresent': fileLoaded.playlistEntryId != null,
      'fileLoadedTrackSnapshotKnown': tracks != null,
      'videoTrackCount': videoTrackCount,
      'fileLoadedGeometryKnown': fileLoaded.videoOutputParameters != null,
      'confirmedStrategy': confirmed.strategy.name,
      'confirmedEvidence': confirmed.evidence.name,
      'attachWaitSkipped': attached == null,
      'attachStrategy': attached?.strategy.name ?? 'notAttempted',
      'attachEvidence': attached?.evidence.name,
      'attachGeometry': attached?.geometry == null
          ? null
          : {
              'width': attached!.geometry!.width,
              'height': attached.geometry!.height,
            },
      'textureIdPresent': video.id.value != null,
      'pausedAfterAttach': stillPaused,
      'passed':
          fileLoaded.playlistEntryId != null &&
          hasVideo &&
          attachConfirmed &&
          stillPaused,
    });
    failed = result['passed'] != true;
  } catch (error) {
    result['failureStage'] = operationStage;
    result['hookStage'] = hookStage;
    result['observedHooks'] = observedHooks;
    result['nativeLifecycleEvents'] = nativeLifecycleEvents;
    result['textureIdPresentAtFailure'] = video?.id.value != null;
    result['textureSizeAtFailure'] = video == null
        ? null
        : {
            'width': video.rect.value?.width,
            'height': video.rect.value?.height,
          };
    result['errorType'] = error.runtimeType.toString();
    result['passed'] = false;
    failed = true;
  } finally {
    await report.writeAsString(
      const JsonEncoder.withIndent('  ').convert(result),
    );
    await eventSubscription?.cancel();
    await hookRegistration?.dispose();
    if (player != null) {
      await player.dispose();
    } else if (video != null) {
      await video.releaseOutput();
    }
  }

  exit(failed ? 1 : 0);
}
