from __future__ import annotations

import json
from datetime import datetime
from pathlib import Path
from typing import Any


def _format_timestamp(seconds: float) -> str:
    total = int(round(max(0.0, seconds)))
    minutes = total // 60
    secs = total % 60
    return f"{minutes:02d}:{secs:02d}"


def _session_basename_from_wav(input_wav_path: str) -> str:
    return Path(input_wav_path).stem


def _write_atomic(path: Path, content: str) -> None:
    temp_path = path.with_suffix(path.suffix + ".tmp")
    temp_path.write_text(content)
    temp_path.replace(path)


def export_outputs(
    output_dir: str,
    session_id: str,
    input_wav_path: str,
    model_name: str,
    diarization_model: str,
    language: str,
    merged_segments: list[dict[str, Any]],
    full_text: str,
    duration_seconds: float,
    save_json: bool,
) -> dict[str, str]:
    output_folder = Path(output_dir)
    output_folder.mkdir(parents=True, exist_ok=True)

    basename = _session_basename_from_wav(input_wav_path)
    transcript_path = output_folder / f"{basename}.md"

    lines: list[str] = [
        "# Meeting Transcript",
        "",
        f"- Session ID: `{session_id}`",
        f"- Created At: `{datetime.now().isoformat(timespec='seconds')}`",
        f"- Duration: `{duration_seconds:.1f}s`",
        f"- ASR Model: `{model_name}`",
        f"- Diarization Model: `{diarization_model}`",
        f"- Language: `{language}`",
        "",
        "## Transcript",
        "",
    ]

    for segment in merged_segments:
        ts = _format_timestamp(float(segment.get("start", 0.0)))
        speaker = str(segment.get("speaker", "Speaker ?"))
        text = str(segment.get("text", "")).strip()
        if not text:
            continue
        lines.append(f"[{ts}] {speaker}: {text}")

    if len(lines) <= 12 and full_text.strip():
        lines.extend(["", "## Raw Text", "", full_text.strip()])

    markdown = "\n".join(lines) + "\n"
    _write_atomic(transcript_path, markdown)

    result = {
        "transcript_path": str(transcript_path),
        "wav_path": input_wav_path,
    }

    if save_json:
        json_path = output_folder / f"{basename}.json"
        payload = {
            "session_id": session_id,
            "created_at": datetime.now().isoformat(timespec="seconds"),
            "duration_seconds": duration_seconds,
            "asr_model": model_name,
            "diarization_model": diarization_model,
            "language": language,
            "segments": merged_segments,
        }
        _write_atomic(json_path, json.dumps(payload, indent=2))
        result["json_path"] = str(json_path)

    return result
