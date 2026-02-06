from __future__ import annotations

from pathlib import Path

import numpy as np
import soundfile as sf


def _resample(signal: np.ndarray, source_rate: int, target_rate: int) -> np.ndarray:
    if source_rate == target_rate:
        return signal.astype(np.float32)
    if signal.size == 0:
        return signal.astype(np.float32)

    duration = len(signal) / float(source_rate)
    target_length = max(1, int(round(duration * target_rate)))
    source_positions = np.linspace(0.0, len(signal) - 1, num=len(signal), dtype=np.float64)
    target_positions = np.linspace(0.0, len(signal) - 1, num=target_length, dtype=np.float64)
    return np.interp(target_positions, source_positions, signal).astype(np.float32)


def _to_mono(audio: np.ndarray) -> np.ndarray:
    if audio.ndim == 1:
        return audio.astype(np.float32)
    return audio.mean(axis=1).astype(np.float32)


def maybe_mix_microphone_track(system_wav_path: str) -> str:
    system_path = Path(system_wav_path)
    mic_path = system_path.with_name(f"{system_path.stem}.mic{system_path.suffix}")
    if not mic_path.exists():
        return str(system_path)

    system_audio, system_sr = sf.read(str(system_path), always_2d=False)
    mic_audio, mic_sr = sf.read(str(mic_path), always_2d=False)

    system_mono = _to_mono(np.asarray(system_audio))
    mic_mono = _to_mono(np.asarray(mic_audio))

    target_sr = int(system_sr)
    mic_mono = _resample(mic_mono, int(mic_sr), target_sr)

    mixed_length = max(len(system_mono), len(mic_mono))
    if len(system_mono) < mixed_length:
        system_mono = np.pad(system_mono, (0, mixed_length - len(system_mono)))
    if len(mic_mono) < mixed_length:
        mic_mono = np.pad(mic_mono, (0, mixed_length - len(mic_mono)))

    mixed = (system_mono + mic_mono) * 0.5
    peak = float(np.max(np.abs(mixed))) if mixed.size > 0 else 0.0
    if peak > 1.0:
        mixed = mixed / peak

    temp_path = system_path.with_suffix(".mixing" + system_path.suffix)
    sf.write(str(temp_path), mixed, target_sr)
    temp_path.replace(system_path)
    return str(system_path)
