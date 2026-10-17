import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:pili_aurora/plugin/pl_player/playback/native_load_readiness.dart';
import 'package:pili_aurora/plugin/pl_player/playback/playback_contracts.dart';

void main() {
  test('输出就绪前 EOF 立即结算失败，迟到的输出不能覆盖终态', () async {
    final load = NativeLoadReadiness(outputEpoch: 3)
      ..hasVideo = true
      ..handleEnd(NativeEndFileReason.eof, 0);
    expect(load.result.isCompleted, isTrue);
    final result = await load.result.future;
    expect(result.loaded, isFalse);
    expect(result.failure?.category, PlaybackFailureCategory.source);
    load.fileLoaded = true;
    load.output.complete(
      const PlaybackOutputPreparation(
        strategy: PlaybackOutputStrategy.legacyAttached,
        evidence: 'late',
        outputEpoch: 3,
      ),
    );
    load.resultMaybeComplete();
    await Future<void>.delayed(Duration.zero);
    expect(await load.result.future, same(result));
  });

  test('原生 stop 不作为拉流失败；error 保留来源错误', () async {
    final load = NativeLoadReadiness(outputEpoch: 4)
      ..handleEnd(NativeEndFileReason.stop, 0);
    expect(load.result.isCompleted, isFalse);
    load.handleEnd(NativeEndFileReason.error, -13);
    expect((await load.result.future).failure?.cause, contains('-13'));
  });

  test('等待几何时收到断流，立即结束等待而非等总 deadline', () async {
    final load = NativeLoadReadiness(outputEpoch: 5)..fileLoaded = true;
    final geometry = load.waitForGeometry(
      const Duration(seconds: 30),
      live: true,
    );
    final failure = expectLater(geometry, throwsA(isA<PlaybackFailure>()));
    load.handleEnd(NativeEndFileReason.eof, 0);
    await failure.timeout(const Duration(milliseconds: 200));
  });

  testWidgets('直播无有效尺寸五秒后进入失败，点播保留请求预算', (tester) async {
    final live = NativeLoadReadiness(outputEpoch: 6)..fileLoaded = true;
    final liveResult = expectLater(
      live.waitForGeometry(const Duration(seconds: 30), live: true),
      throwsA(isA<PlaybackFailure>()),
    );
    final vod = NativeLoadReadiness(outputEpoch: 7)..fileLoaded = true;
    var vodComplete = false;
    final vodResult = vod
        .waitForGeometry(const Duration(seconds: 30), live: false)
        .then((_) => vodComplete = true);
    await tester.pump(const Duration(seconds: 5));
    await liveResult;
    expect(vodComplete, isFalse);
    vod.outputGeometry.complete(
      const NativeVideoOutputParameters(
        width: 1920,
        height: 1080,
        displayWidth: 1920,
        displayHeight: 1080,
        pixelAspectRatio: 1,
        rotation: 0,
      ),
    );
    await vodResult;
  });
}
