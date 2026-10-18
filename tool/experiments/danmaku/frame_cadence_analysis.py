#!/usr/bin/env python3
"""Compare two cadence.jsonl captures and report scheduler/latency deltas."""

from __future__ import annotations

import argparse
import bisect
import collections
import csv
import json
import math
from datetime import datetime, timedelta, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
OUTPUT = ROOT / "build" / "frame-cadence-analysis"
EVENT_NAMES = {
    0: "request",
    1: "timerPlan",
    2: "timerWake",
    3: "callback",
    4: "update",
    5: "skip",
    6: "nativeBatch",
    7: "diagnosticsCapture",
    8: "danmakuBatch",
    9: "paragraph",
    10: "image",
    11: "specialImage",
    12: "paintScroll",
    13: "paintStatic",
    14: "paintSpecial",
    15: "frameTiming",
    16: "clock",
    17: "flush",
    18: "nativeClock",
    19: "schedulerState",
    100: "native.frameRequest",
    101: "native.updateTexImage",
    102: "native.reuseTexture",
    103: "native.consumed",
}


def percentile(values: list[int | float], p: float) -> float:
    ordered = sorted(values)
    at = (len(ordered) - 1) * p
    lo = math.floor(at)
    hi = math.ceil(at)
    return ordered[lo] + (ordered[hi] - ordered[lo]) * (at - lo)


def stats(values) -> dict:
    values = list(values)
    if not values:
        return {"n": 0}
    result = {
        "n": len(values),
        "mean": round(sum(values) / len(values), 3),
        "p50": round(percentile(values, 0.50), 3),
        "p95": round(percentile(values, 0.95), 3),
        "p99": round(percentile(values, 0.99), 3),
        "max": round(max(values), 3),
    }
    for threshold in (20000, 40000, 100000):
        result[f"gt{threshold // 1000}ms"] = sum(value > threshold for value in values)
    return result


def load_capture(path: Path) -> dict:
    groups: dict[int, list[list[int]]] = collections.defaultdict(list)
    headers = []
    sequences = []
    drops = []
    with path.open(encoding="utf-8") as source:
        for line in source:
            record = json.loads(line)
            if record["type"] == "cadence.batch":
                sequences.append(record["sequence"])
                drops.append(record["dropped"])
                for row in record["events"]:
                    groups[row[1]].append(row)
            else:
                headers.append(record)
    for rows in groups.values():
        rows.sort(key=lambda row: row[0])
    return {
        "path": str(path),
        "groups": groups,
        "headers": headers,
        "sequence_count": len(sequences),
        "sequence_holes": sum(
            later - earlier != 1 for earlier, later in zip(sequences, sequences[1:])
        ),
        "dropped_max": max(drops) if drops else 0,
    }


def wall_clock(header: dict, monotonic_us: int) -> str:
    session = datetime.fromisoformat(header["utc"])
    shifted = session + timedelta(microseconds=monotonic_us - header["monotonicUs"])
    return shifted.astimezone(timezone(timedelta(hours=8))).isoformat(
        timespec="milliseconds"
    )


def event_times(rows: list[list[int]], column: int = 0) -> list[int]:
    return [row[column] for row in rows]


def count_between(times: list[int], start: int, end: int) -> int:
    return bisect.bisect_right(times, end) - bisect.bisect_left(times, start)


def analyze(name: str, path: Path) -> dict:
    capture = load_capture(path)
    groups = capture["groups"]
    header = capture["headers"][0]
    updates = groups[4]
    callbacks = groups[3]
    skips = groups[5]
    plans = groups[1]
    wakes = groups[2]
    frames = groups[15]
    batches = groups[8]
    update_times_mono = event_times(updates)
    update_times_frame = event_times(updates, 6)
    callback_times = event_times(callbacks)
    callback_by_ticker = {row[4]: row for row in callbacks}
    plan_times = event_times(plans)
    wake_times = event_times(wakes)
    frame_times = event_times(frames, 3)
    batch_times = event_times(batches)

    gaps = [
        later - earlier
        for earlier, later in zip(update_times_frame, update_times_frame[1:])
    ]
    execution_gaps = [
        later - earlier
        for earlier, later in zip(update_times_mono, update_times_mono[1:])
    ]

    # Split long idle/app-switch intervals from continuous playback.
    segments = []
    segment_start = 0
    for index, gap in enumerate(gaps):
        if gap > 500000:
            segments.append((segment_start, index + 1))
            segment_start = index + 1
    segments.append((segment_start, len(updates)))
    segments = [segment for segment in segments if segment[1] - segment[0] >= 2]
    active_gaps = []
    active_execution_gaps = []
    active_callback_gaps = []
    active_duration_us = 0
    for start, end in segments:
        active_duration_us += update_times_mono[end - 1] - update_times_mono[start]
        active_gaps.extend(
            later - earlier
            for earlier, later in zip(
                update_times_frame[start:end], update_times_frame[start + 1 : end]
            )
        )
        active_execution_gaps.extend(
            later - earlier
            for earlier, later in zip(
                update_times_mono[start:end], update_times_mono[start + 1 : end]
            )
        )
        callback_start = bisect.bisect_left(
            callback_times, update_times_mono[start]
        )
        callback_end = bisect.bisect_right(
            callback_times, update_times_mono[end - 1]
        )
        active_callback_gaps.extend(
            later - earlier
            for earlier, later in zip(
                callback_times[callback_start:callback_end],
                callback_times[callback_start + 1 : callback_end],
            )
        )

    active_event_ranges = [
        (update_times_mono[start], update_times_mono[end - 1])
        for start, end in segments
    ]
    active_frame_ranges = [
        (update_times_frame[start], update_times_frame[end - 1])
        for start, end in segments
    ]

    def in_active_event_range(timestamp: int) -> bool:
        return any(start <= timestamp <= end for start, end in active_event_ranges)

    def in_active_frame_range(timestamp: int) -> bool:
        return any(start <= timestamp <= end for start, end in active_frame_ranges)

    active_frames = [row for row in frames if in_active_frame_range(row[3])]
    active_wakes = [row for row in wakes if in_active_event_range(row[0])]
    active_render = {
        EVENT_NAMES[kind]: stats(
            row[4] for row in groups[kind] if in_active_event_range(row[0])
        )
        for kind in (8, 9, 10, 11, 12, 13, 14, 17, 100, 101, 102, 103)
        if groups[kind]
    }

    # A problematic skip is one whose immediate timer re-plan advances the
    # unexecuted update deadline before the next accepted update.
    skip_rows = []
    problematic_skips = 0
    plan_advanced_skips = 0
    for row in skips:
        plan_index = bisect.bisect_right(plan_times, row[0])
        update_index = bisect.bisect_right(update_times_mono, row[0])
        callback_index = bisect.bisect_right(callback_times, row[0])
        next_plan = plans[plan_index] if plan_index < len(plans) else None
        next_update = (
            updates[update_index] if update_index < len(updates) else None
        )
        next_callback = (
            callbacks[callback_index] if callback_index < len(callbacks) else None
        )
        skip_callback = callback_by_ticker.get(row[4])
        had_timer = skip_callback[7] if skip_callback is not None else None
        advance = None
        if next_plan is not None:
            advance = next_plan[3] - row[5]
        before_update = (
            next_plan is not None
            and next_update is not None
            and next_plan[0] <= next_update[0]
        )
        timer_fired = had_timer == 0
        if before_update and advance is not None and advance > 1000 and timer_fired:
            problematic_skips += 1
        if before_update and advance is not None and advance > 0:
            plan_advanced_skips += 1
        skip_rows.append(
            {
                "time": wall_clock(header, row[0]),
                "ahead_us": row[5] - row[4],
                "had_timer": had_timer,
                "timer_fired": timer_fired,
                "next_plan_advance_us": advance,
                "next_plan_before_update": before_update,
                "next_callback_found": next_callback is not None,
            }
        )

    long_gap_rows = []
    for index, gap in enumerate(gaps):
        if gap <= 20000:
            continue
        previous = updates[index]
        current = updates[index + 1]
        event_start = previous[0]
        event_end = current[0]
        frame_start = previous[6]
        frame_end = current[6]
        skip_events = [
            row for row in skips if event_start <= row[0] <= event_end
        ]
        skip_advances = 0
        for row in skip_events:
            plan_index = bisect.bisect_right(plan_times, row[0])
            update_index = bisect.bisect_right(update_times_mono, row[0])
            if plan_index >= len(plans) or update_index >= len(updates):
                continue
            plan = plans[plan_index]
            next_update = updates[update_index]
            skip_callback = callback_by_ticker.get(row[4])
            timer_fired = skip_callback is not None and skip_callback[7] == 0
            if (
                timer_fired
                and plan[0] <= next_update[0]
                and plan[3] - row[5] > 1000
            ):
                skip_advances += 1
        wake_rows = [
            row for row in wakes if event_start <= row[0] <= event_end
        ]
        plan_events = [
            row for row in plans if event_start <= row[0] <= event_end
        ]
        frame_rows = [
            row for row in frames if frame_start <= row[3] <= frame_end
        ]
        callback_count = count_between(callback_times, event_start, event_end)
        batch_count = count_between(batch_times, event_start, event_end)
        batch_rows = [
            row for row in batches if event_start <= row[0] <= event_end
        ]
        batch_position_delta = (
            batch_rows[-1][5] - batch_rows[0][5] if len(batch_rows) >= 2 else 0
        )
        max_timer_late = max((row[4] for row in wake_rows), default=0)
        max_skip_ahead = max((row[5] - row[4] for row in skip_events), default=0)
        if gap > 500000 and not plan_events:
            cause = "ticker 停止排程（暂停/启停边界）"
        elif gap > 500000 and callback_count <= 1:
            cause = "长时间无回调（暂停、切片或离开前台，需状态确认）"
        elif callback_count == 0:
            cause = "无帧回调（定时器已请求但引擎未交付）"
        elif skip_advances:
            cause = "skip 后截止时间被推进（旧机制残留）"
        elif max_timer_late > 8000:
            cause = "Timer 明显迟到"
        elif skip_events:
            cause = "隔槽 skip / 合帧，无截止推进"
        else:
            cause = "无 skip 的调度抖动"
        long_gap_rows.append(
            {
                "index": index,
                "time": wall_clock(header, previous[0]),
                "gap_ms": round(gap / 1000, 3),
                "system_frame_gap_ms": round(gap / 1000, 3),
                "execution_gap_ms": round((current[3] - previous[3]) / 1000, 3),
                "callbacks": callback_count,
                "skips": len(skip_events),
                "skip_deadline_advances": skip_advances,
                "timer_wakes": len(wake_rows),
                "timer_plans": len(plan_events),
                "max_timer_late_ms": round(max_timer_late / 1000, 3),
                "max_skip_ahead_ms": round(max_skip_ahead / 1000, 3),
                "danmaku_batches": batch_count,
                "batch_position_delta_ms": batch_position_delta,
                "frames": len(frame_rows),
                "cause": cause,
            }
        )

    scheduler_transitions = []
    previous_state = None
    for row in groups[19]:
        state = tuple(row[3:8])
        if state != previous_state:
            scheduler_transitions.append(
                {
                    "time": wall_clock(header, row[0]),
                    "target_fps": row[3],
                    "screen_period_us": row[4],
                    "native_period_us": row[5],
                    "sync_period_us": row[6],
                    "stable_intervals": row[7],
                }
            )
            previous_state = state

    build_us = [row[5] - row[4] for row in active_frames]
    raster_us = [row[7] - row[6] for row in active_frames]
    vsync_gaps = [
        later[3] - earlier[3]
        for earlier, later in zip(active_frames, active_frames[1:])
        if later[3] - earlier[3] <= 500000
    ]
    raster_gaps = [
        later[7] - earlier[7]
        for earlier, later in zip(active_frames, active_frames[1:])
        if later[7] - earlier[7] <= 500000
    ]
    slow_raster_frames = sorted(
        (
            {
                "time": wall_clock(header, row[0]),
                "raster_ms": round((row[7] - row[6]) / 1000, 3),
                "build_ms": round((row[5] - row[4]) / 1000, 3),
            }
            for row in active_frames
            if row[7] - row[6] > 16667
        ),
        key=lambda item: item["raster_ms"],
        reverse=True,
    )

    result = {
        "name": name,
        "capture": {
            "path": capture["path"],
            "batches": capture["sequence_count"],
            "sequence_holes": capture["sequence_holes"],
            "dropped_max": capture["dropped_max"],
            "events": sum(len(rows) for rows in groups.values()),
            "recording_start": wall_clock(
                header, min(row[0] for rows in groups.values() for row in rows)
            ),
            "recording_end": wall_clock(
                header, max(row[0] for rows in groups.values() for row in rows)
            ),
            "targets": dict(sorted(collections.Counter(
                row[3] for row in groups[19]
            ).items())),
            "screen_periods": dict(sorted(collections.Counter(
                row[4] for row in groups[19]
            ).items())),
        },
        "counts": {
            EVENT_NAMES[kind]: len(rows) for kind, rows in sorted(groups.items())
        },
        "playback": {
            "update_count": len(updates),
            "duration_s": round(
                (update_times_mono[-1] - update_times_mono[0]) / 1e6, 3
            ),
            "active_duration_s": round(active_duration_us / 1e6, 3),
            "segments": [
                {
                    "updates": end - start,
                    "start": wall_clock(header, update_times_mono[start]),
                    "end": wall_clock(header, update_times_mono[end - 1]),
                    "duration_s": round(
                        (update_times_mono[end - 1] - update_times_mono[start])
                        / 1e6,
                        3,
                    ),
                }
                for start, end in segments
            ],
            "update_frame_interval_us_all": stats(gaps),
            "update_frame_interval_us_active": stats(active_gaps),
            "update_execution_interval_us_all": stats(execution_gaps),
            "update_execution_interval_us_active": stats(active_execution_gaps),
            "callback_interval_us_active": stats(active_callback_gaps),
            "rate_hz_active": round(
                len(active_gaps) * 1e6 / sum(active_gaps), 3
            )
            if active_gaps
            else None,
        },
        "skips": {
            "count": len(skips),
            "ahead_us": stats(row[5] - row[4] for row in skips),
            "ahead_le_1000_us": sum(row[5] - row[4] <= 1000 for row in skips),
            "timer_fired": sum(
                callback_by_ticker.get(row[4]) is not None
                and callback_by_ticker[row[4]][7] == 0
                for row in skips
            ),
            "timer_pending": sum(
                callback_by_ticker.get(row[4]) is not None
                and callback_by_ticker[row[4]][7] == 1
                for row in skips
            ),
            "next_plan_before_update": sum(
                row["next_plan_before_update"] for row in skip_rows
            ),
            "plan_advanced_skips": plan_advanced_skips,
            "problematic_deadline_advances": problematic_skips,
        },
        "timer": {
            "lateness_us_active": stats(row[4] for row in active_wakes),
        },
        "frame_timing_active_us": {
            "build": stats(build_us),
            "raster": stats(raster_us),
            "vsync_gap": stats(vsync_gaps),
            "raster_finish_gap": stats(raster_gaps),
            "build_gt_8ms": sum(value > 8000 for value in build_us),
            "raster_gt_16_667ms": sum(value > 16667 for value in raster_us),
            "raster_gt_20ms": sum(value > 20000 for value in raster_us),
            "raster_gt_33ms": sum(value > 33334 for value in raster_us),
        },
        "render_us_active": active_render,
        "slow_raster_frames": slow_raster_frames[:20],
        "scheduler_transitions": scheduler_transitions,
        "long_gaps": long_gap_rows,
    }

    if skip_rows:
        with (OUTPUT / f"{name}-skips.csv").open(
            "w", newline="", encoding="utf-8-sig"
        ) as target:
            writer = csv.DictWriter(target, fieldnames=list(skip_rows[0]))
            writer.writeheader()
            writer.writerows(skip_rows)
    if long_gap_rows:
        with (OUTPUT / f"{name}-long-gaps.csv").open(
            "w", newline="", encoding="utf-8-sig"
        ) as target:
            writer = csv.DictWriter(target, fieldnames=list(long_gap_rows[0]))
            writer.writeheader()
            writer.writerows(long_gap_rows)
    return result


def print_comparison(old: dict, new: dict) -> None:
    def row(label: str, old_value, new_value) -> tuple[str, str, str]:
        return label, str(old_value), str(new_value)

    old_playback = old["playback"]
    new_playback = new["playback"]
    old_active = old_playback["update_frame_interval_us_active"]
    new_active = new_playback["update_frame_interval_us_active"]
    old_all = old_playback["update_frame_interval_us_all"]
    new_all = new_playback["update_frame_interval_us_all"]
    rows = [
        row("更新数", old_playback["update_count"], new_playback["update_count"]),
        row(
            "总跨度(s)",
            old_playback["duration_s"],
            new_playback["duration_s"],
        ),
        row(
            "连续播放合计(s)",
            old_playback["active_duration_s"],
            new_playback["active_duration_s"],
        ),
        row("连续段数", len(old_playback["segments"]), len(new_playback["segments"])),
        row("更新率(Hz)", old_playback["rate_hz_active"], new_playback["rate_hz_active"]),
        row("间隔P95(ms)", old_active["p95"] / 1000, new_active["p95"] / 1000),
        row("间隔P99(ms)", old_active["p99"] / 1000, new_active["p99"] / 1000),
        row("间隔最大(ms)", old_active["max"] / 1000, new_active["max"] / 1000),
        row(">20ms次数", old_active["gt20ms"], new_active["gt20ms"]),
        row(">40ms次数", old_active["gt40ms"], new_active["gt40ms"]),
        row(">100ms次数", old_active["gt100ms"], new_active["gt100ms"]),
        row(
            ">20ms/分钟",
            round(
                old_active["gt20ms"] / old_playback["active_duration_s"] * 60, 2
            ),
            round(
                new_active["gt20ms"] / new_playback["active_duration_s"] * 60, 2
            ),
        ),
        row(
            ">40ms/分钟",
            round(
                old_active["gt40ms"] / old_playback["active_duration_s"] * 60, 2
            ),
            round(
                new_active["gt40ms"] / new_playback["active_duration_s"] * 60, 2
            ),
        ),
        row(
            "全部间隔最大(ms)",
            old_all["max"] / 1000,
            new_all["max"] / 1000,
        ),
        row(
            "skip 数",
            old["skips"]["count"],
            new["skips"]["count"],
        ),
        row(
            "skip 前进<=1ms",
            old["skips"]["ahead_le_1000_us"],
            new["skips"]["ahead_le_1000_us"],
        ),
        row(
            "skip后推进截止",
            old["skips"]["problematic_deadline_advances"],
            new["skips"]["problematic_deadline_advances"],
        ),
        row(
            "Timer迟到P99(ms)",
            old["timer"]["lateness_us_active"]["p99"] / 1000,
            new["timer"]["lateness_us_active"]["p99"] / 1000,
        ),
        row(
            "Timer迟到最大(ms)",
            old["timer"]["lateness_us_active"]["max"] / 1000,
            new["timer"]["lateness_us_active"]["max"] / 1000,
        ),
        row(
            "Raster P99(ms)",
            old["frame_timing_active_us"]["raster"]["p99"] / 1000,
            new["frame_timing_active_us"]["raster"]["p99"] / 1000,
        ),
        row(
            "Raster >16.67ms",
            old["frame_timing_active_us"]["raster_gt_16_667ms"],
            new["frame_timing_active_us"]["raster_gt_16_667ms"],
        ),
        row(
            "Raster >20ms",
            old["frame_timing_active_us"]["raster_gt_20ms"],
            new["frame_timing_active_us"]["raster_gt_20ms"],
        ),
    ]
    widths = [
        max(len(str(item[index])) for item in rows + [("指标", "diagnostics-7", "diagnostics-8")])
        for index in range(3)
    ]
    print(
        f"{'指标':<{widths[0]}}  {'diagnostics-7':>{widths[1]}}  "
        f"{'diagnostics-8':>{widths[2]}}"
    )
    print(f"{'-' * widths[0]}  {'-' * widths[1]}  {'-' * widths[2]}")
    for item in rows:
        print(
            f"{item[0]:<{widths[0]}}  {item[1]:>{widths[1]}}  "
            f"{item[2]:>{widths[2]}}"
        )

    print("\ndiagnostics-8 长间隔（>20ms）")
    for gap in new["long_gaps"]:
        print(
            f"{gap['gap_ms']:>10.3f} ms  {gap['cause']}  "
            f"callbacks={gap['callbacks']} skips={gap['skips']} "
            f"advances={gap['skip_deadline_advances']} "
            f"timerLate={gap['max_timer_late_ms']:.1f}ms "
            f"batches={gap['danmaku_batches']} {gap['time']}"
        )
    print("\ndiagnostics-8 Raster >16.67ms（前5）")
    for frame in new["slow_raster_frames"][:5]:
        print(
            f"raster={frame['raster_ms']:.3f} ms build={frame['build_ms']:.3f} ms "
            f"{frame['time']}"
        )


def main() -> None:
    global OUTPUT
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--old",
        type=Path,
        default=ROOT / "doc/dev/diagnostics-7/raw/cadence.jsonl",
        help="baseline cadence.jsonl",
    )
    parser.add_argument(
        "--new",
        type=Path,
        default=ROOT / "doc/dev/diagnostics-8/raw/cadence.jsonl",
        help="candidate cadence.jsonl",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=ROOT / "build/frame-cadence-analysis",
        help="directory for summary.json and CSV outputs",
    )
    args = parser.parse_args()
    OUTPUT = args.output.resolve()
    OUTPUT.mkdir(parents=True, exist_ok=True)
    old = analyze("baseline", args.old.resolve())
    new = analyze("candidate", args.new.resolve())
    payload = {"old": old, "new": new}
    with (OUTPUT / "summary.json").open("w", encoding="utf-8") as target:
        json.dump(payload, target, ensure_ascii=False, indent=2)
    print_comparison(old, new)
    print(f"\n输出：{OUTPUT}")


if __name__ == "__main__":
    main()
