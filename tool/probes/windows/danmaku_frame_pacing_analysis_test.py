import tempfile
import unittest
from pathlib import Path

from danmaku_frame_pacing_analysis import continuity_module, judge, match_stage, process, read_presents


def fixture():
    stage = {
        'clockCalibration': {'qpcBefore': 1000000, 'qpcAfter': 1000000,
                             'frequency': 1000000, 'timelineUs': 1000000},
        'frames': [{'frameNumber': i + 10, 'targetUs': 1000000 + i * 10000,
                    'positionUs': i * 10000} for i in range(12)],
        'timings': [{'frameNumber': i + 10, 'rasterStartUs': 1001000 + i * 10000,
                     'rasterFinishUs': 1002000 + i * 10000} for i in range(12)],
    }
    presents = [{'qpc': 1001500 + i * 10000, 'displayMs': 5,
                 'dropped': False, 'swapChain': 'one', 'key': str(i)} for i in range(12)]
    return stage, presents


class FramePacingAnalysisTest(unittest.TestCase):
    def test_clock_offset_and_frame_numbers_match_exact_raster_interval(self):
        stage, presents = fixture()
        stage['clockCalibration']['timelineUs'] += 123
        for frame in stage['frames']:
            frame['targetUs'] += 123
        for timing in stage['timings']:
            timing['rasterStartUs'] += 123
            timing['rasterFinishUs'] += 123
        matched, counts = match_stage(stage, presents)
        self.assertEqual(counts['matchedFraction'], 1)
        self.assertEqual(matched[0]['presentNs'], 1006623000)
        self.assertEqual(matched[0]['frameNumber'], 10)
        summary = continuity_module().analyze(matched)['summary']
        self.assertTrue(judge(summary, counts, True))
        self.assertFalse(judge(summary, counts, False))

    def test_dropped_missing_and_ambiguous_frames_are_not_filled(self):
        stage, presents = fixture()
        presents[3]['dropped'] = True
        del stage['timings'][5]
        presents.append({**presents[7], 'key': 'duplicate', 'swapChain': 'two'})
        matched, counts = match_stage(stage, presents)
        self.assertEqual([f['index'] for f in matched], [0, 1, 2, 4, 6, 8, 9, 10, 11])
        self.assertEqual(counts['dropped'], 1)
        self.assertEqual(counts['presentMatched'], 10)
        self.assertEqual(counts['missingTiming'], 1)
        self.assertEqual(counts['ambiguousPresent'], 1)
        summary = continuity_module().analyze(matched)['summary']
        self.assertEqual(summary['segmentLengths'], [3, 1, 1, 4])
        self.assertFalse(judge(summary, counts, True))

    def test_compensating_display_intervals_fail_all_three_radii(self):
        stage, presents = fixture()
        for i, event in enumerate(presents):
            event['displayMs'] += 2 if i % 2 else 0
        matched, counts = match_stage(stage, presents)
        summary = continuity_module().analyze(matched)['summary']
        self.assertFalse(judge(summary, counts, True))
        for radius in ('1', '2', '3'):
            self.assertGreater(summary['centeredWindows'][radius]['velocityRms']['p95'], .1)

    def test_nearby_present_outside_raster_is_not_used(self):
        stage, presents = fixture()
        presents[0]['qpc'] += 1000
        matched, counts = match_stage(stage, presents)
        self.assertEqual(counts['missingPresent'], 1)
        self.assertEqual(matched[0]['index'], 1)

    def test_extra_native_display_cannot_be_hidden_by_perfect_ui_frames(self):
        stage, presents = fixture()
        presents.append({**presents[3], 'qpc': 1035000, 'key': 'native-repeat'})
        matched, counts = match_stage(stage, presents)
        self.assertEqual(counts['matchedFraction'], 1)
        self.assertEqual(counts['unassociatedDisplayedPresents'], 1)
        self.assertAlmostEqual(counts['displayedCoverage'], 12 / 13)
        summary = continuity_module().analyze(matched)['summary']
        self.assertFalse(judge(summary, counts, True))

    def test_csv_requires_qpc_and_reads_dropped_rows(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'presents.csv'
            path.write_text('QPCTime,msUntilDisplayed,Dropped,SwapChainAddress\n1000,0,1,one\n', encoding='utf-8')
            self.assertTrue(read_presents(path)[0]['dropped'])
            path.write_text('TimeInSeconds,msUntilDisplayed\n1,2\n', encoding='utf-8')
            with self.assertRaises(ValueError):
                read_presents(path)

    def test_failed_probe_without_stages_still_writes_failure_summary(self):
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder)
            result = process({'passed': False, 'videoBackground': False, 'stages': []}, [], output)
            self.assertFalse(result['passed'])
            self.assertIn('未通过', (output / 'summary.md').read_text(encoding='utf-8'))
            self.assertTrue((output / 'summary.csv').exists())


if __name__ == '__main__':
    unittest.main()
