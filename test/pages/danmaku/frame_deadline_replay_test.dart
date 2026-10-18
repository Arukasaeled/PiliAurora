import 'dart:convert';
import 'dart:io';

import 'package:canvas_danmaku/frame_rate_ticker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('刷新率未知时仍可跟随外部 vsync', (tester) async {
    var updates = 0;
    final ticker = FrameRateTicker(
      (_) => updates++,
      screenRefreshRate: () => double.nan,
    )..start();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(updates, 2);
    ticker.dispose();
    await tester.pump();
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('真实亚毫秒槽位偏差不会使更新截止连续延期', (tester) async {
    tester.view.display.refreshRate = 120;
    addTearDown(tester.view.display.resetRefreshRate);
    final fixture = jsonDecode(
      File(
        'test/pages/danmaku/fixtures/cadence_boundary.json',
      ).readAsStringSync(),
    ) as Map<String, dynamic>;
    final origin = tester.binding.clock.now().microsecondsSinceEpoch;
    int now() => tester.binding.clock.now().microsecondsSinceEpoch - origin;
    final frames = ValueNotifier<List<int>>(const []);
    final updates = <int>[];
    final ticker = _ReplayTicker(
      (_) => updates.add(
        tester.binding.currentSystemFrameTimeStamp.inMicroseconds,
      ),
      now,
      frames,
    )..start();
    for (final dynamic event in fixture['events'] as List) {
      final row = event as List;
      await tester.binding.delayed(
        Duration(microseconds: (row[0] as int) - now()),
      );
      if (row[1] == 'video') {
        frames.value = List<int>.from(row[2] as List);
      } else {
        tester.binding.handleBeginFrame(Duration(microseconds: row[2] as int));
        tester.binding.handleDrawFrame();
      }
    }
    final diagnostics = ticker.diagnostics;
    ticker.dispose();
    frames.dispose();
    await tester.binding.delayed(const Duration(seconds: 2));
    final gaps = [
      for (var i = 1; i < updates.length; i++) updates[i] - updates[i - 1],
    ];
    debugPrint(
      'captured cadence: updates=${updates.length}, '
      'maxGapUs=${gaps.reduce((a, b) => a > b ? a : b)}, '
      'skips=${diagnostics['deadlineSkips']}',
    );
    expect(gaps, everyElement(lessThan(20000)));
    expect(updates.length, inInclusiveRange(70, 74));
    expect(tester.binding.hasScheduledFrame, isFalse);
  });
}

class _ReplayTicker extends FrameRateTicker {
  _ReplayTicker(super.onTick, this.now, ValueListenable<List<int>> frames)
    : super(frameRate: 60, videoFrameTimings: frames);
  final int Function() now;
  @override
  int get clockMicroseconds => now();
}
