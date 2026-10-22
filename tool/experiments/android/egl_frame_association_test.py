import unittest

from egl_frame_association import associate_swap, parse_frames


class EglFrameAssociationTest(unittest.TestCase):
    def test_future_timestamp_and_trace_boundary_rounding(self):
        frames = parse_frames([
            "vsync 100 200 190 7 105",
            "frame 565 1000000 1800000 2000000 24000000 23000000 1 "
            "24000010 1900000 21000000",
        ])
        # 实机漏配模式：trace 比 native 记录的结束多出 51ns。
        frame = associate_swap(frames, 1002917, 1800051)
        self.assertEqual(frame["id"], 565)
        self.assertEqual(frame["present"], 24000010)
        self.assertGreater(frame["desired"], frame["end"])

    def test_ambiguous_or_unpresented_frame_stays_unmatched(self):
        frames = parse_frames(["frame 3 10000 20000 30000 40000 39000 1 -2 0 0"])
        self.assertIsNone(associate_swap(frames, 11000, 19000))
        frames[0]["present"] = 40000
        self.assertIsNone(associate_swap(frames * 2, 11000, 19000))
        self.assertIsNone(associate_swap(frames, 11000, 22000))

    def test_incomplete_record_is_rejected(self):
        with self.assertRaises(ValueError):
            parse_frames(["frame 3 10000 20000"])


if __name__ == "__main__":
    unittest.main()
