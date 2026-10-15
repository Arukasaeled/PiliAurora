import 'dart:async';
import 'dart:convert';
import 'dart:developer' show Timeline;

import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// 无网络的高刷呈现探针：同一组滚动弹幕依次检查 120、90 与 60 FPS。
void main() => runApp(const MaterialApp(home: _Probe()));

class _Probe extends StatefulWidget {
  const _Probe();

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  static const _stages = [120, 90, 60];
  int _stage = 0;
  int _frames = 0;
  int _buildUs = 0;
  int _rasterUs = 0;
  DanmakuController<void>? _controller;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
  }

  void _onTimings(List<FrameTiming> timings) {
    for (final timing in timings) {
      _frames++;
      _buildUs += timing.buildDuration.inMicroseconds;
      _rasterUs += timing.rasterDuration.inMicroseconds;
    }
  }

  void _measure() {
    final rate = _stages[_stage];
    // 每档先稳定三秒，再在同一个七秒窗口里读取累计更新和 timing。
    debugPrint('SCENE-HIGH-REFRESH start rate=$rate');
    _timer = Timer(const Duration(seconds: 3), () {
      if (_controller!.scrollDanmaku.every((track) => track.isEmpty)) {
        var accepted = 0;
        for (var i = 0; i < 12; i++) {
          if (_controller!.addDanmaku(
            DanmakuContentItem<void>('FPS probe $i'),
          )) {
            accepted++;
          }
        }
        debugPrint(
          'SCENE-HIGH-REFRESH seed tracks=${_controller!.trackCount} accepted=$accepted',
        );
        if (accepted == 0) throw StateError('高刷探针没有活动弹幕');
      }
      final initialUpdates =
          _controller!.schedulerDiagnostics['updates'] as int;
      final started = Timeline.now;
      _frames = _buildUs = _rasterUs = 0;
      _timer = Timer(const Duration(seconds: 7), () {
        final stats = _controller!.schedulerDiagnostics;
        final seconds = (Timeline.now - started) / 1000000;
        debugPrint(
          'SCENE-HIGH-REFRESH ${jsonEncode({
            'target': rate,
            'seconds': seconds,
            'updateFps': ((stats['updates'] as int) - initialUpdates) / seconds,
            'reportedFrameFps': _frames / seconds,
            'averageBuildUs': _frames == 0 ? null : _buildUs / _frames,
            'averageRasterUs': _frames == 0 ? null : _rasterUs / _frames,
            'scheduler': stats,
          })}',
        );
        if (_stage == _stages.length - 1) {
          debugPrint('SCENE-HIGH-REFRESH done');
        } else {
          setState(() => _stage++);
          _measure();
        }
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final rate = _stages[_stage];
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            Text(
              'Target $rate FPS',
              style: const TextStyle(color: Colors.white),
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) => DanmakuScreen<void>(
                  frameRate: rate,
                  size: constraints.biggest,
                  option: const DanmakuOption(
                    duration: 120,
                    fontSize: 20,
                    massiveMode: true,
                  ),
                  createdController: (controller) {
                    _controller = controller;
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    super.dispose();
  }
}
