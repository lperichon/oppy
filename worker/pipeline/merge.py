from __future__ import annotations

from typing import Any


def _overlap(a_start: float, a_end: float, b_start: float, b_end: float) -> float:
    return max(0.0, min(a_end, b_end) - max(a_start, b_start))


def _nearest_speaker(segment_midpoint: float, turns: list[dict[str, Any]]) -> str:
    nearest_turn = min(
        turns,
        key=lambda turn: min(
            abs(segment_midpoint - turn["start"]),
            abs(segment_midpoint - turn["end"]),
        ),
    )
    return str(nearest_turn["speaker"])


def merge_segments_with_speakers(
    asr_segments: list[dict[str, Any]],
    diarization_turns: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    if not diarization_turns:
        return [
            {
                "start": float(seg.get("start", 0.0)),
                "end": float(seg.get("end", 0.0)),
                "text": str(seg.get("text", "")).strip(),
                "speaker": "Speaker ?",
            }
            for seg in asr_segments
            if str(seg.get("text", "")).strip()
        ]

    raw_labeled_segments: list[dict[str, Any]] = []
    label_order: list[str] = []

    for seg in asr_segments:
        text = str(seg.get("text", "")).strip()
        if not text:
            continue

        start = float(seg.get("start", 0.0))
        end = float(seg.get("end", start))
        if end < start:
            end = start

        best_speaker = None
        best_overlap = 0.0
        for turn in diarization_turns:
            overlap = _overlap(start, end, float(turn["start"]), float(turn["end"]))
            if overlap > best_overlap:
                best_overlap = overlap
                best_speaker = str(turn["speaker"])

        if not best_speaker:
            midpoint = (start + end) / 2.0
            best_speaker = _nearest_speaker(midpoint, diarization_turns)

        if best_speaker not in label_order:
            label_order.append(best_speaker)

        raw_labeled_segments.append(
            {
                "start": start,
                "end": end,
                "text": text,
                "speaker": best_speaker,
            }
        )

    speaker_map = {raw: f"Speaker {idx + 1}" for idx, raw in enumerate(label_order)}

    return [
        {
            "start": seg["start"],
            "end": seg["end"],
            "text": seg["text"],
            "speaker": speaker_map.get(seg["speaker"], "Speaker ?"),
        }
        for seg in raw_labeled_segments
    ]
