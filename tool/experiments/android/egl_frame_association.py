"""关联 EGL 帧 ID 与同一次 swap 的 Perfetto 区间，保留实际呈现时间。"""

from collections.abc import Iterable


def parse_frames(lines: Iterable[str]) -> list[dict[str, int]]:
    fields = (
        "id", "start", "end", "target", "expected", "desired", "set",
        "present", "ready", "latch",
    )
    frames = []
    for line in lines:
        if not line.startswith("frame "):
            continue
        values = [int(value) for value in line.split()[1:]]
        if len(values) != len(fields):
            raise ValueError("EGL 帧记录字段不完整")
        frame = dict(zip(fields, values))
        if frame["end"] < frame["start"]:
            raise ValueError("EGL swap 区间倒退")
        frames.append(frame)
    return frames


def parse_engine_frames(lines: Iterable[str]) -> list[dict[str, int]]:
    """读取正式引擎的提交/完成记录；缺失呈现保留为0，不推算时间戳。"""
    frames: dict[int, dict[str, int]] = {}
    completed: dict[int, tuple[int, int, int]] = {}
    for line in lines:
        if line.startswith("submit "):
            frame_id, vsync_id, start, expected, deadline, before, after, success = (
                int(value) for value in line.split()[1:]
            )
            if frame_id in frames:
                raise ValueError("捕获包含重复 EGL 帧 ID，需按 Surface 代次分段")
            if after < before:
                raise ValueError("EGL swap 区间倒退")
            frames[frame_id] = dict(
                id=frame_id, start=before, end=after, target=expected,
                expected=expected, desired=0, set=0, present=0, ready=0,
                latch=0, vsyncId=vsync_id, frameStart=start,
                deadline=deadline, success=success,
            )
        elif line.startswith("present "):
            frame_id, present, ready, latch = (
                int(value) for value in line.split()[1:]
            )
            if frame_id in completed:
                raise ValueError("同一 EGL 帧存在重复完成记录")
            completed[frame_id] = (present, ready, latch)
    for frame_id, frame in frames.items():
        if frame_id in completed:
            frame["present"], frame["ready"], frame["latch"] = completed[frame_id]
    return list(frames.values())


def associate_swap(
    frames: Iterable[dict[str, int]], start_ns: int, end_ns: int,
) -> dict[str, int] | None:
    # 两路单调时钟读数与 atrace 边界存在几十纳秒差异；未来 desired
    # 不在 swap 内，必须沿记录过的 swap 区间关联 frameId。
    boundary_tolerance_ns = 1000
    candidates = [
        frame for frame in frames
        if frame["start"] <= start_ns + boundary_tolerance_ns
        and end_ns <= frame["end"] + boundary_tolerance_ns
    ]
    if len(candidates) != 1 or candidates[0]["present"] <= 0:
        return None
    return candidates[0]
