import argparse
import json
import os
import sys
from dataclasses import dataclass
from pathlib import Path

from pipeline.asr import transcribe_with_mlx
from pipeline.diarization import diarize_with_pyannote
from pipeline.export import export_outputs
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


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    args = parser.parse_args()

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

        emit_progress("asr", "Transcribing with MLX model")
        asr_output = transcribe_with_mlx(
            audio_path=str(audio_path),
            model=config.asr_model,
            language=config.language,
        )

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
