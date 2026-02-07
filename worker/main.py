import argparse
import json
import os
import sys
import tempfile
import threading
import wave
from dataclasses import dataclass
from pathlib import Path

from pipeline.asr import transcribe_with_mlx
from pipeline.diarization import diarize_with_pyannote
from pipeline.export import export_outputs
from pipeline.input_mix import maybe_mix_microphone_track
from pipeline.merge import merge_segments_with_speakers


@dataclass
class WorkerConfig:
    session_id: str
    input_wav_path: str
    output_dir: str
    asr_model: str
    diarization_model: str
    language: str
    save_json: bool
    keep_wav: bool


def emit_progress(stage: str, message: str) -> None:
    print(json.dumps({"type": "progress", "stage": stage, "message": message}), flush=True)


def emit_result(success: bool, **kwargs) -> None:
    payload = {"type": "result", "success": success, **kwargs}
    print(json.dumps(payload), flush=True)


def load_config(config_path: Path) -> WorkerConfig:
    data = json.loads(config_path.read_text())
    return WorkerConfig(
        session_id=data["session_id"],
        input_wav_path=data["input_wav_path"],
        output_dir=data["output_dir"],
        asr_model=data["asr_model"],
        diarization_model=data["diarization_model"],
        language=data.get("language", "auto"),
        save_json=bool(data.get("save_json", False)),
        keep_wav=bool(data.get("keep_wav", True)),
    )


def _create_bootstrap_wav() -> str:
    sample_rate = 16_000
    duration_seconds = 0.25
    sample_count = int(sample_rate * duration_seconds)
    silence = b"\x00\x00" * sample_count

    with tempfile.NamedTemporaryFile(prefix="oppy-asr-bootstrap-", suffix=".wav", delete=False) as temp_file:
        wav_path = temp_file.name

    with wave.open(wav_path, "wb") as wav_file:
        wav_file.setnchannels(1)
        wav_file.setsampwidth(2)
        wav_file.setframerate(sample_rate)
        wav_file.writeframes(silence)

    return wav_path


def bootstrap_asr_model(asr_model: str, language: str) -> int:
    model_name = asr_model.strip()
    if not model_name:
        emit_result(
            False,
            error_code="ASR_MODEL_MISSING",
            message="Missing ASR model for bootstrap run.",
        )
        return 1

    warmup_wav_path = _create_bootstrap_wav()
    try:
        emit_progress("asr_bootstrap", "Loading ASR model")
        transcribe_with_mlx(
            audio_path=warmup_wav_path,
            model=model_name,
            language=language,
        )
        emit_result(
            True,
            message=f"ASR model ready: {model_name}",
        )
        return 0
    except Exception as exc:
        emit_result(
            False,
            error_code="ASR_BOOTSTRAP_FAILED",
            message=str(exc),
        )
        return 1
    finally:
        try:
            Path(warmup_wav_path).unlink(missing_ok=True)
        except OSError:
            pass


def _asr_timeout_seconds() -> float:
    raw_value = os.environ.get("OPPY_ASR_TIMEOUT_SECONDS", "900").strip()
    try:
        timeout = float(raw_value)
    except ValueError:
        return 900.0
    if timeout <= 0:
        return 900.0
    return timeout


def _transcribe_with_timeout(audio_path: str, model: str, language: str, timeout_seconds: float):
    holder: dict[str, object] = {}
    completed = threading.Event()

    def run_transcription() -> None:
        try:
            holder["result"] = transcribe_with_mlx(
                audio_path=audio_path,
                model=model,
                language=language,
            )
        except Exception as exc:
            holder["error"] = exc
        finally:
            completed.set()

    worker = threading.Thread(target=run_transcription, daemon=True)
    worker.start()
    if not completed.wait(timeout_seconds):
        raise TimeoutError(f"ASR transcription timed out after {timeout_seconds:.1f} seconds")

    error = holder.get("error")
    if isinstance(error, Exception):
        raise error
    return holder["result"]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config")
    parser.add_argument("--bootstrap-asr", action="store_true")
    parser.add_argument("--asr-model", default="")
    parser.add_argument("--language", default="auto")
    args = parser.parse_args()

    if args.bootstrap_asr:
        return bootstrap_asr_model(
            asr_model=args.asr_model,
            language=args.language,
        )

    if not args.config:
        emit_result(
            False,
            error_code="CONFIG_PATH_MISSING",
            message="Worker config path is required.",
        )
        return 1

    try:
        config = load_config(Path(args.config))
        audio_path = Path(config.input_wav_path)
        if not audio_path.exists():
            emit_result(
                False,
                error_code="INPUT_AUDIO_NOT_FOUND",
                message=f"Audio file not found: {audio_path}",
            )
            return 1

        token = os.environ.get("HF_TOKEN", "").strip()
        if not token:
            emit_result(
                False,
                error_code="HF_TOKEN_MISSING",
                message="No Hugging Face token found in worker environment.",
            )
            return 1

        emit_progress("mix", "Preparing combined audio track")
        mixed_audio_path = maybe_mix_microphone_track(str(audio_path))

        emit_progress("asr", "Transcribing with MLX model")
        try:
            asr_output = _transcribe_with_timeout(
                audio_path=mixed_audio_path,
                model=config.asr_model,
                language=config.language,
                timeout_seconds=_asr_timeout_seconds(),
            )
        except TimeoutError as exc:
            emit_result(
                False,
                error_code="ASR_TIMEOUT",
                message=str(exc),
            )
            return 1

        emit_progress("diarization", "Running pyannote diarization")
        diarization_warning = None
        try:
            diarization_output = diarize_with_pyannote(
                audio_path=str(audio_path),
                model=config.diarization_model,
                token=token,
            )
        except Exception as exc:
            diarization_output = []
            diarization_warning = str(exc)
            emit_progress(
                "diarization",
                "Diarization failed, continuing with unknown speakers",
            )

        emit_progress("merge", "Assigning speakers to transcript segments")
        merged_segments = merge_segments_with_speakers(
            asr_segments=asr_output["segments"],
            diarization_turns=diarization_output,
        )

        emit_progress("export", "Writing markdown transcript")
        paths = export_outputs(
            output_dir=config.output_dir,
            session_id=config.session_id,
            input_wav_path=str(audio_path),
            model_name=config.asr_model,
            diarization_model=config.diarization_model,
            language=config.language,
            merged_segments=merged_segments,
            full_text=asr_output.get("text", ""),
            duration_seconds=asr_output.get("duration_seconds", 0.0),
            save_json=config.save_json,
        )

        emit_result(
            True,
            transcript_path=paths["transcript_path"],
            wav_path=paths["wav_path"],
            json_path=paths.get("json_path"),
            message=(
                "Processing complete"
                if not diarization_warning
                else f"Processing complete (diarization fallback: {diarization_warning})"
            ),
        )
        return 0
    except Exception as exc:
        emit_result(
            False,
            error_code="WORKER_EXCEPTION",
            message=str(exc),
        )
        return 1


if __name__ == "__main__":
    sys.exit(main())
