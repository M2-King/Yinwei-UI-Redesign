"""Pure diagnostic checks. Does not load a DLL or open an audio device."""
import unittest
from check_array_file_tap import metrics, verdict


class ProbeChecks(unittest.TestCase):
    def test_binaural_azimuth_and_muting_both_required(self):
        samples = {"left": metrics([(0.5, 0.1)] * 512),
                   "right": metrics([(0.1, 0.5)] * 512),
                   "muted": metrics([(0.0, 0.0)] * 512)}
        self.assertEqual(verdict(samples)["result"], "PASS")
        samples["muted"] = samples["right"]
        self.assertEqual(verdict(samples)["result"], "FAIL_OR_INCONCLUSIVE")

    def test_pre_array_tap_and_silence_cannot_pass(self):
        for frames in [[(0.2, 0.2)] * 512, [(0.0, 0.0)] * 512]:
            samples = {k: metrics(frames) for k in ("left", "right", "muted")}
            self.assertEqual(verdict(samples)["result"], "FAIL_OR_INCONCLUSIVE")
        with self.assertRaises(RuntimeError):
            metrics([])


if __name__ == "__main__":
    unittest.main()
