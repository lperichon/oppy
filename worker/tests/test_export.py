import json
import tempfile
import unittest
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from pipeline.export import export_outputs


class ExportTests(unittest.TestCase):
    def test_writes_markdown_and_json_outputs(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            output_dir = Path(temp_dir)
            wav_path = output_dir / "Meeting-20260206-101010.wav"
            wav_path.write_bytes(b"RIFF")

            paths = export_outputs(
                output_dir=str(output_dir),
                session_id="session-1",
                input_wav_path=str(wav_path),
                model_name="mlx-community/whisper-large-v3-turbo-asr-fp16",
                diarization_model="pyannote/speaker-diarization-3.1",
                language="auto",
                merged_segments=[
                    {"start": 0.0, "end": 1.0, "speaker": "Speaker 1", "text": "hello"},
                    {"start": 75.0, "end": 80.0, "speaker": "Speaker 2", "text": "all good"},
                ],
                full_text="hello all good",
                duration_seconds=80.0,
                save_json=True,
            )

            transcript_path = Path(paths["transcript_path"])
            self.assertTrue(transcript_path.exists())
            content = transcript_path.read_text()
            self.assertIn("[00:00] Speaker 1: hello", content)
            self.assertIn("[01:15] Speaker 2: all good", content)

            json_path = Path(paths["json_path"])
            self.assertTrue(json_path.exists())
            payload = json.loads(json_path.read_text())
            self.assertEqual(payload["session_id"], "session-1")
            self.assertEqual(len(payload["segments"]), 2)


if __name__ == "__main__":
    unittest.main()
