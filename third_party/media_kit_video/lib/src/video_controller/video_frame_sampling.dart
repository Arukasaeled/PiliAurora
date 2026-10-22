import 'package:media_kit_video/src/video_controller/output_operation.dart';

enum VideoFrameSampleKind { refreshRequested, textureConsumed }

enum VideoFrameSamplingAdmission { blocked, priming, active }

sealed class VideoFrameEvent {
  const VideoFrameEvent(this.output, this.samplingGeneration);

  final OutputOperationToken output;
  final int samplingGeneration;

  static VideoFrameEvent fromPlatformArguments(Map args) {
    final output = OutputOperationToken.fromPlatformArguments(
      Map<Object?, Object?>.from(args['token'] as Map),
    );
    final generation = args['samplingGeneration'] as int;
    if (args['admission'] case final String admission) {
      return VideoFrameSamplingState(
        output: output,
        samplingGeneration: generation,
        admission: VideoFrameSamplingAdmission.values.byName(admission),
        validAfterUs: args['validAfterUs'] as int,
      );
    }
    return VideoFrameBatch(
      output: output,
      samplingGeneration: generation,
      kind: VideoFrameSampleKind.values.byName(args['kind'] as String),
      sequence: args['sequence'] as int,
      monotonicUs: List<int>.from(args['monotonicUs'] as List),
    );
  }
}

final class VideoFrameBatch extends VideoFrameEvent {
  VideoFrameBatch({
    required OutputOperationToken output,
    required int samplingGeneration,
    required this.kind,
    required this.sequence,
    required List<int> monotonicUs,
  }) : monotonicUs = List.unmodifiable(monotonicUs),
       super(output, samplingGeneration);

  final VideoFrameSampleKind kind;
  final int sequence;
  final List<int> monotonicUs;
}

final class VideoFrameSamplingState extends VideoFrameEvent {
  const VideoFrameSamplingState({
    required OutputOperationToken output,
    required int samplingGeneration,
    required this.admission,
    required this.validAfterUs,
  }) : super(output, samplingGeneration);

  final VideoFrameSamplingAdmission admission;
  final int validAfterUs;
}

/// 每个消费者独立维护高水位；同输出失效时保留序号。
class VideoFrameEventGate {
  OutputOperationToken? _output;
  VideoFrameSamplingState? _state;
  final _sequences = <VideoFrameSampleKind, int>{};

  void bind(OutputOperationToken? output) {
    if (_output == output) return;
    _output = output;
    _state = null;
    _sequences.clear();
  }

  bool accept(VideoFrameEvent event) {
    if (event.output != _output) return false;
    final state = _state;
    if (event is VideoFrameSamplingState) {
      if (state != null &&
          (event.samplingGeneration < state.samplingGeneration ||
              event.samplingGeneration == state.samplingGeneration &&
                  event.admission.index <= state.admission.index)) {
        return false;
      }
      _state = event;
      return true;
    }
    final batch = event as VideoFrameBatch;
    if (state?.admission != VideoFrameSamplingAdmission.active ||
        state?.samplingGeneration != batch.samplingGeneration ||
        batch.sequence <= (_sequences[batch.kind] ?? -1)) {
      return false;
    }
    _sequences[batch.kind] = batch.sequence;
    return true;
  }
}
