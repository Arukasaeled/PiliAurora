import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/plugin/pl_player/playback/video_frame_timings.dart';

void main() {
  test('Android 请求与消费交错时只把请求批次送入弹幕相位学习', () {
    final timings = PlaybackVideoFrameTimings(useRequestTimings: true);
    addTearDown(timings.dispose);
    final published = <List<int>>[];
    timings.frames.addListener(() => published.add(timings.frames.value));
    final requested = List.generate(15, (index) => 1000 + index * 16667);
    final consumed = requested.map((stamp) => stamp + 5000).toList();
    timings.recordRequests(requested);
    expect(timings.presented.value, isFalse);
    expect(timings.recordConsumed(consumed), isTrue);
    expect(timings.presented.value, isTrue);
    expect(published, [requested]);
    expect(timings.diagnostics(300000), containsPair('nativeFrameSamples', 15));
    expect(
      timings.diagnostics(300000),
      containsPair('consumedFrameSamples', 15),
    );
  });

  test('刷新请求时间较新时仍接受有效消费证据，拒绝重复消费', () {
    final timings = PlaybackVideoFrameTimings(useRequestTimings: true);
    addTearDown(timings.dispose);
    timings.recordRequests([1000, 2000, 3000]);
    expect(timings.recordConsumed([1500, 2500]), isTrue);
    expect(timings.recordConsumed([1500, 2500]), isFalse);
    expect(timings.frames.value, [1000, 2000, 3000]);
  });

  test('加载新媒体重新等待首帧，清空相位仍保留已出画事实', () {
    final timings = PlaybackVideoFrameTimings(useRequestTimings: true);
    addTearDown(timings.dispose);
    timings
      ..recordConsumed([1000])
      ..clearPhase();
    expect(timings.presented.value, isTrue);
    timings.beginLoad();
    expect(timings.presented.value, isFalse);
    timings.recordRequests([2000]);
    expect(timings.presented.value, isFalse);
    timings.recordConsumed([2500]);
    expect(timings.presented.value, isTrue);
  });

  test('Windows 沿用消费批次作为调度时钟', () {
    final timings = PlaybackVideoFrameTimings(useRequestTimings: false);
    addTearDown(timings.dispose);
    timings.recordRequests([1000]);
    expect(timings.frames.value, isEmpty);
    timings.recordConsumed([1500, 2500]);
    expect(timings.frames.value, [1500, 2500]);
    expect(timings.presented.value, isTrue);
  });
}
