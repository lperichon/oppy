import tempfile
import unittest
from pathlib import Path

import numpy as np
import soundfile as sf

import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from pipeline.input_mix import maybe_mix_microphone_track


class InputMixTests(unittest.TestCase):
    def test_returns_original_path_when_no_mic_track(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            base = Path(temp_dir) / "Meeting-1.wav"
            sf.write(str(base), np.zeros(1600, dtype=np.float32), 16000)

            result = maybe_mix_microphone_track(str(base))
            self.assertEqual(result, str(base))

    def test_mixes_mic_track_into_system_audio(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            base = Path(temp_dir) / "Meeting-2.wav"
            mic = Path(temp_dir) / "Meeting-2.mic.wav"

            sf.write(str(base), np.full(1600, 0.2, dtype=np.float32), 16000)
            sf.write(str(mic), np.full(800, 0.4, dtype=np.float32), 8000)

            maybe_mix_microphone_track(str(base))
            mixed, sample_rate = sf.read(str(base), always_2d=False)

            self.assertEqual(sample_rate, 16000)
            self.assertGreater(float(np.max(mixed)), 0.2)
            self.assertLessEqual(float(np.max(np.abs(mixed))), 1.0)


if __name__ == "__main__":
    unittest.main()
