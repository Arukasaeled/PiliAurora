#!/usr/bin/env python3
"""关联 Flutter 帧与 PresentMon v1 QPC 记录，复用 ±1/±2/±3 连续性分析。"""

from __future__ import annotations

import argparse
import bisect
import csv
import importlib.util
import json
from collections import Counter
from pathlib import Path


def continuity_module():
    source = Path(__file__).resolve().parents[2] / 'experiments/danmaku/presentation_continuity_analysis.py'
    spec = importlib.util.spec_from_file_location('presentation_continuity_analysis', source)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def match_stage(stage: dict, presents: list[dict]) -> tuple[list[dict], dict]:
    calibration = stage['clockCalibration']
    frequency = calibration['frequency']
    qpc_midpoint = (calibration['qpcBefore'] + calibration['qpcAfter']) / 2
    offset_us = calibration['timelineUs'] - qpc_midpoint * 1e6 / frequency
    uncertainty_us = (calibration['qpcAfter'] - calibration['qpcBefore']) * 1e6 / frequency / 2
    # 保留 QPC 和 Timeline 微秒量化误差，不放宽到相邻帧。
    tolerance_us = uncertainty_us + 2
    events = sorted([
        {**p, 'startUs': p['qpc'] * 1e6 / frequency + offset_us}
        for p in presents
    ], key=lambda p: p['startUs'])
    starts = [p['startUs'] for p in events]
    timings = {t['frameNumber']: t for t in stage['timings']}
    matched = []
    counts = {'missingTiming': 0, 'missingPresent': 0, 'ambiguousPresent': 0, 'dropped': 0,
              'missingPosition': 0, 'reusedPresent': 0}
    used = set()
    displayed_used = set()
    for index, frame in enumerate(stage['frames']):
        timing = timings.get(frame['frameNumber'])
        if timing is None:
            counts['missingTiming'] += 1
            continue
        left = bisect.bisect_left(starts, timing['rasterStartUs'] - tolerance_us)
        right = bisect.bisect_right(starts, timing['rasterFinishUs'] + tolerance_us)
        candidates = events[left:right]
        if not candidates:
            counts['missingPresent'] += 1
            continue
        if len(candidates) != 1:
            counts['ambiguousPresent'] += 1
            continue
        event = candidates[0]
        if event['key'] in used:
            counts['reusedPresent'] += 1
            continue
        used.add(event['key'])
        if event['dropped'] or event['displayMs'] <= 0:
            counts['dropped'] += 1
            continue
        if frame['positionUs'] is None:
            counts['missingPosition'] += 1
            continue
        matched.append({
            'index': index,
            'frameNumber': frame['frameNumber'],
            'targetUs': frame['targetUs'],
            'positionUs': frame['positionUs'],
            'presentNs': round((event['startUs'] + event['displayMs'] * 1000) * 1000),
            'presentQpc': event['qpc'],
            'swapChain': event['swapChain'],
            'presentMode': event.get('presentMode', 'unknown'),
        })
        displayed_used.add(event['key'])
    sampled_timings = [timings[f['frameNumber']] for f in stage['frames']
                       if f['frameNumber'] in timings]
    displayed = []
    if sampled_timings:
        start = min(t['rasterStartUs'] for t in sampled_timings) - tolerance_us
        end = max(t['rasterFinishUs'] for t in sampled_timings) + tolerance_us
        displayed = [e for e in events if start <= e['startUs'] <= end
                     and not e['dropped'] and e['displayMs'] > 0]
    return matched, {
        'frames': len(stage['frames']), 'matched': len(matched),
        'matchedFraction': len(matched) / max(1, len(stage['frames'])),
        'presentMatched': len(used),
        'presentMatchedFraction': len(used) / max(1, len(stage['frames'])),
        'displayedPresents': len(displayed),
        'presentModes': dict(Counter(e.get('presentMode', 'unknown') for e in displayed)),
        'unassociatedDisplayedPresents': sum(e['key'] not in displayed_used for e in displayed),
        'displayedCoverage': len(displayed_used) / max(1, len(displayed)),
        'calibrationUncertaintyUs': uncertainty_us, **counts,
    }


def read_presents(path: Path) -> list[dict]:
    with path.open(encoding='utf-8-sig', newline='') as source:
        reader = csv.DictReader(source)
        required = {'QPCTime', 'msUntilDisplayed', 'Dropped', 'SwapChainAddress'}
        if not required.issubset(reader.fieldnames or []):
            raise ValueError('PresentMon 需要 --v1_metrics --qpc_time；缺失字段：' +
                             ', '.join(sorted(required - set(reader.fieldnames or []))))
        return [
            {'qpc': int(row['QPCTime']), 'displayMs': float(row['msUntilDisplayed']),
             'dropped': row['Dropped'] != '0', 'swapChain': row['SwapChainAddress'],
             'presentMode': row.get('PresentMode', 'unknown'),
             'key': (row['QPCTime'], row['SwapChainAddress'])}
            for row in reader
        ]


def judge(summary: dict, association: dict, scheduler_passed: bool) -> bool:
    windows = summary['centeredWindows'].values()
    return (scheduler_passed and association['matchedFraction'] >= .95 and
            association['displayedCoverage'] >= .99 and all(
        w['windows'] > 0 and w['velocityRms']['p95'] <= .1 and
        w['withOutside10pct'] < w['windows'] * .01 for w in windows
    ))


def process(probe: dict, presents: list[dict], output: Path) -> dict:
    analyze = continuity_module().analyze
    rows = []
    for index, stage in enumerate(probe['stages']):
        matched, association = match_stage(stage, presents)
        result = analyze(matched)
        result['source'] = {'run': 'windows', 'stage': index, 'target': stage['refreshHz'],
                            'mode': stage['mode'], 'requestedCount': stage['requestedCount'],
                            'timeSource': 'PresentMon QPCTime + msUntilDisplayed'}
        result['association'] = association
        result['passed'] = judge(result['summary'], association, stage['passed'])
        (output / f'presentation-stage-{index}.json').write_text(json.dumps({
            'summary': result['source'], 'matched': matched,
        }, ensure_ascii=False), encoding='utf-8')
        (output / f'continuity-stage-{index}.json').write_text(json.dumps(result, ensure_ascii=False), encoding='utf-8')
        rows.append({'stage': index, 'mode': stage['mode'], 'requestedCount': stage['requestedCount'],
                     'fps': stage['fps'], 'schedulerPassed': stage['passed'], 'passed': result['passed'],
                     'association': association, 'summary': result['summary']})
    summary = {'passed': probe['passed'] and len(rows) == 4 and all(r['passed'] for r in rows),
               'videoBackground': probe['videoBackground'], 'stages': rows,
               'criteria': {'minimumMatchedFraction': .95, 'minimumDisplayedCoverage': .99,
                            'maximumVelocityRmsP95': .1,
                            'maximumWindowsWithOutside10pctFraction': .01}}
    (output / 'summary.json').write_text(json.dumps(summary, indent=2, ensure_ascii=False), encoding='utf-8')
    csv_rows = []
    lines = ['# Windows 弹幕帧连续性', '',
             f'判定：{"通过" if summary["passed"] else "未通过"}；视频背景：{probe["videoBackground"]}。', '',
             '时间来源：PresentMon 实际呈现事件，经 QPC 校准、Flutter 帧编号及 Raster 时间段关联。',
             '未匹配、丢帧、重复或歧义事件不补点；缺帧会截断局部窗口。',
             '另核对全部显示事件的覆盖率，避免漏计原生纹理复用旧画面的额外呈现。', '',
             '| 场景 | 输入 | FPS | 已显示关联率 | 显示事件覆盖率 | 窗口 | 速度RMS P95 | 超10%窗口 | 相位极差P95(ms) |',
             '| --- | ---: | ---: | ---: | ---: | --- | ---: | ---: | ---: |']
    for row in rows:
        print(f'{row["mode"]} {row["requestedCount"]}: matched={row["association"]["matchedFraction"]:.2%}, passed={row["passed"]}')
        for radius, w in row['summary']['centeredWindows'].items():
            rms_p95 = w['velocityRms'].get('p95')
            phase_p95 = w['phaseSpanMs'].get('p95')
            outside = w['withOutside10pct'] / max(1, w['windows'])
            csv_rows.append({'stage': row['stage'], 'mode': row['mode'], 'input': row['requestedCount'],
                             'schedulerPassed': row['schedulerPassed'],
                             'matchedFraction': row['association']['matchedFraction'],
                             'displayedCoverage': row['association']['displayedCoverage'],
                             'presentModes': '; '.join(sorted(row['association']['presentModes'])),
                             'radius': radius, 'windows': w['windows'], 'velocityRmsP95': rms_p95,
                             'outside10pctFraction': outside, 'phaseSpanMsP95': phase_p95,
                             'gapRelativeRmsP95': w['gapRelativeRms'].get('p95'),
                             'netVelocityRatioP95': w['netVelocityRatio'].get('p95')})
            rms_text = 'NA' if rms_p95 is None else f'{rms_p95:.3%}'
            phase_text = 'NA' if phase_p95 is None else f'{phase_p95:.4f}'
            lines.append(f'| {row["mode"]} | {row["requestedCount"]} | {row["fps"]:.2f} | '
                         f'{row["association"]["matchedFraction"]:.2%} | '
                         f'{row["association"]["displayedCoverage"]:.2%} | ±{radius} | '
                         f'{rms_text} | {outside:.2%} | {phase_text} |')
    lines += ['', '呈现路径：' + '；'.join(
        f'{row["mode"]}/{row["requestedCount"]}=' + ', '.join(sorted(row['association']['presentModes']))
        for row in rows
    ) + '。', '', '判定要求：调度检查通过、关联率≥95%、显示事件覆盖率≥99%；三个半径均有完整窗口，速度RMS P95≤10%，'
              '含单步速度偏差超过10%的窗口比例<1%。详细间隔RMS、跨帧跨度和差分见每阶段 JSON。', '',
              '采样使用合成点播时钟及本地消息；视频背景检查合成负载，未覆盖真实媒体时钟校准或超分。']
    (output / 'summary.md').write_text('\n'.join(lines) + '\n', encoding='utf-8')
    with (output / 'summary.csv').open('w', encoding='utf-8-sig', newline='') as target:
        writer = csv.DictWriter(target, fieldnames=[
            'stage', 'mode', 'input', 'schedulerPassed', 'matchedFraction', 'displayedCoverage', 'presentModes',
            'radius', 'windows', 'velocityRmsP95',
            'outside10pctFraction', 'phaseSpanMsP95', 'gapRelativeRmsP95', 'netVelocityRatioP95',
        ])
        writer.writeheader()
        writer.writerows(csv_rows)
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('probe', type=Path)
    parser.add_argument('presentmon', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    summary = process(json.loads(args.probe.read_text(encoding='utf-8')), read_presents(args.presentmon), args.output)
    raise SystemExit(0 if summary['passed'] else 1)


if __name__ == '__main__':
    main()
