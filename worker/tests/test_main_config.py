import json
import tempfile
import unittest
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import main as worker_main


class MainConfigTests(unittest.TestCase):
    def test_load_config_applies_defaults(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            config_path = Path(temp_dir) / "config.json"
            config_path.write_text(
                json.dumps(
                    {
                        "session_id": "s1",
                        "input_wav_path": "/tmp/audio.wav",
                        "output_dir": "/tmp",
                        "asr_model": "mlx-community/whisper-large-v3-turbo-asr-fp16",
                        "diarization_model": "pyannote/speaker-diarization-3.1",
                    }
                )
            )

            config = worker_main.load_config(config_path)

            self.assertEqual(config.language, "auto")
            self.assertFalse(config.save_json)
            self.assertTrue(config.keep_wav)


if __name__ == "__main__":
    unittest.main()
