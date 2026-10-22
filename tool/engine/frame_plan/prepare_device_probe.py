"""Reuse the motion fixture with the production binding and engine frame plan."""
from pathlib import Path


def main():
    repo = Path(__file__).resolve().parents[3]
    source = repo / "tool/experiments/android/frame_plan_probe.dart.in"
    text = source.read_text(encoding="utf-8")
    start = text.index("final _expected =")
    end = text.index("  MediaKit.ensureInitialized();")
    text = text[:start] + """int plannedFrameUs() => SchedulerBinding.instance.currentSystemFrameTimeStamp.inMicroseconds;
const probeAsync = true;
const probeContinuous = true;
const probeIndependent = false;
const probeUseGate = false;
Future<void> main() async {
  ScaledWidgetsFlutterBinding.ensureInitialized();
""" + text[end:]
    text = text.replace("import 'frame_plan_window.dart';", """import 'package:pili_aurora/pages/danmaku/window_screen.dart';
import 'package:pili_aurora/common/widgets/scale_app.dart';""")
    text = text.replace("    probeDirty = true;\n", "")
    text = text.replace("; probeGate = probeUseGate;", ";")
    text = text.replace("; probeGate = false;", ";")
    text = text.replace("continuousVideoVsync:probeContinuous,", "")
    output = repo / "build/frame-plan-engine-probe"
    output.mkdir(parents=True, exist_ok=True)
    (output / "probe.dart").write_text(text, encoding="utf-8", newline="\n")
    print(output / "probe.dart")


if __name__ == "__main__":
    main()
