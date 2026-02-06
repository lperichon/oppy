import unittest
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from pipeline.merge import merge_segments_with_speakers


class MergeTests(unittest.TestCase):
    def test_assigns_speakers_by_overlap_and_normalizes_labels(self):
        asr_segments = [
            {"start": 0.0, "end": 2.0, "text": "hello team"},
            {"start": 2.1, "end": 4.0, "text": "status update"},
            {"start": 4.2, "end": 5.0, "text": "thanks"},
        ]
        diarization_turns = [
            {"start": 0.0, "end": 2.5, "speaker": "SPEAKER_07"},
            {"start": 2.5, "end": 5.0, "speaker": "SPEAKER_03"},
        ]

        merged = merge_segments_with_speakers(asr_segments, diarization_turns)

        self.assertEqual(len(merged), 3)
        self.assertEqual(merged[0]["speaker"], "Speaker 1")
        self.assertEqual(merged[1]["speaker"], "Speaker 2")
        self.assertEqual(merged[2]["speaker"], "Speaker 2")

    def test_falls_back_to_unknown_speaker_when_no_turns(self):
        asr_segments = [
            {"start": 0.0, "end": 1.0, "text": "line one"},
            {"start": 1.0, "end": 2.0, "text": "line two"},
        ]

        merged = merge_segments_with_speakers(asr_segments, diarization_turns=[])

        self.assertEqual([segment["speaker"] for segment in merged], ["Speaker ?", "Speaker ?"])


if __name__ == "__main__":
    unittest.main()
