"""Check rate-normalized motion in a PILIAURORA_PROBE_RATE_SWITCH capture."""
import argparse
import json
from pathlib import Path


def analyze(log):
    motion, anchors, commands = [], [], []
    for line in log.splitlines():
        if "PILI_MOTION " not in line:
            continue
        record = line.split("PILI_MOTION ", 1)[1]
        if record.startswith("data "):
            data = json.loads(record[5:])
            motion.extend(data.get("motion", []))
            anchors.extend(data.get("anchors", []))
        elif record.startswith("rate "):
            commands.append(json.loads(record[5:]))
    if not motion or not commands or any(len(row) != 6 for row in motion):
        raise ValueError("Capture needs PILIAURORA_PROBE_RATE_SWITCH=true")
    pairs = [(a, b) for a, b in zip(motion, motion[1:]) if b[1] > a[1]]
    ratios = [(b[2] - a[2]) / (b[1] - a[1]) / (b[3] / 1000)
              for a, b in pairs if b[3] > 0]
    samples = []
    for command in commands:
        anchor = next((row for row in anchors
                       if row[0] >= command["appliedUs"]
                       and row[2] == round(command["speed"] * 1000)), None)
        samples.append({"speed": command["speed"], "sampleLatencyUs":
                        None if anchor is None else anchor[0] - command["appliedUs"]})
    zero = sum(b[2] == a[2] for a, b in pairs)
    backwards = sum(b[2] < a[2] for a, b in pairs)
    outside = sum(abs(ratio - 1) > .06 for ratio in ratios)
    return {
        "updates": len(motion), "zeroSteps": zero, "backwardsSteps": backwards,
        "normalizedRateMin": min(ratios), "normalizedRateMax": max(ratios),
        "outside6Percent": outside, "commandSamples": samples,
        "passed": (len(commands) == 7 and len(ratios) == len(pairs)
                   and zero == backwards == outside == 0
                   and all(row["sampleLatencyUs"] is not None for row in samples)),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    summary = analyze(args.log.read_text(encoding="utf-8"))
    result = json.dumps(summary, ensure_ascii=False, indent=2)
    if args.output:
        args.output.write_text(result + "\n", encoding="utf-8")
    print(result)
    raise SystemExit(0 if summary["passed"] else 1)


if __name__ == "__main__":
    main()
