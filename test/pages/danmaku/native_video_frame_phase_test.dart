import 'package:canvas_danmaku/frame_rate_ticker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'frame_sync_fixture.dart';

void main() {
  for (final hz in [119.88, 120.0, 120.12]) {
    for (final androidFrames in [false, true]) {
      for (final displaySync in [false, true]) {
        for (final phase in [0, 1]) {
          testWidgets(
            '纹理刷新请求决定 60 FPS 相位，$hz Hz phase=$phase '
            'sync=$displaySync Android=$androidFrames',
            (
              tester,
            ) async {
              tester.view.display.refreshRate = hz;
              addTearDown(tester.view.display.resetRefreshRate);
              final frames = ValueNotifier<List<int>>(const []);
              final sync = ValueNotifier(displaySync);
              addTearDown(frames.dispose);
              addTearDown(sync.dispose);
              final fixture = FrameSyncFixture(
                tester,
                hz,
                model: androidFrames
                    ? FrameSyncModel.android
                    : FrameSyncModel.isolated,
              );
              var ticks = 0;
              final ticker = _ClockTicker(
                (_) => ticks++,
                () => fixture.now,
                frames,
                sync,
              )..start();
              await tester.pump();
              final batch = <int>[];
              var extra = 0;
              var combined = 0;
              var initialTicks = 0;
              for (var slot = 1; slot <= 720; slot++) {
                await fixture.elapseToSlot(slot);
                final video = slot % 2 == phase;
                if (video) {
                  batch.add(fixture.requestForSlot(slot));
                }
                final dart = await fixture.pump(hasVideo: video);
                if (slot % 30 == 0) {
                  frames.value = batch.toList();
                  batch.clear();
                }
                if (slot == 240) initialTicks = ticks;
                if (slot > 240) {
                  if (video || dart) combined++;
                  if (dart && !video) extra++;
                }
              }
              ticker.dispose();
              await tester.binding.delayed(const Duration(seconds: 2));
              expect(tester.binding.hasScheduledFrame, isFalse);
              expect(ticks - initialTicks, closeTo(240, 1));
              expect(combined, 240);
              expect(extra, 0);
            },
          );
        }
      }
    }
  }
}

class _ClockTicker extends FrameRateTicker {
  _ClockTicker(
    super.onTick,
    this.now,
    ValueListenable<List<int>> frames,
    ValueListenable<bool> sync,
  ) : super(
        frameRate: 60,
        videoFrameTimings: frames,
        videoDisplaySyncActive: sync,
      );

  final int Function() now;

  @override
  int get clockMicroseconds => now();
}
