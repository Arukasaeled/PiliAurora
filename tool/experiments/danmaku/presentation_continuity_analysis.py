#!/usr/bin/env python3
"""汇总同帧媒体位置与实际呈现时间的跨帧变化、±1/±2/±3 局部波动。"""

from __future__ import annotations

import argparse
import csv
import json
import math
import statistics
from pathlib import Path


RADII = (1, 2, 3)


def describe(values) -> dict:
    values = sorted(values)
    if not values:
        return {"n": 0}
    return {
        "n": len(values),
        "mean": statistics.mean(values),
        "p05": values[round((len(values) - 1) * 0.05)],
        "p50": statistics.median(values),
        "p95": values[round((len(values) - 1) * 0.95)],
        "p99": values[round((len(values) - 1) * 0.99)],
        "min": values[0],
        "max": values[-1],
    }


def rms(values) -> float:
    values = list(values)
    return math.sqrt(statistics.mean(value * value for value in values))


def continuous_segments(frames: list[dict]) -> list[list[dict]]:
    segments = []
    for frame in frames:
        if segments:
            previous = segments[-1][-1]
            continuous = (
                frame["index"] == previous["index"] + 1
                and frame["targetUs"] > previous["targetUs"]
                and frame["presentNs"] > previous["presentNs"]
                and frame["positionUs"] >= previous["positionUs"]
            )
        else:
            continuous = False
        if continuous:
            segments[-1].append(frame)
        else:
            segments.append([frame])
    return segments


def span(first: dict, last: dict, rate: float) -> dict:
    target_us = last["targetUs"] - first["targetUs"]
    present_ns = last["presentNs"] - first["presentNs"]
    present_us = present_ns / 1000
    return {
        "firstIndex": first["index"],
        "lastIndex": last["index"],
        "targetGapMs": target_us / 1000,
        "presentGapMs": present_us / 1000,
        "gapRelativeError": present_us / target_us - 1,
        "velocityRatio": (last["positionUs"] - first["positionUs"])
        / (rate * present_us),
        "phaseChangeMs": (present_ns - target_us * 1000) / 1e6,
    }


def analyze(frames: list[dict], rate: float = 1.0) -> dict:
    if not math.isfinite(rate) or rate <= 0:
        raise ValueError("媒体速率必须为正数")
    segments = continuous_segments(frames)
    adjacent = []
    spans = {str(k): [] for k in RADII}
    changes = {str(k): [] for k in RADII}
    windows = {str(r): [] for r in RADII}
    for segment in segments:
        steps = [span(a, b, rate) for a, b in zip(segment, segment[1:])]
        adjacent.extend(steps)
        for distance in RADII:
            spans[str(distance)].extend(
                span(a, b, rate)
                for a, b in zip(segment, segment[distance:])
            )
            # 间隔序列另作滞后差分，保留隔帧重复或交替的波动形式。
            for a, b in zip(steps, steps[distance:]):
                changes[str(distance)].append({
                    "firstIndex": a["lastIndex"],
                    "lastIndex": b["lastIndex"],
                    "gapRelativeChange": b["presentGapMs"] / a["presentGapMs"] - 1,
                    "velocityChange": b["velocityRatio"] - a["velocityRatio"],
                })
        for radius in RADII:
            for center in range(radius, len(segment) - radius):
                local_frames = segment[center - radius : center + radius + 1]
                local_steps = steps[center - radius : center + radius]
                gaps = [step["presentGapMs"] for step in local_steps]
                velocities = [step["velocityRatio"] for step in local_steps]
                delays_ns = [f["presentNs"] - f["targetUs"] * 1000 for f in local_frames]
                net = span(local_frames[0], local_frames[-1], rate)
                # RMS 保留窗口内正负偏差，长短帧相抵时仍能看到运动抖动。
                windows[str(radius)].append({
                    "centerIndex": segment[center]["index"],
                    "firstIndex": local_frames[0]["index"],
                    "lastIndex": local_frames[-1]["index"],
                    "targetSpanMs": net["targetGapMs"],
                    "presentSpanMs": net["presentGapMs"],
                    "gapCv": statistics.pstdev(gaps) / statistics.mean(gaps),
                    "gapRelativeRms": rms(s["gapRelativeError"] for s in local_steps),
                    "velocityRms": rms(v - 1 for v in velocities),
                    "velocityRange": max(velocities) - min(velocities),
                    "phaseSpanMs": (max(delays_ns) - min(delays_ns)) / 1e6,
                    "netVelocityRatio": net["velocityRatio"],
                    "netGapRelativeError": net["gapRelativeError"],
                    "outside10pctSteps": sum(abs(v - 1) > 0.1 for v in velocities),
                })

    span_stats = {}
    change_stats = {}
    window_stats = {}
    for key in spans:
        rows = spans[key]
        span_stats[key] = {
            "pairs": len(rows),
            **{metric: describe(row[metric] for row in rows) for metric in (
                "presentGapMs", "gapRelativeError", "velocityRatio", "phaseChangeMs",
            )},
            "absPhaseChangeMs": describe(abs(row["phaseChangeMs"]) for row in rows),
            "outside10pct": sum(abs(row["velocityRatio"] - 1) > 0.1 for row in rows),
        }
        rows = changes[key]
        change_stats[key] = {
            "pairs": len(rows),
            "absGapRelativeChange": describe(abs(row["gapRelativeChange"]) for row in rows),
            "absVelocityChange": describe(abs(row["velocityChange"]) for row in rows),
        }
        rows = windows[key]
        window_stats[key] = {
            "radius": int(key),
            "framesPerWindow": 2 * int(key) + 1,
            "windows": len(rows),
            "withOutside10pct": sum(row["outside10pctSteps"] > 0 for row in rows),
            **{metric: describe(row[metric] for row in rows) for metric in (
                "targetSpanMs", "presentSpanMs", "gapCv", "gapRelativeRms",
                "velocityRms", "velocityRange", "phaseSpanMs",
                "netVelocityRatio", "netGapRelativeError",
            )},
        }
    return {
        "summary": {
            "frames": len(frames),
            "segmentLengths": [len(segment) for segment in segments],
            "rate": rate,
            "quantiles": "sorted[round((n-1)*q)], median for p50",
            "lagSpans": span_stats,
            "lagChanges": change_stats,
            "centeredWindows": window_stats,
        },
        "adjacent": adjacent,
        "lagSpans": spans,
        "lagChanges": changes,
        "centeredWindows": windows,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("inputs", nargs="+", type=Path, help="已关联的单阶段 presentation-stage-*.json")
    parser.add_argument("--output", type=Path, help="诊断产物目录；省略时向标准输出写 JSONL")
    parser.add_argument("--rate", type=float, default=1.0, help="测量段媒体倍速，默认 1")
    args = parser.parse_args()
    if args.output:
        args.output.mkdir(parents=True, exist_ok=True)
    results = []
    csv_rows = []
    for path in args.inputs:
        record = json.loads(path.read_text(encoding="utf-8"))
        result = analyze(record["matched"], args.rate)
        metadata = record["summary"]
        name = f'{metadata["run"]}-stage-{metadata["stage"]}'
        result["source"] = metadata
        if args.output:
            (args.output / f"{name}.json").write_text(
                json.dumps(result, indent=2, ensure_ascii=False), encoding="utf-8"
            )
        else:
            print(json.dumps(result, ensure_ascii=False))
        results.append({"source": metadata, "summary": result["summary"]})
        for radius, summary in result["summary"]["centeredWindows"].items():
            csv_rows.append({
                "run": metadata["run"], "stage": metadata["stage"], "target": metadata["target"],
                "radius": radius, "framesPerWindow": summary["framesPerWindow"],
                "windows": summary["windows"], "withOutside10pct": summary["withOutside10pct"],
                **{f"{metric}_{stat}": summary[metric].get(stat) for metric in (
                    "gapRelativeRms", "velocityRms", "phaseSpanMs", "netVelocityRatio",
                ) for stat in ("mean", "p50", "p95", "p99", "max")},
            })
        if args.output:
            print(json.dumps({"run": metadata["run"], "stage": metadata["stage"],
                              "frames": len(record["matched"]),
                              "windows": {k: v["windows"] for k, v in result["summary"]["centeredWindows"].items()}}))
    if args.output is None:
        return
    (args.output / "summary.json").write_text(
        json.dumps(results, indent=2, ensure_ascii=False), encoding="utf-8"
    )
    with (args.output / "summary.csv").open("w", newline="", encoding="utf-8-sig") as target:
        writer = csv.DictWriter(target, fieldnames=list(csv_rows[0]))
        writer.writeheader()
        writer.writerows(csv_rows)


if __name__ == "__main__":
    main()
