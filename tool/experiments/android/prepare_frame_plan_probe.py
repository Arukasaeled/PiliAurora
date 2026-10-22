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
    window = replace_once(
        window, "import 'package:canvas_danmaku/frame_rate_ticker.dart';",
        "import 'frame_plan_ticker.dart';",
    )
    window = replace_once(
        window, "    this.frameTimeUs,", "    this.frameTimeUs,\n    this.continuousVideoVsync = true,",
    )
    window = replace_once(
        window, "  final int Function()? frameTimeUs;",
        "  final int Function()? frameTimeUs;\n  final bool continuousVideoVsync;",
    )
    window = replace_once(
        window, "continuousVideoVsync: defaultTargetPlatform == TargetPlatform.android,",
        "continuousVideoVsync: widget.continuousVideoVsync,",
    )
    window = window.replace(
        "show ValueListenable, defaultTargetPlatform, TargetPlatform;", "show ValueListenable;",
    )
    ticker = (root / "third_party/canvas_danmaku/lib/frame_rate_ticker.dart").read_text(encoding="utf-8")
    window = replace_once(
        window,
        "      preserveVideoPhase: const bool.fromEnvironment(\n"
        "        'PILIAURORA_CONTENT_COMPOSITION',\n      ),",
        "      preserveVideoPhase: true,",
    )
    outputs = {
        "frame_plan_window.dart": window,
        "frame_plan_ticker.dart": ticker,
        "probe.dart": (source / "frame_plan_probe.dart.in").read_text(encoding="utf-8"),
        "VideoSurfaceTexture.probe.java": (source / "frame_plan_surface.java.in").read_text(encoding="utf-8"),
        "pacing.cpp": (source / "frame_plan_pacing_probe.cpp").read_text(encoding="utf-8"),
    }
    for name, content in outputs.items():
        (output / name).write_text(content, encoding="utf-8")
    print(output)


if __name__ == "__main__":
    main()
