"""生成隔离帧计划夹具；生产源码由构建者显式选择是否临时替换。"""

import argparse
from pathlib import Path


def replace_once(source: str, old: str, new: str) -> str:
    if source.count(old) != 1:
        raise ValueError(f"源码接缝已变化：{old}")
    return source.replace(old, new, 1)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", default="build/android-frame-plan-probe")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    output = (root / args.output).resolve()
    if not output.is_relative_to((root / "build").resolve()):
        raise ValueError("实验夹具输出须位于仓库 build/ 内")
    output.mkdir(parents=True, exist_ok=True)
    source = Path(__file__).resolve().parent

    window = (root / "lib/pages/danmaku/window_screen.dart").read_text(encoding="utf-8")
    window = replace_once(window, "import 'package:pili_aurora/pages/danmaku/frame_scheduler.dart';", "import 'frame_plan_scheduler.dart';")
    window = replace_once(window, "    this.frameTimeUs,", "    this.frameTimeUs,\n    this.continuousVideoVsync = true,")
    window = replace_once(window, "  final int Function()? frameTimeUs;", "  final int Function()? frameTimeUs;\n  final bool continuousVideoVsync;")
    window = replace_once(window, "      onFrame: (frame) => _update(frame: frame),", "      onFrame: (frame) => _update(frame: frame),\n      continuousVideoVsync: widget.continuousVideoVsync,")
    ticker = (root / "third_party/canvas_danmaku/lib/frame_rate_ticker.dart").read_text(encoding="utf-8")
    scheduler = (root / "lib/pages/danmaku/frame_scheduler.dart").read_text(encoding="utf-8")
    scheduler = replace_once(scheduler, "import 'package:canvas_danmaku/frame_rate_ticker.dart';", "import 'frame_plan_ticker.dart';")
    scheduler = replace_once(scheduler, "    required this.onFrame,", "    required this.onFrame,\n    this.continuousVideoVsync = true,")
    scheduler = replace_once(scheduler, "  final TargetPlatform _platform;", "  final TargetPlatform _platform;\n  final bool continuousVideoVsync;")
    scheduler = replace_once(scheduler, "continuousVideoVsync: android,", "continuousVideoVsync: android && continuousVideoVsync,")
    surface = (root / "third_party/media_kit_video/android/src/main/java/com/alexmercerind/media_kit_video/VideoSurfaceTexture.java").read_text(encoding="utf-8")
    surface = replace_once(surface, "final class VideoSurfaceTexture extends SurfaceTexture {", """final class VideoSurfaceTexture extends SurfaceTexture {
    static { System.loadLibrary("pacing"); }
    private static native long pacingRequested();
    private static native void pacingConsumed(long sequence, long timestamp);
    private volatile long pacingSequence;""")
    surface = replace_once(surface, "        if (!frameAvailable.getAndSet(false)) return;", "        final long pacing = pacingSequence;\n        if (!frameAvailable.getAndSet(false)) return;")
    surface = replace_once(surface, "        final long timestamp = getTimestamp();", "        final long timestamp = getTimestamp();\n        pacingConsumed(pacing, timestamp);")
    surface = replace_once(surface, "texture -> {\n            frameAvailable.set(true);", "texture -> {\n            pacingSequence = pacingRequested();\n            frameAvailable.set(true);")
    outputs = {
        "frame_plan_window.dart": window,
        "frame_plan_ticker.dart": ticker,
        "frame_plan_scheduler.dart": scheduler,
        "probe.dart": (source / "frame_plan_probe.dart.in").read_text(encoding="utf-8"),
        "VideoSurfaceTexture.probe.java": surface,
        "pacing.cpp": (source / "frame_plan_pacing_probe.cpp").read_text(encoding="utf-8"),
    }
    for name, content in outputs.items():
        (output / name).write_text(content, encoding="utf-8")
    print(output)


if __name__ == "__main__":
    main()
