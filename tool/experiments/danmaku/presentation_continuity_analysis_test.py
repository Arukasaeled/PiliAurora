import unittest

from presentation_continuity_analysis import analyze


def fixture(gaps_us, rate=1):
    present_us = 100000
    frames = [{"index": 0, "targetUs": 0, "presentNs": present_us * 1000, "positionUs": 0}]
    for index, gap_us in enumerate(gaps_us, 1):
        present_us += gap_us
        frames.append({"index": index, "targetUs": index * 20000,
                       "presentNs": present_us * 1000, "positionUs": index * 20000 * rate})
    return frames


class PresentationContinuityAnalysisTest(unittest.TestCase):
    def test_compensating_gaps_keep_local_spikes_at_all_radii(self):
        result = analyze(fixture([30000, 10000] * 4))
        for radius, expected_count in ((1, 7), (2, 5), (3, 3)):
            summary = result["summary"]["centeredWindows"][str(radius)]
            self.assertEqual(summary["windows"], expected_count)
            self.assertAlmostEqual(summary["netVelocityRatio"]["mean"], 1)
            self.assertAlmostEqual(summary["gapRelativeRms"]["mean"], 0.5)
            self.assertAlmostEqual(summary["velocityRms"]["mean"], (5 / 9) ** 0.5)
            self.assertAlmostEqual(summary["phaseSpanMs"]["mean"], 10)
        # 隔两帧重复的间隔差分为零，窗口内波动仍然保留。
        self.assertEqual(result["summary"]["lagChanges"]["2"]["absGapRelativeChange"]["max"], 0)
        self.assertGreater(result["summary"]["lagChanges"]["1"]["absGapRelativeChange"]["min"], 0)

    def test_sustained_drift_is_distinct_from_zero_cv(self):
        result = analyze(fixture([25000] * 8))
        for distance in (1, 2, 3):
            summary = result["summary"]["lagSpans"][str(distance)]
            self.assertEqual(summary["pairs"], 9 - distance)
            self.assertEqual(summary["phaseChangeMs"]["mean"], 5 * distance)
            self.assertEqual(summary["velocityRatio"]["mean"], 0.8)
        window = result["summary"]["centeredWindows"]["3"]
        self.assertEqual(window["gapCv"]["max"], 0)
        self.assertEqual(window["gapRelativeRms"]["mean"], 0.25)
        self.assertEqual(window["phaseSpanMs"]["mean"], 30)

    def test_missing_frame_and_seek_split_windows_without_padding(self):
        for boundary in ("index", "positionUs", "presentNs", "targetUs"):
            with self.subTest(boundary=boundary):
                frames = fixture([20000] * 9)
                if boundary == "index":
                    for frame in frames[5:]:
                        frame["index"] += 1
                else:
                    offset = frames[5][boundary]
                    for frame in frames[5:]:
                        frame[boundary] -= offset
                result = analyze(frames)
                self.assertEqual(result["summary"]["segmentLengths"], [5, 5])
                self.assertEqual(result["summary"]["centeredWindows"]["1"]["windows"], 6)
                self.assertEqual(result["summary"]["centeredWindows"]["2"]["windows"], 2)
                self.assertEqual(result["summary"]["centeredWindows"]["3"]["windows"], 0)
                self.assertEqual(result["summary"]["lagSpans"]["3"]["pairs"], 4)

    def test_rate_and_variable_targets_keep_constant_delay_free_of_jitter(self):
        frames = fixture([20000] * 8, rate=2)
        for frame in frames:
            target_us = frame["index"] // 2 * 30000 + frame["index"] % 2 * 10000
            frame.update(targetUs=target_us, positionUs=target_us * 2,
                         presentNs=(target_us + 100000) * 1000)
        result = analyze(frames, rate=2)
        for radius in (1, 2, 3):
            summary = result["summary"]["centeredWindows"][str(radius)]
            self.assertEqual(summary["velocityRms"]["max"], 0)
            self.assertEqual(summary["phaseSpanMs"]["max"], 0)
        self.assertAlmostEqual(result["summary"]["centeredWindows"]["1"]["gapCv"]["mean"], 1 / 3)


if __name__ == "__main__":
    unittest.main()
