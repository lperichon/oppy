from __future__ import annotations

from typing import Any

import numpy as np
import soundfile as sf
import torch


def _load_audio_for_pyannote(audio_path: str) -> dict[str, Any]:
    waveform, sample_rate = sf.read(audio_path, always_2d=True)
    waveform = waveform.astype(np.float32).T
    tensor = torch.from_numpy(waveform)
    return {"waveform": tensor, "sample_rate": int(sample_rate)}


def diarize_with_pyannote(audio_path: str, model: str, token: str) -> list[dict[str, Any]]:
    try:
        from pyannote.audio import Pipeline
    except ModuleNotFoundError as exc:
        raise RuntimeError(
            "pyannote.audio is not installed for the worker Python environment. "
            "Install dependencies with: python3 -m pip install -r worker/requirements.txt"
        ) from exc

    pipeline = Pipeline.from_pretrained(model, token=token)
    output = pipeline(_load_audio_for_pyannote(audio_path))

    annotation = output
    if hasattr(output, "exclusive_speaker_diarization"):
        annotation = output.exclusive_speaker_diarization
    elif hasattr(output, "speaker_diarization"):
        annotation = output.speaker_diarization

    if not hasattr(annotation, "itertracks"):
        raise RuntimeError(
            f"Unsupported pyannote output type: {type(output).__name__}"
        )

    turns: list[dict[str, Any]] = []
    for turn, _, speaker in annotation.itertracks(yield_label=True):
        turns.append(
            {
                "start": float(turn.start),
                "end": float(turn.end),
                "speaker": str(speaker),
            }
        )

    turns.sort(key=lambda t: t["start"])
    return turns
