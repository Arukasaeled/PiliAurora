import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/plugin/pl_player/playback/playback_contracts.dart';
import 'package:pili_aurora/services/audio_session.dart';

void main() {
  test(
    'duplicate duck and early end restore once after volume command settles',
    () async {
      final ducker = PlaybackVolumeDucker();
      final owner = Object();
      final pending = Completer<CommandResult>();
      final requestedVolumes = <double>[];
      var currentVolume = 80.0;
      var volumeRevision = 0;

      Future<CommandResult> setVolume(double volume) {
        requestedVolumes.add(volume);
        currentVolume = volume;
        volumeRevision++;
        if (requestedVolumes.length == 1) return pending.future;
        return Future.value(const CommandResult.applied());
      }

      Future<void> begin() => ducker.begin(
        owner: owner,
        volume: 80,
        currentVolume: () => currentVolume,
        currentRevision: () => volumeRevision,
        isCurrent: () => true,
        setVolume: setVolume,
      );

      final firstBegin = begin();
      await begin();
      expect(requestedVolumes, [40]);

      await ducker.end();
      await ducker.end();
      expect(requestedVolumes, [40]);

      pending.complete(const CommandResult.applied());
      await firstBegin;

      expect(requestedVolumes, [40, 80]);
      expect(currentVolume, 80);
    },
  );

  test('duck completion preserves a newer user volume choice', () async {
    final ducker = PlaybackVolumeDucker();
    final owner = Object();
    final requestedVolumes = <double>[];
    var currentVolume = 80.0;
    var volumeRevision = 0;

    Future<CommandResult> setVolume(double volume) async {
      requestedVolumes.add(volume);
      currentVolume = volume;
      volumeRevision++;
      return const CommandResult.applied();
    }

    await ducker.begin(
      owner: owner,
      volume: 80,
      currentVolume: () => currentVolume,
      currentRevision: () => volumeRevision,
      isCurrent: () => true,
      setVolume: setVolume,
    );
    currentVolume = 63;
    volumeRevision++;

    await ducker.end();

    expect(requestedVolumes, [40]);
    expect(currentVolume, 63);
  });

  test('rejected duck command releases its pending state', () async {
    final ducker = PlaybackVolumeDucker();
    final owner = Object();
    var currentVolume = 50.0;
    var volumeRevision = 0;
    var attempts = 0;

    Future<CommandResult> setVolume(double volume) async {
      attempts++;
      if (attempts == 1) return const CommandResult.inactive();
      currentVolume = volume;
      volumeRevision++;
      return const CommandResult.applied();
    }

    Future<void> begin() => ducker.begin(
      owner: owner,
      volume: currentVolume,
      currentVolume: () => currentVolume,
      currentRevision: () => volumeRevision,
      isCurrent: () => true,
      setVolume: setVolume,
    );

    await begin();
    expect(currentVolume, 50);

    await begin();
    await ducker.end();

    expect(currentVolume, 50);
    expect(attempts, 3);
  });

  test(
    'focus token transfers to a new facade until interruption ends',
    () async {
      final focus = PlaybackFocusInhibitor();
      final firstFacade = Object();
      final secondFacade = Object();
      const firstToken = PlaybackInhibitorToken(
        source: PlaybackInhibitorSource.audioFocus,
        id: 1,
      );
      const secondToken = PlaybackInhibitorToken(
        source: PlaybackInhibitorSource.audioFocus,
        id: 2,
      );
      final released = <PlaybackInhibitorToken>[];

      PlaybackFocusAcquire acquire(PlaybackInhibitorToken token) =>
          () => token;
      PlaybackFocusRelease releaseFor(
        Object facade,
      ) => (token) async {
        expect(
          identical(facade, firstFacade) || identical(facade, secondFacade),
          isTrue,
        );
        released.add(token);
        return const CommandResult.applied();
      };

      focus
        ..begin()
        ..attach(
          firstFacade,
          acquire: acquire(firstToken),
          release: releaseFor(firstFacade),
        )
        ..attach(
          secondFacade,
          acquire: acquire(secondToken),
          release: releaseFor(secondFacade),
        );

      await Future<void>.delayed(Duration.zero);
      expect(released, [firstToken]);

      await focus.end();
      expect(released, [firstToken, secondToken]);
    },
  );
}
