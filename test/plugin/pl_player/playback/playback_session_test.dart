import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/plugin/pl_player/models/data_source.dart';
import 'package:pili_aurora/plugin/pl_player/playback/playback_contracts.dart';
import 'package:pili_aurora/plugin/pl_player/playback/playback_session.dart';

void main() {
  test('直播候选确认无视频轨后立即尝试下一源，保留请求和播放意图', () async {
    final runtime = _FakeRuntime();
    final session = PlaybackSession(runtime: runtime);
    final owner = session.attach();
    runtime.onLoad = (plan, context, index) async =>
        index == 0 ? _audioLoaded(context) : _loaded(context, plan);
    final result = await owner.load(
      _plan(
        'live',
        kind: PlaybackTimelineKind.live,
        candidates: [
          'https://example.test/audio.flv',
          'https://example.test/video.flv',
        ],
      ),
      start: PlaybackStartPolicy.play,
    );
    expect(result.outcome, LoadOutcome.ready);
    expect(runtime.loadedPlans.map((p) => p.source.videoIndex), [0, 1]);
    expect(runtime.playCalls, [true]);
    expect(session.currentSnapshot.requestId, 1);
    expect(session.currentSnapshot.loadId, 2);
    expect(session.currentPlan?.source.videoIndex, 1);
    owner.close();
    await runtime.released;
  });

  test('直播全部候选无视频轨时失败并停止重试', () async {
    final runtime = _FakeRuntime();
    final session = PlaybackSession(runtime: runtime);
    final owner = session.attach();
    runtime.onLoad = (plan, context, index) async => _audioLoaded(context);
    final result = await owner.load(
      _plan(
        'live',
        kind: PlaybackTimelineKind.live,
        candidates: [
          'https://example.test/one.flv',
          'https://example.test/two.flv',
        ],
      ),
    );
    expect(result.outcome, LoadOutcome.failed);
    expect(result.failure?.operation, 'validate-live-video');
    expect(runtime.loadedPlans, hasLength(2));
    expect(runtime.playCalls, isEmpty);
    owner.close();
    await runtime.released;
  });

  test('直播轮换候选期间的暂停与新媒体请求仍优先生效', () async {
    final runtime = _FakeRuntime();
    final session = PlaybackSession(runtime: runtime);
    final owner = session.attach();
    final secondStarted = Completer<void>();
    final secondFinished = Completer<void>();
    runtime.onLoad = (plan, context, index) async {
      if (index == 0) return _audioLoaded(context);
      if (index == 1) {
        secondStarted.complete();
        await secondFinished.future;
      }
      return _loaded(context, plan);
    };
    final live = owner.load(
      _plan(
        'live',
        kind: PlaybackTimelineKind.live,
        candidates: [
          'https://example.test/one.flv',
          'https://example.test/two.flv',
        ],
      ),
      start: PlaybackStartPolicy.play,
    );
    await secondStarted.future;
    await owner.setPlaying(false);
    final latest = owner.load(
      _plan('latest'),
      start: PlaybackStartPolicy.preserve,
    );
    expect((await live).outcome, LoadOutcome.superseded);
    secondFinished.complete();
    expect((await latest).outcome, LoadOutcome.ready);
    expect(session.currentPlan?.contentKey, 'latest');
    expect(runtime.playCalls, [false]);
    owner.close();
    await runtime.released;
  });

  for (final live in [false, true]) {
    test('允许${live ? '显式纯音频直播' : '纯音频点播'}的无视频输出', () async {
      final runtime = _FakeRuntime();
      final session = PlaybackSession(runtime: runtime);
      final owner = session.attach();
      runtime.onLoad = (plan, context, index) async => _audioLoaded(context);
      final result = await owner.load(
        _plan(
          'audio',
          kind: live
              ? PlaybackTimelineKind.live
              : PlaybackTimelineKind.onDemand,
          audioOnly: live,
        ),
      );
      expect(result.outcome, LoadOutcome.ready);
      expect(runtime.loadedPlans, hasLength(1));
      owner.close();
      await runtime.released;
    });
  }

  test('查询成功后业务回写仍属于当前媒体，下一次加载使其失效', () async {
    var now = Duration.zero;
    final runtime = _FakeRuntime();
    final session = PlaybackSession(runtime: runtime, monotonicNow: () => now);
    final owner = session.attach();
    late PlaybackQuery query;
    final loaded = await owner.query((accepted) async {
      query = accepted;
      return _plan('online-video');
    }, start: PlaybackStartPolicy.play);
    expect(loaded.outcome, LoadOutcome.ready);
    expect(query.isCurrent, isTrue, reason: '页面在 ready 后才挂载视频和字幕');
    now = const Duration(minutes: 1);
    expect(query.isCurrent, isTrue, reason: '成功加载后的回写不再受加载 deadline 限制');
    await owner.load(_plan('next-video'));
    expect(query.isCurrent, isFalse);
    late PlaybackQuery current;
    await owner.query((accepted) async {
      current = accepted;
      return _plan('next-video');
    });
    expect(current.isCurrent, isTrue);
    owner.invalidateRequests();
    expect(current.isCurrent, isFalse);
    owner.close();
    await session.shutdown();
  });

  test('新加载立即结算旧请求，但等旧原生调用排空后才执行新加载', () async {
    final runtime = _FakeRuntime();
    final session = PlaybackSession(runtime: runtime);
    final owner = session.attach();
    final oldOpen = Completer<void>();
    final oldStarted = Completer<void>();
    final calls = <String>[];
    runtime.onLoad = (plan, context, index) async {
      calls.add(plan.contentKey);
      if (index == 0) {
        oldStarted.complete();
        await oldOpen.future;
      }
      return _loaded(context, plan);
    };

    final old = owner.load(_plan('old'));
    await oldStarted.future;
    final latest = owner.load(_plan('latest'));
    expect((await old).outcome, LoadOutcome.superseded);
    expect(calls, ['old']);

    oldOpen.complete();
    expect((await latest).outcome, LoadOutcome.ready);
    expect(calls, ['old', 'latest']);

    owner.close();
    final shutdown = await session.shutdown();
    expect(shutdown.outcome, PlaybackShutdownOutcome.released);
    expect(session.currentSnapshot.phase, PlaybackPhase.disposed);
  });

  test('旧 play 写入返回后 writer 收敛到更新的 pause 意图', () async {
    final runtime = _FakeRuntime();
    final session = PlaybackSession(runtime: runtime);
    final owner = session.attach();
    expect((await owner.load(_plan('movie'))).outcome, LoadOutcome.ready);

    final oldPlay = Completer<PlaybackRuntimeCommandResult>();
    final playStarted = Completer<void>();
    runtime.onSetPlaying = (playing, context, index) {
      runtime.playCalls.add(playing);
      if (playing && index == 1) {
        playStarted.complete();
        return oldPlay.future;
      }
      return Future.value(const PlaybackRuntimeCommandResult());
    };

    final play = owner.setPlaying(true);
    await playStarted.future;
    final pause = owner.setPlaying(false);
    oldPlay.complete(const PlaybackRuntimeCommandResult());

    expect((await play).outcome, CommandOutcome.superseded);
    expect((await pause).outcome, CommandOutcome.applied);
    expect(runtime.playCalls, [false, true, false]);
    expect(session.currentSnapshot.intent.playing, isFalse);
    expect(session.currentSnapshot.actual.playing, isNull);

    owner.close();
    await runtime.released;
  });

  test('异步 query 被新请求取代后不能提交迟到计划', () async {
    final runtime = _FakeRuntime();
    final session = PlaybackSession(runtime: runtime);
    final owner = session.attach();
    final oldResolver = Completer<PlaybackPlan?>();
    final oldStarted = Completer<void>();
    runtime.onLoad = (plan, context, _) async => _loaded(context, plan);

    final old = owner.query((query) {
      oldStarted.complete();
      return oldResolver.future;
    });
    await oldStarted.future;
    final latest = owner.load(_plan('latest'));
    expect((await old).outcome, LoadOutcome.superseded);
    oldResolver.complete(_plan('late'));

    expect((await latest).outcome, LoadOutcome.ready);
    expect(runtime.loadedKeys, ['latest']);
    owner.close();
    await runtime.released;
  });

  test('owner返回后须提交自己的load才恢复旧播放意图', () async {
    final runtime = _FakeRuntime();
    final session = PlaybackSession(runtime: runtime);
    final previous = session.attach();
    expect((await previous.load(_plan('movie'))).outcome, LoadOutcome.ready);
    await previous.setPlaying(true);
    final routeToken = previous.acquireInhibitor(
      PlaybackInhibitorSource.system,
    );
    expect(routeToken, isNotNull);
    await _until(() => !runtime.playCalls.last);

    final next = session.attach();
    expect((await next.load(_plan('next'))).outcome, LoadOutcome.ready);
    await next.setPlaying(true);
    await _until(() => runtime.playCalls.last);

    next.close();
    await _until(() => !runtime.playCalls.last);
    expect(previous.isActive, isFalse);

    previous.activate();
    expect(previous.isActive, isTrue);
    await _until(() => !runtime.playCalls.last);
    expect(
      (await previous.releaseInhibitor(routeToken!)).outcome,
      CommandOutcome.applied,
    );
    expect(runtime.playCalls.last, isFalse);
    expect((await previous.setPlaying(true)).outcome, CommandOutcome.noMedia);
    expect((await previous.load(_plan('movie'))).outcome, LoadOutcome.ready);
    await _until(() => runtime.playCalls.last);

    previous.close();
    await runtime.released;
  });

  test('关闭inactive owner不影响当前活动owner的播放', () async {
    final runtime = _FakeRuntime();
    final session = PlaybackSession(runtime: runtime);
    final previous = session.attach();
    expect((await previous.load(_plan('movie'))).outcome, LoadOutcome.ready);
    await previous.setPlaying(true);

    final active = session.attach();
    expect((await active.load(_plan('next'))).outcome, LoadOutcome.ready);
    await active.setPlaying(true);
    await _until(() => runtime.playCalls.last);

    previous.close();
    expect(active.isActive, isTrue);
    expect(session.currentSnapshot.intent.playing, isTrue);
    expect(runtime.playCalls.last, isTrue);

    active.close();
    await runtime.released;
  });

  test('session audio focus抑制跨owner load并按新owner最新意图恢复', () async {
    final runtime = _FakeRuntime();
    final session = PlaybackSession(runtime: runtime);
    final previous = session.attach();
    expect((await previous.load(_plan('movie'))).outcome, LoadOutcome.ready);
    await previous.setPlaying(true);

    final focusToken = session.acquireSessionInhibitor(
      PlaybackInhibitorSource.audioFocus,
    );
    expect(focusToken, isNotNull);
    await _until(() => !runtime.playCalls.last);

    final active = session.attach();
    expect(
      (await active.load(
        _plan('next'),
        start: PlaybackStartPolicy.play,
      )).outcome,
      LoadOutcome.ready,
    );
    expect(active.isActive, isTrue);
    expect(session.currentSnapshot.intent.playing, isTrue);
    expect(runtime.playCalls.last, isFalse);

    expect((await active.setPlaying(false)).outcome, CommandOutcome.applied);
    expect(
      (await session.releaseSessionInhibitor(focusToken!)).outcome,
      CommandOutcome.applied,
    );
    expect(runtime.playCalls.last, isFalse);

    expect((await active.setPlaying(true)).outcome, CommandOutcome.applied);
    await _until(() => runtime.playCalls.last);

    active.close();
    previous.close();
    await runtime.released;
  });

  test('snapshot 新订阅即时给当前值，暂停期间只保留 latest', () async {
    final runtime = _FakeRuntime();
    final session = PlaybackSession(runtime: runtime);
    final owner = session.attach();
    final received = <PlaybackSnapshot>[];
    final firstSnapshot = Completer<void>();
    final subscription = owner.snapshots.listen((snapshot) {
      received.add(snapshot);
      if (!firstSnapshot.isCompleted) firstSnapshot.complete();
    });
    await firstSnapshot.future;
    expect(
      received.single.snapshotVersion,
      session.currentSnapshot.snapshotVersion,
    );

    subscription.pause();
    final tokens = <PlaybackInhibitorToken>[];
    for (var i = 0; i < 20; i++) {
      tokens.add(owner.acquireInhibitor(PlaybackInhibitorSource.system)!);
    }
    for (final token in tokens) {
      await owner.releaseInhibitor(token);
    }
    final versionBeforeResume = session.currentSnapshot.snapshotVersion;
    final countBeforeResume = received.length;
    subscription.resume();
    await _until(() => received.length > countBeforeResume);
    expect(received.length, countBeforeResume + 1);
    expect(received.last.snapshotVersion, versionBeforeResume);

    await subscription.cancel();
    owner.close();
    await runtime.released;
  });

  test('seek 受 timeline 与已知区间约束', () async {
    final runtime = _FakeRuntime();
    final session = PlaybackSession(runtime: runtime);
    final owner = session.attach();
    expect((await owner.load(_plan('movie'))).outcome, LoadOutcome.ready);

    expect(
      (await owner.seek(const Duration(seconds: -1))).outcome,
      CommandOutcome.outOfRange,
    );
    expect(
      (await owner.seek(const Duration(seconds: 11))).outcome,
      CommandOutcome.outOfRange,
    );
    expect(
      (await owner.seek(const Duration(seconds: 10))).outcome,
      CommandOutcome.applied,
    );
    expect(runtime.seekCalls, [const Duration(seconds: 10)]);

    owner.close();
    await runtime.released;
  });

  test('不可 seek 直播的 shader 重建走同一加载协议并保留 request 与播放意图', () async {
    final runtime = _FakeRuntime()..shaderChangeRequiresRendererReset = true;
    final session = PlaybackSession(
      runtime: runtime,
      commandBudget: Duration.zero,
    );
    final owner = session.attach();
    expect(
      (await owner.load(
        _plan(
          'live',
          kind: PlaybackTimelineKind.live,
          seekPolicy: PlaybackSeekPolicy.unknown,
        ),
        start: PlaybackStartPolicy.play,
      )).outcome,
      LoadOutcome.ready,
    );
    final requestId = session.requestId;
    final previousLoadId = session.loadId;

    expect(
      (await owner.setShader(['quality'])).outcome,
      CommandOutcome.applied,
    );
    expect(session.requestId, requestId);
    expect(session.loadId, previousLoadId + 1);
    expect(runtime.loadedPlans, hasLength(2));
    expect(runtime.loadedPlans.last.configuration.shaders, ['quality']);
    expect(runtime.loadedPlans.last.startPosition, isNull);
    expect(runtime.loadedPlans.last.reloadPosition, isNull);
    expect(runtime.shaderCalls, isEmpty);
    expect(session.currentSnapshot.intent.playing, isTrue);
    expect(runtime.playCalls, [true, true]);

    owner.close();
    await runtime.released;
  });

  test('不可 seek 直播的解码器和音频模式改动经加载协议应用', () async {
    final runtime = _FakeRuntime();
    final session = PlaybackSession(runtime: runtime);
    final owner = session.attach();
    expect(
      (await owner.load(
        _plan(
          'live',
          kind: PlaybackTimelineKind.live,
          seekPolicy: PlaybackSeekPolicy.unknown,
        ),
      )).outcome,
      LoadOutcome.ready,
    );

    expect(
      (await owner.setDecoder(const PlaybackDecoder('no'))).outcome,
      CommandOutcome.applied,
    );
    expect((await owner.setAudioOnly(true)).outcome, CommandOutcome.applied);
    expect(
      (await owner.setPlaybackSpeed(
        1.5,
        mediaOptions: const {'cache-secs': '5'},
      )).outcome,
      CommandOutcome.applied,
    );

    expect(runtime.loadedPlans, hasLength(3));
    expect(runtime.loadedPlans[1].configuration.hwdec, 'no');
    expect(runtime.loadedPlans[1].configuration.audioOnly, isFalse);
    expect(runtime.loadedPlans[2].configuration.hwdec, 'no');
    expect(runtime.loadedPlans[2].configuration.audioOnly, isTrue);
    expect(runtime.decoderCalls, isEmpty);
    expect(runtime.audioOnlyCalls, isEmpty);

    owner.close();
    await runtime.released;
  });

  test('可 seek 点播的 shader、解码器和音频模式原位更新', () async {
    final runtime = _FakeRuntime()..shaderChangeRequiresRendererReset = true;
    final session = PlaybackSession(runtime: runtime);
    final owner = session.attach();
    expect((await owner.load(_plan('movie'))).outcome, LoadOutcome.ready);

    expect(
      (await owner.setShader(['quality'])).outcome,
      CommandOutcome.applied,
    );
    expect(
      (await owner.setDecoder(const PlaybackDecoder('no'))).outcome,
      CommandOutcome.applied,
    );
    expect((await owner.setAudioOnly(true)).outcome, CommandOutcome.applied);

    expect(runtime.loadedPlans, hasLength(1));
    expect(runtime.shaderCalls, [
      ['quality'],
    ]);
    expect(runtime.decoderCalls, ['no']);
    expect(runtime.audioOnlyCalls, [true]);
    expect(
      (await owner.setPlaybackSpeed(
        1.5,
        mediaOptions: const {'cache-secs': '5'},
      )).outcome,
      CommandOutcome.applied,
    );
    expect(runtime.speedCalls.single.speed, 1.5);
    expect(runtime.speedCalls.single.mediaOptions, {'cache-secs': '5'});
    expect(session.currentSnapshot.configuration.applied.shaders, ['quality']);
    expect(
      session.currentSnapshot.configuration.applied.mediaOptions,
      {'cache-secs': '5'},
    );

    owner.close();
    await runtime.released;
  });

  test('暂停期间恢复延期，恢复用户播放意图后才提交加载', () async {
    var now = Duration.zero;
    final runtime = _FakeRuntime();
    final session = PlaybackSession(
      runtime: runtime,
      monotonicNow: () => now,
    );
    final owner = session.attach();
    final plan = _plan('movie');
    expect((await owner.load(plan)).outcome, LoadOutcome.ready);

    expect((await owner.recover(plan)).outcome, LoadOutcome.deferred);
    expect(runtime.loadedKeys, ['movie']);

    now = const Duration(seconds: 40);
    await owner.setPlaying(true);
    runtime.emitActual(
      session.loadId,
      const PlaybackActual(playing: true, videoProgressing: false),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(runtime.loadedKeys, ['movie', 'movie']);
    expect(session.currentSnapshot.phase, PlaybackPhase.ready);

    owner.close();
    await session.shutdown();
  });

  test('恢复预算跨 loadId 累计，连续健康十秒后才重置', () async {
    var now = Duration.zero;
    final runtime = _FakeRuntime();
    final session = PlaybackSession(
      runtime: runtime,
      monotonicNow: () => now,
    );
    final owner = session.attach();
    final plan = _plan('movie');
    expect((await owner.load(plan)).outcome, LoadOutcome.ready);
    await owner.setPlaying(true);
    runtime.emitActual(
      session.loadId,
      const PlaybackActual(playing: true, videoProgressing: false),
    );

    for (var i = 0; i < 3; i++) {
      final result = await owner.recover(plan);
      expect(
        result.outcome,
        LoadOutcome.ready,
        reason: 'recovery attempt $i: ${result.failure?.cause}',
      );
    }
    expect(runtime.loadedKeys, ['movie', 'movie', 'movie', 'movie']);

    now = const Duration(seconds: 1);
    runtime.emitActual(
      session.loadId,
      const PlaybackActual(playing: true, videoProgressing: true),
    );
    now = const Duration(seconds: 11);
    runtime.emitActual(
      session.loadId,
      const PlaybackActual(playing: true, videoProgressing: true),
    );

    expect((await owner.recover(plan)).outcome, LoadOutcome.ready);
    expect(runtime.loadedKeys, ['movie', 'movie', 'movie', 'movie', 'movie']);

    owner.close();
    await session.shutdown();
  });

  test('连续故障恢复预算按有效播放时间耗尽，不因经过三十秒自动重开', () async {
    var now = Duration.zero;
    final runtime = _FakeRuntime();
    final session = PlaybackSession(
      runtime: runtime,
      monotonicNow: () => now,
    );
    final owner = session.attach();
    final plan = _plan('movie');
    expect((await owner.load(plan)).outcome, LoadOutcome.ready);
    await owner.setPlaying(true);
    runtime.emitActual(
      session.loadId,
      const PlaybackActual(playing: true, videoProgressing: false),
    );

    for (var i = 0; i < 3; i++) {
      expect((await owner.recover(plan)).outcome, LoadOutcome.ready);
    }
    now = const Duration(seconds: 30);
    final exhausted = await owner.recover(plan);
    expect(exhausted.outcome, LoadOutcome.failed);
    expect(runtime.loadedKeys, ['movie', 'movie', 'movie', 'movie']);

    owner.close();
    await session.shutdown();
  });

  test('shutdown deadline可先结算cleanupIncomplete，released迟到后仍完成资源释放', () async {
    final runtime = _FakeRuntime()
      ..onShutdown = () async => const PlaybackShutdownResult.cleanupIncomplete(
        PlaybackFailure(
          category: PlaybackFailureCategory.timeout,
          operation: 'shutdown',
          stage: PlaybackStage.closing,
          recoverable: false,
          cause: 'fake delayed release',
        ),
      );
    final session = PlaybackSession(runtime: runtime);
    session.attach().close();
    final result = await session.shutdown();
    expect(result.outcome, PlaybackShutdownOutcome.cleanupIncomplete);
    expect(session.currentSnapshot.phase, PlaybackPhase.closing);

    runtime.completeRelease();
    await _until(() => session.currentSnapshot.phase == PlaybackPhase.disposed);
  });

  test('shutdown 不因暂停的 snapshot stream 拖住原生 released', () async {
    final runtime = _FakeRuntime();
    final session = PlaybackSession(runtime: runtime);
    final owner = session.attach();
    final subscription = owner.snapshots.listen((_) {})..pause();

    owner.close();
    final shutdown = await session.shutdown().timeout(
      const Duration(seconds: 1),
    );
    expect(shutdown.outcome, PlaybackShutdownOutcome.released);
    expect(session.currentSnapshot.phase, PlaybackPhase.disposed);
    await subscription.cancel();
  });
}

PlaybackPlan _plan(
  String key, {
  PlaybackSeekPolicy seekPolicy = PlaybackSeekPolicy.allowed,
  PlaybackTimelineKind kind = PlaybackTimelineKind.onDemand,
  List<String>? candidates,
  bool audioOnly = false,
}) => PlaybackPlan(
  contentKey: key,
  source: PlaybackSourceSnapshot.fromDataSource(
    NetworkSource(
      videoSource: candidates?.first ?? 'https://example.test/$key.mp4',
      audioSource: null,
      videoCandidates: candidates ?? const [],
    ),
  ),
  timeline: PlaybackTimeline(
    kind: kind,
    seekPolicy: seekPolicy,
    duration: kind == PlaybackTimelineKind.live
        ? null
        : const Duration(seconds: 10),
  ),
  configuration: PlaybackConfiguration(audioOnly: audioOnly),
);

PlaybackRuntimeLoadResult _audioLoaded(PlaybackExecutionContext context) =>
    PlaybackRuntimeLoadResult(
      loaded: true,
      output: PlaybackOutputPreparation(
        strategy: PlaybackOutputStrategy.noVideo,
        evidence: 'native-track-list-no-video',
        outputEpoch: context.loadId,
        hasVideo: false,
      ),
      capabilities: const PlaybackCapabilities(hasVideo: false, hasAudio: true),
    );

PlaybackRuntimeLoadResult _loaded(
  PlaybackExecutionContext context,
  PlaybackPlan plan,
) => PlaybackRuntimeLoadResult(
  loaded: true,
  output: PlaybackOutputPreparation(
    strategy: PlaybackOutputStrategy.prepared,
    evidence: 'fake-explicit-ack',
    outputEpoch: context.loadId,
    hasVideo: true,
  ),
  capabilities: PlaybackCapabilities(
    seekSupport: plan.timeline.seekPolicy == PlaybackSeekPolicy.allowed
        ? PlaybackSeekSupport.supported
        : PlaybackSeekSupport.unknown,
    seekStart: plan.timeline.seekPolicy == PlaybackSeekPolicy.allowed
        ? Duration.zero
        : null,
    seekEnd: plan.timeline.seekPolicy == PlaybackSeekPolicy.allowed
        ? plan.timeline.duration
        : null,
    hasVideo: true,
    hasAudio: false,
  ),
);

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 100; i++) {
    if (condition()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('Condition did not become true.');
}

class _FakeRuntime implements PlaybackRuntimePort {
  @override
  final int runtimeId = 51;
  @override
  bool shaderChangeRequiresRendererReset = false;
  final StreamController<PlaybackRuntimeEvent> _events =
      StreamController<PlaybackRuntimeEvent>.broadcast(sync: true);
  final Completer<void> _released = Completer<void>();
  final loadedKeys = <String>[];
  final loadedPlans = <PlaybackPlan>[];
  final playCalls = <bool>[];
  final seekCalls = <Duration>[];
  final shaderCalls = <List<String>>[];
  final decoderCalls = <String>[];
  final audioOnlyCalls = <bool>[];
  final speedCalls = <({double speed, Map<String, String> mediaOptions})>[];
  int _loadIndex = 0;
  int _playIndex = 0;
  Future<PlaybackShutdownResult> Function()? onShutdown;
  Future<PlaybackRuntimeLoadResult> Function(
    PlaybackPlan plan,
    PlaybackExecutionContext context,
    int index,
  )?
  onLoad;
  Future<PlaybackRuntimeCommandResult> Function(
    bool playing,
    PlaybackExecutionContext context,
    int index,
  )?
  onSetPlaying;

  @override
  Stream<PlaybackRuntimeEvent> get events => _events.stream;

  @override
  Future<void> get released => _released.future;

  void emitActual(int loadId, PlaybackActual actual) => _events.add(
    PlaybackRuntimeStateChanged(
      runtimeId: runtimeId,
      loadId: loadId,
      actual: actual,
    ),
  );

  void completeRelease() {
    if (!_released.isCompleted) _released.complete();
  }

  @override
  Future<PlaybackRuntimeLoadResult> load(
    PlaybackPlan plan,
    PlaybackExecutionContext context,
  ) async {
    final index = _loadIndex++;
    loadedKeys.add(plan.contentKey);
    loadedPlans.add(plan);
    final result = onLoad == null
        ? _loaded(context, plan)
        : await onLoad!(plan, context, index);
    return result;
  }

  @override
  Future<PlaybackRuntimeCommandResult> setPlaying(
    bool playing,
    PlaybackExecutionContext context,
  ) {
    final index = _playIndex++;
    if (onSetPlaying != null) return onSetPlaying!(playing, context, index);
    playCalls.add(playing);
    return Future.value(const PlaybackRuntimeCommandResult());
  }

  @override
  Future<PlaybackRuntimeCommandResult> seek(
    Duration target,
    PlaybackExecutionContext context,
  ) async {
    seekCalls.add(target);
    return const PlaybackRuntimeCommandResult();
  }

  @override
  Future<PlaybackRuntimeCommandResult> setPlaybackSpeed(
    double value,
    Map<String, String> mediaOptions,
    PlaybackExecutionContext context,
  ) async {
    speedCalls.add((speed: value, mediaOptions: Map.of(mediaOptions)));
    return const PlaybackRuntimeCommandResult();
  }

  @override
  Future<PlaybackRuntimeCommandResult> setVolume(
    double value,
    PlaybackExecutionContext context,
  ) async => const PlaybackRuntimeCommandResult();

  @override
  Future<PlaybackRuntimeCommandResult> setAudioOnly(
    bool value,
    PlaybackExecutionContext context,
  ) async {
    audioOnlyCalls.add(value);
    return const PlaybackRuntimeCommandResult();
  }

  @override
  Future<PlaybackRuntimeCommandResult> setAudioTrack(
    int? trackId,
    PlaybackExecutionContext context,
  ) async => const PlaybackRuntimeCommandResult();

  @override
  Future<PlaybackRuntimeCommandResult> setSubtitleTrack(
    PlaybackSubtitleTrack? track,
    PlaybackExecutionContext context,
  ) async => const PlaybackRuntimeCommandResult();

  @override
  Future<PlaybackRuntimeCommandResult> setDecoder(
    PlaybackDecoder decoder,
    PlaybackExecutionContext context,
  ) async {
    decoderCalls.add(decoder.value);
    return const PlaybackRuntimeCommandResult();
  }

  @override
  Future<PlaybackRuntimeCommandResult> setShader(
    List<String> shaders,
    PlaybackExecutionContext context,
  ) async {
    shaderCalls.add(List.of(shaders));
    return const PlaybackRuntimeCommandResult();
  }

  @override
  Future<PlaybackShutdownResult> shutdown() async {
    final handler = onShutdown;
    if (handler != null) return handler();
    completeRelease();
    unawaited(_events.close());
    return const PlaybackShutdownResult.released();
  }
}
