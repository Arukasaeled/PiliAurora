import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:pili_aurora/plugin/pl_player/playback/video_frame_timings.dart';

const output = OutputOperationToken(
  runtimeId: 1,
  loadId: 1,
  outputEpoch: 1,
  configRevision: 0,
);
VideoFrameSamplingState state(
  int generation,
  VideoFrameSamplingAdmission admission, [
  int after = 0,
]) => VideoFrameSamplingState(
  output: output,
  samplingGeneration: generation,
  admission: admission,
  validAfterUs: after,
);
VideoFrameBatch batch(
  int generation,
  int sequence,
  List<int> values, [
  VideoFrameSampleKind kind = VideoFrameSampleKind.refreshRequested,
]) => VideoFrameBatch(
  output: output,
  samplingGeneration: generation,
  kind: kind,
  sequence: sequence,
  monotonicUs: values,
);

void main() {
  PlaybackVideoFrameTimings create({bool android = true}) {
    final timings = PlaybackVideoFrameTimings(useRequestTimings: android);
    addTearDown(timings.dispose);
    timings
      ..beginLoad(output, 0)
      ..setEnabled(true, 0)
      ..accept(state(1, VideoFrameSamplingAdmission.active));
    return timings;
  }

  test('请求与消费证据分别更新，Android 相位保留请求阶段', () {
    final timings = create()..accept(batch(1, 1, [1000, 2000]));
    expect(timings.presented.value, isFalse);
    expect(timings.recordConsumed([1500, 2500]), isTrue);
    expect(timings.recordConsumed([1500, 2500]), isFalse);
    expect(timings.presented.value, isTrue);
    expect(timings.frameState.value.videoSamples!.monotonicUs, [1000, 2000]);
    timings.accept(batch(1, 1, [3000], VideoFrameSampleKind.textureConsumed));
    expect(
      timings.frameState.value.videoSamples!.kind,
      VideoFrameSampleKind.refreshRequested,
    );
  });

  test('同 token 多次重置保留高水位，旧代次和倒序批次不能回填', () {
    final timings = create()
      ..accept(batch(1, 10, [1000]))
      ..setEnabled(false, 1500)
      ..accept(batch(1, 11, [2000]));
    expect(timings.frameState.value.videoSamples, isNull);
    timings
      ..accept(state(2, VideoFrameSamplingAdmission.blocked))
      ..setEnabled(true, 2500)
      ..accept(state(3, VideoFrameSamplingAdmission.priming))
      ..accept(state(4, VideoFrameSamplingAdmission.active, 3000))
      ..accept(batch(1, 12, [4000]))
      ..accept(batch(4, 10, [4000]));
    expect(timings.frameState.value.videoSamples, isNull);
    timings.accept(batch(4, 12, [4000]));
    expect(timings.frameState.value.videoSamples!.sequence, 12);
    timings
      ..accept(state(3, VideoFrameSamplingAdmission.active))
      ..accept(batch(4, 12, [5000]))
      ..accept(batch(4, 11, [5000]));
    expect(timings.frameState.value.videoSamples!.monotonicUs, [4000]);
    timings
      ..accept(state(5, VideoFrameSamplingAdmission.blocked))
      ..accept(state(6, VideoFrameSamplingAdmission.priming))
      ..accept(state(7, VideoFrameSamplingAdmission.active))
      ..accept(batch(7, 13, [5000]));
    expect(timings.frameState.value.videoSamples!.sequence, 13);
  });

  test('过期批次也消费序号，条目有序有界且不可变', () {
    final timings = create()
      ..accept(state(2, VideoFrameSamplingAdmission.active, 1000))
      ..accept(batch(2, 20, [500]))
      ..accept(batch(2, 20, [2000]));
    expect(timings.frameState.value.videoSamples, isNull);
    timings.accept(batch(2, 21, List.generate(100, (i) => 2000 + (99 - i))));
    final values = timings.frameState.value.videoSamples!.monotonicUs;
    expect(values.length, 64);
    expect(values.first, 2036);
    expect(() => values.add(3000), throwsUnsupportedError);
  });

  test('同步状态重发沿用批次身份；新输出清除首帧与序号空间', () {
    final timings = create()
      ..accept(batch(1, 20, [1000]))
      ..recordConsumed([1500]);
    final samples = timings.frameState.value.videoSamples;
    timings.setDisplaySyncActive(true);
    expect(timings.frameState.value.videoSamples, same(samples));
    timings.invalidate(2000);
    expect(timings.presented.value, isTrue);
    const next = OutputOperationToken(
      runtimeId: 1,
      loadId: 2,
      outputEpoch: 2,
      configRevision: 0,
    );
    timings
      ..beginLoad(next, 3000)
      ..setEnabled(true, 3000)
      ..accept(state(100, VideoFrameSamplingAdmission.active))
      ..accept(batch(100, 100, [4000]));
    expect(timings.presented.value, isFalse);
    expect(timings.frameState.value.videoSamples, isNull);
    timings
      ..accept(
        const VideoFrameSamplingState(
          output: next,
          samplingGeneration: 1,
          admission: VideoFrameSamplingAdmission.active,
          validAfterUs: 3000,
        ),
      )
      ..accept(
        VideoFrameBatch(
          output: next,
          samplingGeneration: 1,
          kind: VideoFrameSampleKind.refreshRequested,
          sequence: 1,
          monotonicUs: [4000],
        ),
      );
    expect(timings.frameState.value.videoSamples!.sequence, 1);
  });

  test('采样开关等待当前回执，旧状态、批次和旧回执不能打开新窗口', () {
    final timings = create()..accept(batch(1, 10, [1000]));
    final close = timings.beginSamplingChange(false, 2000);
    final open = timings.beginSamplingChange(true, 3000);
    timings
      ..accept(state(2, VideoFrameSamplingAdmission.active, 4000))
      ..accept(batch(2, 11, [5000]))
      ..completeSamplingChange(
        close,
        state(3, VideoFrameSamplingAdmission.blocked, 4500),
      );
    expect(timings.frameState.value.videoSamples, isNull);
    expect(
      timings.frameState.value.admission,
      VideoFrameSamplingAdmission.blocked,
    );
    timings
      ..completeSamplingChange(
        open,
        state(4, VideoFrameSamplingAdmission.priming, 6000),
      )
      ..accept(state(5, VideoFrameSamplingAdmission.active, 7000))
      ..accept(batch(5, 12, [8000]));
    expect(timings.frameState.value.videoSamples!.sequence, 12);
    timings
      ..completeSamplingChange(
        close,
        state(100, VideoFrameSamplingAdmission.blocked),
      )
      ..accept(batch(2, 13, [9000]));
    expect(timings.frameState.value.videoSamples!.sequence, 12);
  });

  test('当前活动状态早于开关回执交付时，在回执确认后恢复', () {
    final timings = create();
    final revision = timings.beginSamplingChange(true, 3000);
    timings
      ..accept(state(5, VideoFrameSamplingAdmission.active, 7000))
      ..accept(batch(5, 10, [8000]));
    expect(timings.frameState.value.videoSamples, isNull);
    timings.completeSamplingChange(
      revision,
      state(4, VideoFrameSamplingAdmission.priming, 6000),
    );
    expect(
      timings.frameState.value.admission,
      VideoFrameSamplingAdmission.active,
    );
    timings.accept(batch(5, 11, [9000]));
    expect(timings.frameState.value.videoSamples!.sequence, 11);
  });

  test('Windows 相位观察值采用消费阶段，关闭期间保留消费证据', () {
    final timings = create(android: false)..accept(batch(1, 1, [1000]));
    expect(timings.frameState.value.videoSamples, isNull);
    timings.accept(batch(1, 1, [1500], VideoFrameSampleKind.textureConsumed));
    expect(timings.frameState.value.videoSamples!.monotonicUs, [1500]);
    timings
      ..setEnabled(false, 2000)
      ..recordConsumed([2500]);
    expect(timings.frameState.value.videoSamples, isNull);
    expect(timings.presented.value, isTrue);
  });
}
