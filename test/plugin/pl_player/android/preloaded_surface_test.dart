import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:media_kit_video/src/video_controller/android_video_controller/real.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.alexmercerind/media_kit_video');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const token = OutputOperationToken(
    runtimeId: 1,
    loadId: 1,
    outputEpoch: 1,
    configRevision: 0,
  );
  late _Player player;
  late PlatformVideoController controller;
  late List<MethodCall> calls;

  setUp(() async {
    player = _Player();
    calls = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        'VideoOutputManager.Create' => {'id': 7},
        'VideoOutputManager.CreateSurface' => {'wid': 123},
        'VideoOutputManager.SetFrameSampling' => {
          'token': token.toPlatformArguments(),
          'samplingGeneration': 100,
          'admission': 'blocked',
          'validAfterUs': 5000,
        },
        'VideoOutputManager.BeginOutputOperation' ||
        'VideoOutputManager.InvalidateOutputGeneration' => true,
        _ => null,
      };
    });
    controller = await AndroidVideoController.create(
      player,
      const VideoControllerConfiguration(
        androidAttachSurfaceAfterVideoParameters: false,
      ),
    );
    await controller.beginOutputForLoad(token);
    for (final hook in player.onLoadHooks) {
      await hook();
    }
    player.options.clear();
    calls.clear();
  });
  tearDown(() async {
    await controller.releaseOutput();
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('平台通道隔离旧 token、旧代次和同输出倒序批次', () async {
    final received = <VideoFrameEvent>[];
    final subscription = controller.frameEvents.listen(received.add);
    addTearDown(subscription.cancel);
    Future<void> emit(Map<String, Object> data) async {
      final completed = Completer<void>();
      ServicesBinding.instance.channelBuffers.push(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(
          MethodCall('VideoOutput.FrameSampling', {
            'handle': player.handle,
            'token': token.toPlatformArguments(),
            ...data,
          }),
        ),
        (_) => completed.complete(),
      );
      await completed.future;
    }

    await emit({
      'samplingGeneration': 1,
      'admission': 'active',
      'validAfterUs': 0,
    });
    await emit({
      'samplingGeneration': 1,
      'kind': 'refreshRequested',
      'sequence': 10,
      'monotonicUs': [1000],
    });
    await emit({
      'samplingGeneration': 2,
      'admission': 'blocked',
      'validAfterUs': 2000,
    });
    await emit({
      'samplingGeneration': 3,
      'admission': 'active',
      'validAfterUs': 3000,
    });
    await emit({
      'samplingGeneration': 1,
      'kind': 'refreshRequested',
      'sequence': 11,
      'monotonicUs': [4000],
    });
    await emit({
      'samplingGeneration': 3,
      'kind': 'refreshRequested',
      'sequence': 10,
      'monotonicUs': [4000],
    });
    await emit({
      'samplingGeneration': 3,
      'kind': 'refreshRequested',
      'sequence': 12,
      'monotonicUs': [4000],
    });
    expect(received.whereType<VideoFrameBatch>().map((b) => b.sequence), [
      10,
      12,
    ]);
    final receipt = await controller.setVideoFrameSampling(token, false);
    expect(receipt!.output, token);
    expect(receipt.samplingGeneration, 100);
    expect(receipt.admission, VideoFrameSamplingAdmission.blocked);
    await controller.invalidateOutputGeneration(token);
    await emit({
      'samplingGeneration': 4,
      'admission': 'active',
      'validAfterUs': 5000,
    });
    expect(received, hasLength(5));
  });

  for (final selectedBeforeDecode in [false, true]) {
    for (final displayWidth in [1920, 1440]) {
      test(
        'preloaded selected=$selectedBeforeDecode，直播加载后确认显示宽度 $displayWidth',
        () async {
          final api = _HookApi([_track(selected: selectedBeforeDecode)]);
          final selected = await controller.prepareForLoad(
            token,
            OutputPreparationRequest(
              allowedTrackId: '1',
              cropKnownNone: false,
              nativeApi: api,
            ),
          );
          expect(selected.strategy, OutputLoadSelectionStrategy.selectedVideo);
          expect(
            selected.evidence,
            isNot(OutputLoadSelectionEvidence.preloadedSurfaceConfigured),
          );
          expect(api.options, [
            if (!selectedBeforeDecode) ('vid', '1'),
            ('android-surface-size', '1920x1080'),
            ('wid', '123'),
            ('vo', 'gpu'),
          ]);
          final confirmed = await controller.confirmFileLoaded(
            token,
            NativeVideoOutputParameters(
              width: 1920,
              height: 1080,
              displayWidth: displayWidth,
              displayHeight: 1080,
              pixelAspectRatio: 1,
              rotation: 0,
            ),
            videoTracks: [_track()],
            allowedTrackId: '1',
          );
          expect(confirmed.strategy, OutputPreparationStrategy.legacyAttached);
          expect(confirmed.geometry?.width, displayWidth);
          expect(player.options.where((option) => option.$1 == 'vo'), isEmpty);
          expect(
            calls.where(
              (call) =>
                  call.method == 'VideoOutputManager.SetSurfaceTextureSize',
            ),
            hasLength(displayWidth == 1920 ? 1 : 2),
          );
          if (displayWidth != 1920) {
            expect(player.options, [
              ('android-surface-size', '${displayWidth}x1080'),
            ]);
          }
        },
      );
    }
  }

  test('FILE_LOADED 仍须确认实际选轨', () async {
    await controller.prepareForLoad(
      token,
      OutputPreparationRequest(
        allowedTrackId: '1',
        cropKnownNone: false,
        nativeApi: _HookApi([_track(selected: false)]),
      ),
    );
    final result = await controller.confirmFileLoaded(
      token,
      const NativeVideoOutputParameters(
        width: 1920,
        height: 1080,
        displayWidth: 1920,
        displayHeight: 1080,
        pixelAspectRatio: 1,
        rotation: 0,
      ),
      videoTracks: [_track(selected: false)],
      allowedTrackId: '1',
    );
    expect(result.strategy, OutputPreparationStrategy.unknown);
    expect(
      result.evidence,
      OutputPreparationEvidence.trackSelectionUnconfirmed,
    );
  });

  test('释放前同步解除 VO 和 wid，等待原生释放回执', () async {
    final release = Completer<void>();
    var nativeReleases = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'VideoOutputManager.Dispose') {
        nativeReleases++;
        expect(player.options, [('vo', 'null'), ('wid', '0')]);
        await release.future;
      }
      return null;
    });
    var completed = false;
    final disposal = controller.releaseOutput().then((_) => completed = true);
    final repeated = controller.releaseOutput();
    await Future<void>.delayed(Duration.zero);
    expect(nativeReleases, 1);
    expect(completed, isFalse);
    release.complete();
    await Future.wait([disposal, repeated]);
    expect(completed, isTrue);
  });

  test('已确认无视频轨的媒体不挂载 Surface', () async {
    final api = _HookApi(const []);
    final selection = await controller.prepareForLoad(
      token,
      OutputPreparationRequest(
        allowedTrackId: null,
        cropKnownNone: false,
        nativeApi: api,
      ),
    );
    expect(selection.strategy, OutputLoadSelectionStrategy.noVideo);
    expect(api.options, isEmpty);
    expect(calls, isEmpty);
  });
}

NativeVideoTrackMetadata _track({bool selected = true}) =>
    NativeVideoTrackMetadata(
      id: '1',
      type: 'video',
      demuxWidth: 1920,
      demuxHeight: 1080,
      demuxFps: 60,
      demuxPar: null,
      demuxRotate: null,
      demuxCropKnownNone: null,
      selected: selected,
    );

class _HookApi implements NativeHookApi {
  _HookApi(this.tracks);
  final List<NativeVideoTrackMetadata> tracks;
  final options = <(String, String)>[];
  @override
  bool get isValid => true;
  @override
  List<NativeVideoTrackMetadata> readVideoTracks() => tracks;
  @override
  void setOption(String name, String value) => options.add((name, value));
}

class _Player implements NativePlayer {
  @override
  final List<Media> current = [const Media('https://example.test/live.flv')];
  @override
  bool get disposed => false;
  @override
  int get handle => 42;
  @override
  bool get supportsPreloadedHook => true;
  @override
  final release = <Future<void> Function()>[];
  @override
  final onLoadHooks = <FutureOr<void> Function()>[];
  @override
  final onUnloadHooks = <FutureOr<void> Function()>[];
  @override
  final PlayerStream stream = _Stream();
  final options = <(String, String)>[];
  @override
  void setProperty(String property, String value) {}
  @override
  void setOption(String name, String value) => options.add((name, value));
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Stream implements PlayerStream {
  @override
  Stream<VideoParams> get videoParams => const Stream.empty();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
