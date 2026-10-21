import unittest

from egl_frame_association import associate_swap, parse_engine_frames


class EngineFrameAssociationTest(unittest.TestCase):
    def test_missing_present_remains_missing(self):
        frames = parse_engine_frames([
            "submit 8 19 10000 40000 30000 20000 21000 1",
            "submit 9 20 20000 50000 40000 30000 31000 1",
            "present 8 401 290 350",
        ])
        self.assertEqual(associate_swap(frames, 20000, 21000)["vsyncId"], 19)
        self.assertIsNone(associate_swap(frames, 30000, 31000))
        self.assertEqual(frames[1]["present"], 0)

    def test_surface_rebuild_requires_explicit_segmentation(self):
        with self.assertRaisesRegex(ValueError, "Surface"):
            parse_engine_frames([
                "submit 1 1 100 400 300 200 210 1",
                "submit 1 2 200 500 400 300 310 1",
            ])


if __name__ == "__main__":
    unittest.main()
