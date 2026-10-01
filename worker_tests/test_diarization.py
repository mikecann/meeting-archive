"""Speaker labels and voice embeddings from the Whisper and pyannote adapter."""

from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch


WORKER_ROOT = Path(__file__).resolve().parents[1] / "worker"
sys.path.insert(0, str(WORKER_ROOT))

from meeting_archive_worker.manifest import verify_incoming  # noqa: E402
from meeting_archive_worker.model_processor import (  # noqa: E402
    WhisperPyannoteTranscriber,
    extract_speaker_embeddings,
    process as model_process,
)
from meeting_archive_worker.speakers import SpeakerRegistry  # noqa: E402
from test_worker import write_bundle  # noqa: E402


NAN = float("nan")


class Annotation:
    """The parts of a pyannote annotation the adapter reads."""

    def __init__(self, turns: list[tuple[float, float, str]]):
        self.turns = turns

    def labels(self) -> list[str]:
        return sorted({label for _, _, label in self.turns})

    def itertracks(self, yield_label: bool = False):
        for start, end, label in self.turns:
            yield SimpleNamespace(start=start, end=end), None, label


def diarization(turns: list[tuple[float, float, str]], embeddings: list[list[float]]):
    return SimpleNamespace(
        speaker_diarization=Annotation(turns),
        exclusive_speaker_diarization=Annotation(turns),
        speaker_embeddings=embeddings,
    )


def channel(path) -> str:
    return "microphone" if "microphone" in Path(path).name else "incoming"


def stub_transcriber(segments: dict, outputs: dict):
    """A real adapter whose Whisper and pyannote calls return fixed results."""
    transcriber = object.__new__(WhisperPyannoteTranscriber)
    transcriber.whisper = SimpleNamespace(transcribe=lambda path, **_options: (
        [SimpleNamespace(start=start, end=end, text=text) for start, end, text in segments.get(channel(path), [])],
        None,
    ))
    transcriber.diarizer = object()
    transcriber.diarization_enabled = True
    transcriber.embeddings = {}
    calls = []

    def diarize(path, **options):
        calls.append((channel(path), options))
        return outputs[channel(path)]

    transcriber._diarize_without_torchcodec = diarize
    return transcriber, calls


def run_process(incoming: Path, transcriber, database: Path) -> None:
    verified = verify_incoming(incoming)
    job = SimpleNamespace(
        meeting_id=verified.meeting_id,
        manifest_revision=verified.revision,
        manifest_sha256=verified.manifest_sha256,
    )
    with patch.dict(os.environ, {"MEETING_ARCHIVE_WORKER_DB": str(database)}, clear=True), \
         patch("meeting_archive_worker.model_processor.WhisperPyannoteTranscriber", return_value=transcriber), \
         patch("meeting_archive_worker.model_processor.probe_start_time", return_value=None), \
         patch("meeting_archive_worker.model_processor.create_playback"):
        model_process(incoming, job)


class VoiceEmbeddingTests(unittest.TestCase):
    def test_non_finite_empty_or_zero_embedding_is_no_voice_sample(self) -> None:
        rows = [[NAN, NAN], [1.0, float("inf")], [], [0.0, 0.0], [0.6, 0.8]]
        labels = SimpleNamespace(labels=lambda: [f"SPEAKER_0{index}" for index in range(5)])

        self.assertEqual(
            extract_speaker_embeddings(rows, labels, "incoming"),
            {"incoming:SPEAKER_04": [0.6, 0.8]},
        )

    def test_speaker_with_a_nan_centroid_keeps_the_rest_of_the_job(self) -> None:
        # pyannote averages an empty set of chunk embeddings for a speaker heard
        # too briefly, which gives a NaN centroid. Saving it as an observation
        # failed a real meeting on all eight attempts.
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            incoming, _ = write_bundle(root)
            database = root / "worker.sqlite"
            transcriber, _ = stub_transcriber(
                {"incoming": [(0.0, 4.0, "Thanks for joining."), (5.0, 5.4, "Yep.")]},
                {"incoming": diarization(
                    [(0.0, 4.0, "SPEAKER_00"), (5.0, 5.4, "SPEAKER_01")],
                    [[0.6, 0.8], [NAN, NAN]],
                )},
            )

            run_process(incoming, transcriber, database)

            meeting_id = verify_incoming(incoming).meeting_id
            registry = SpeakerRegistry(database)
            self.assertEqual(registry.observation(meeting_id, 1, "incoming:SPEAKER_00"), [0.6, 0.8])
            self.assertIsNone(registry.observation(meeting_id, 1, "incoming:SPEAKER_01"))
            transcript = json.loads((incoming / "transcripts/v1/transcript.json").read_text(encoding="utf-8"))
            self.assertEqual(
                [turn.get("speaker") for turn in transcript["turns"]],
                ["incoming:SPEAKER_00", "incoming:SPEAKER_01"],
            )
            self.assertTrue(transcript["processing"]["speaker_observations_committed"])


if __name__ == "__main__":
    unittest.main()
