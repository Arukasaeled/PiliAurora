import 'dart:async';

import 'package:media_kit/media_kit.dart';
import 'package:pili_aurora/plugin/pl_player/playback/playback_contracts.dart';

/// 每次加载的就绪与终态；原生文件归属由运行时核对后再交入。
class NativeLoadReadiness {
  NativeLoadReadiness({required this.outputEpoch});

  final int outputEpoch;
  final Completer<PlaybackOutputPreparation> output = Completer();
  final Completer<NativeVideoOutputParameters> outputGeometry = Completer();
  final Completer<PlaybackRuntimeLoadResult> result = Completer();
  bool fileLoaded = false;
  bool? hasVideo;

  void resultMaybeComplete() {
    if (result.isCompleted || !fileLoaded || !output.isCompleted) return;
    final prepared = output.future;
    unawaited(
      prepared.then(
        (value) {
          if (result.isCompleted) return;
          result.complete(
            PlaybackRuntimeLoadResult(
              loaded: true,
              output: value,
              failure: value.strategy == PlaybackOutputStrategy.unknown
                  ? PlaybackFailure(
                      category: PlaybackFailureCategory.output,
                      operation: 'prepare-output',
                      stage: PlaybackStage.outputPreparing,
                      recoverable: false,
                      cause: value.evidence,
                    )
                  : null,
            ),
          );
        },
        onError: (Object error, StackTrace stack) {
          if (!result.isCompleted) result.completeError(error, stack);
        },
      ),
    );
  }

  void failLoad(PlaybackFailure failure, String evidence) {
    if (result.isCompleted) return;
    result.complete(
      PlaybackRuntimeLoadResult(
        loaded: false,
        output: PlaybackOutputPreparation(
          strategy: PlaybackOutputStrategy.unknown,
          evidence: evidence,
          outputEpoch: outputEpoch,
          hasVideo: hasVideo,
        ),
        failure: failure,
      ),
    );
  }

  void handleEnd(NativeEndFileReason reason, int error) {
    if (reason != NativeEndFileReason.error &&
        reason != NativeEndFileReason.eof) {
      return;
    }
    failLoad(
      PlaybackFailure(
        category: PlaybackFailureCategory.source,
        operation: 'end-file',
        stage: PlaybackStage.opening,
        recoverable: true,
        cause: reason == NativeEndFileReason.eof
            ? 'Source ended before video output became ready.'
            : 'Native end-file error $error.',
      ),
      reason == NativeEndFileReason.eof
          ? 'native-eof-before-ready'
          : 'native-end-file-error',
    );
  }

  Future<NativeVideoOutputParameters> waitForGeometry(
    Duration remaining, {
    required bool live,
  }) {
    const liveGeometryBudget = Duration(seconds: 5);
    final budget = live && remaining > liveGeometryBudget
        ? liveGeometryBudget
        : remaining;
    // FILE_LOADED 后仍可能没有视频参数；终态与参数竞争，避免断流后继续空等。
    return Future.any([
      outputGeometry.future,
      result.future.then<NativeVideoOutputParameters>((value) {
        throw value.failure ??
            StateError('Load ended while awaiting geometry.');
      }),
    ]).timeout(
      budget,
      onTimeout: () {
        throw const PlaybackFailure(
          category: PlaybackFailureCategory.source,
          operation: 'video-output-geometry',
          stage: PlaybackStage.outputPreparing,
          recoverable: true,
          cause: 'Source did not provide valid video dimensions before the deadline.',
        );
      },
    );
  }
}
