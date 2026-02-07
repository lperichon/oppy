import io
import json
import os
import sys
import tempfile
import threading
import time
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import main as worker_main


class MainIntegrationTests(unittest.TestCase):
    def _write_config(self, folder: Path, wav_path: Path) -> Path:
        config_path = folder / "config.json"
        config_path.write_text(
            json.dumps(
                {
                    "session_id": "session-int-1",
                    "input_wav_path": str(wav_path),
                    "output_dir": str(folder),
                    "asr_model": "mlx-community/whisper-large-v3-turbo-asr-fp16",
                    "diarization_model": "pyannote/speaker-diarization-3.1",
                    "language": "auto",
                    "save_json": True,
                    "keep_wav": True,
                }
            )
        )
        return config_path

    def test_main_success_path_emits_events_and_writes_outputs(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            wav_path = root / "Meeting-20260206-120000.wav"
            wav_path.write_bytes(b"RIFF")
            config_path = self._write_config(root, wav_path)

            mocked_asr = {
                "text": "hello world",
                "duration_seconds": 3.5,
                "segments": [{"start": 0.0, "end": 3.0, "text": "hello world"}],
            }
            mocked_turns = [{"start": 0.0, "end": 3.5, "speaker": "SPEAKER_00"}]

            output_buffer = io.StringIO()
            with mock.patch.object(sys, "argv", ["main.py", "--config", str(config_path)]), mock.patch.dict(
                os.environ, {"HF_TOKEN": "hf_test_token"}, clear=False
            ), mock.patch.object(
                worker_main, "transcribe_with_mlx", return_value=mocked_asr
            ), mock.patch.object(
                worker_main, "diarize_with_pyannote", return_value=mocked_turns
            ), redirect_stdout(output_buffer):
                exit_code = worker_main.main()

            self.assertEqual(exit_code, 0)

            lines = [json.loads(line) for line in output_buffer.getvalue().splitlines() if line.strip()]
            progress_stages = [line.get("stage") for line in lines if line.get("type") == "progress"]
            self.assertEqual(progress_stages, ["mix", "asr", "diarization", "merge", "export"])

            result = next(line for line in lines if line.get("type") == "result")
            self.assertTrue(result["success"])
            transcript_path = Path(result["transcript_path"])
            json_path = Path(result["json_path"])
            self.assertTrue(transcript_path.exists())
            self.assertTrue(json_path.exists())
            self.assertIn("Speaker 1", transcript_path.read_text())

    def test_main_returns_token_error_before_pipeline_calls(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            wav_path = root / "Meeting-20260206-120001.wav"
            wav_path.write_bytes(b"RIFF")
            config_path = self._write_config(root, wav_path)

            output_buffer = io.StringIO()
            with mock.patch.object(sys, "argv", ["main.py", "--config", str(config_path)]), mock.patch.dict(
                os.environ, {"HF_TOKEN": ""}, clear=False
            ), mock.patch.object(
                worker_main, "transcribe_with_mlx"
            ) as asr_mock, redirect_stdout(output_buffer):
                exit_code = worker_main.main()

            self.assertEqual(exit_code, 1)
            asr_mock.assert_not_called()

            lines = [json.loads(line) for line in output_buffer.getvalue().splitlines() if line.strip()]
            result = next(line for line in lines if line.get("type") == "result")
            self.assertFalse(result["success"])
            self.assertEqual(result["error_code"], "HF_TOKEN_MISSING")

    def test_main_falls_back_when_diarization_fails(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            wav_path = root / "Meeting-20260206-120002.wav"
            wav_path.write_bytes(b"RIFF")
            config_path = self._write_config(root, wav_path)

            mocked_asr = {
                "text": "fallback example",
                "duration_seconds": 2.0,
                "segments": [{"start": 0.0, "end": 2.0, "text": "fallback example"}],
            }

            output_buffer = io.StringIO()
            with mock.patch.object(sys, "argv", ["main.py", "--config", str(config_path)]), mock.patch.dict(
                os.environ, {"HF_TOKEN": "hf_test_token"}, clear=False
            ), mock.patch.object(
                worker_main, "transcribe_with_mlx", return_value=mocked_asr
            ), mock.patch.object(
                worker_main, "diarize_with_pyannote", side_effect=RuntimeError("diarization service down")
            ), redirect_stdout(output_buffer):
                exit_code = worker_main.main()

            self.assertEqual(exit_code, 0)

            lines = [json.loads(line) for line in output_buffer.getvalue().splitlines() if line.strip()]
            result = next(line for line in lines if line.get("type") == "result")
            self.assertTrue(result["success"])
            self.assertIn("diarization fallback", result.get("message", ""))

            transcript_path = Path(result["transcript_path"])
            content = transcript_path.read_text()
            self.assertIn("Speaker ?", content)

    def test_main_should_not_hang_when_asr_load_blocks(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            wav_path = root / "Meeting-20260206-120003.wav"
            wav_path.write_bytes(b"RIFF")
            config_path = self._write_config(root, wav_path)

            mocked_turns = [{"start": 0.0, "end": 1.0, "speaker": "SPEAKER_00"}]
            mocked_asr = {
                "text": "released",
                "duration_seconds": 1.0,
                "segments": [{"start": 0.0, "end": 1.0, "text": "released"}],
            }

            entered_asr = threading.Event()
            release_asr = threading.Event()
            output_buffer = io.StringIO()

            def blocking_asr(*_args, **_kwargs):
                entered_asr.set()
                self.assertTrue(
                    release_asr.wait(timeout=2),
                    "Test control bug: ASR release event was never set",
                )
                return mocked_asr

            with mock.patch.object(sys, "argv", ["main.py", "--config", str(config_path)]), mock.patch.dict(
                os.environ,
                {
                    "HF_TOKEN": "hf_test_token",
                    "OPPY_ASR_TIMEOUT_SECONDS": "0.1",
                },
                clear=False,
            ), mock.patch.object(
                worker_main, "transcribe_with_mlx", side_effect=blocking_asr
            ), mock.patch.object(
                worker_main, "diarize_with_pyannote", return_value=mocked_turns
            ), redirect_stdout(output_buffer):
                result_holder = {}

                def run_worker_main():
                    result_holder["exit_code"] = worker_main.main()

                worker_thread = threading.Thread(target=run_worker_main)
                worker_thread.start()
                try:
                    self.assertTrue(entered_asr.wait(timeout=1), "ASR stage was not reached")
                    time.sleep(0.2)

                    # Desired behavior: worker should fail fast instead of hanging forever.
                    worker_thread.join(timeout=0.1)
                    self.assertFalse(worker_thread.is_alive(), "Worker hung in ASR stage instead of timing out")

                    lines = [json.loads(line) for line in output_buffer.getvalue().splitlines() if line.strip()]
                    result = next((line for line in lines if line.get("type") == "result"), None)
                    self.assertIsNotNone(result, "Worker should emit a result when ASR times out")
                    self.assertFalse(result["success"])
                    self.assertEqual(result["error_code"], "ASR_TIMEOUT")
                finally:
                    release_asr.set()
                    worker_thread.join(timeout=1)

    def test_bootstrap_asr_emits_ready_result(self):
        mocked_asr = {
            "text": "warm",
            "duration_seconds": 0.25,
            "segments": [{"start": 0.0, "end": 0.25, "text": "warm"}],
        }

        output_buffer = io.StringIO()
        with mock.patch.object(
            sys,
            "argv",
            [
                "main.py",
                "--bootstrap-asr",
                "--asr-model",
                "mlx-community/whisper-large-v3-turbo-asr-fp16",
                "--language",
                "auto",
            ],
        ), mock.patch.object(
            worker_main, "transcribe_with_mlx", return_value=mocked_asr
        ), redirect_stdout(output_buffer):
            exit_code = worker_main.main()

        self.assertEqual(exit_code, 0)
        lines = [json.loads(line) for line in output_buffer.getvalue().splitlines() if line.strip()]
        progress = [line for line in lines if line.get("type") == "progress"]
        self.assertEqual(progress[0]["stage"], "asr_bootstrap")
        result = next(line for line in lines if line.get("type") == "result")
        self.assertTrue(result["success"])
        self.assertIn("ASR model ready", result.get("message", ""))

    def test_bootstrap_asr_requires_model_name(self):
        output_buffer = io.StringIO()
        with mock.patch.object(sys, "argv", ["main.py", "--bootstrap-asr"]), redirect_stdout(output_buffer):
            exit_code = worker_main.main()

        self.assertEqual(exit_code, 1)
        lines = [json.loads(line) for line in output_buffer.getvalue().splitlines() if line.strip()]
        result = next(line for line in lines if line.get("type") == "result")
        self.assertFalse(result["success"])
        self.assertEqual(result["error_code"], "ASR_MODEL_MISSING")


if __name__ == "__main__":
    unittest.main()
