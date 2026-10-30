"""Nemotron 3 Diarization draws the turns; pyannote still makes the voice samples."""

from __future__ import annotations

import contextlib
import os
import sqlite3
import stat
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import numpy as np

WORKER_ROOT = Path(__file__).resolve().parents[1] / "worker"
sys.path.insert(0, str(WORKER_ROOT))

from meeting_archive_worker.manifest import verify_incoming  # noqa: E402
from meeting_archive_worker.model_processor import (  # noqa: E402
    NEMOTRON_MODEL,
    NemotronDiarizer,
    read_rttm,
    speaker_centroids,
)
from test_diarization import MODEL_ID, diarization, run_process, saved_transcript, stub_transcriber  # noqa: E402
from test_worker import write_bundle  # noqa: E402


RATE = 16000
CUT_IN = (
    0.0, 4.0, " So yeah, this could get messy. So can I use this?",
    [(0.0, 0.5, "So"), (0.5, 1.0, "yeah,"), (1.0, 1.5, "this"), (1.5, 2.0, "could"), (2.0, 2.5, "get"),
     (2.5, 3.0, "messy."), (3.0, 3.3, "So"), (3.3, 3.6, "can"), (3.6, 3.8, "I"), (3.8, 3.9, "use"),
     (3.9, 4.0, "this?")],
)


class FakeNemotron:
    def __init__(self, turns=None, error: Exception | None = None) -> None:
        self.turns, self.error, self.paths = turns or [], error, []

    def speaker_turns(self, path):
        self.paths.append(path)
        if self.error:
            raise self.error
        return self.turns


def with_nemotron(transcriber, nemotron):
    """Give a stub transcriber Nemotron and ten seconds of silent audio."""
    transcriber.nemotron = nemotron
    transcriber.track_diarizers = {}
    transcriber.diarizer_device = "cpu"

    @contextlib.contextmanager
    def samples(path):
        yield np.zeros(10 * RATE, dtype="<i2")

    transcriber._decoded_samples = samples
    return transcriber


class NemotronTurnTests(unittest.TestCase):
    def test_nemotron_turns_label_the_words_and_pyannote_never_runs(self) -> None:
        transcriber, pyannote_calls = stub_transcriber({"incoming": [CUT_IN]}, {})
        nemotron = FakeNemotron([(0.0, 3.0, "SPEAKER_00"), (3.0, 10.0, "SPEAKER_01")])
        with_nemotron(transcriber, nemotron)

        with patch("meeting_archive_worker.model_processor.speaker_centroids",
                   return_value={"SPEAKER_00": [0.6, 0.8], "SPEAKER_01": [0.8, -0.6]}):
            turns = transcriber.transcribe(Path("incoming.m4a"), "incoming")

        self.assertEqual(pyannote_calls, [])
        self.assertEqual(nemotron.paths, [Path("incoming.m4a")])
        self.assertEqual(
            [(turn["speaker"], turn["text"]) for turn in turns],
            [("incoming:SPEAKER_00", "So yeah, this could get messy."), ("incoming:SPEAKER_01", "So can I use this?")],
        )
        self.assertEqual(transcriber.embeddings, {"incoming:SPEAKER_00": [0.6, 0.8], "incoming:SPEAKER_01": [0.8, -0.6]})
        self.assertEqual(transcriber.track_diarizers, {"incoming": "nemotron"})

    def test_a_track_filling_all_eight_slots_goes_to_pyannote(self) -> None:
        transcriber, pyannote_calls = stub_transcriber(
            {"incoming": [CUT_IN]},
            {"incoming": diarization([(0.0, 4.0, "SPEAKER_00")], [[0.6, 0.8]])},
        )
        crowd = [(float(index), index + 0.5, f"SPEAKER_0{index}") for index in range(8)]
        with_nemotron(transcriber, FakeNemotron(crowd))

        turns = transcriber.transcribe(Path("incoming.m4a"), "incoming")

        self.assertEqual(pyannote_calls, [("incoming", {})])
        self.assertEqual({turn["speaker"] for turn in turns}, {"incoming:SPEAKER_00"})
        self.assertEqual(transcriber.track_diarizers, {"incoming": "pyannote"})

    def test_a_nemotron_failure_falls_back_to_pyannote(self) -> None:
        transcriber, pyannote_calls = stub_transcriber(
            {"incoming": [CUT_IN]},
            {"incoming": diarization([(0.0, 4.0, "SPEAKER_00")], [[0.6, 0.8]])},
        )
        with_nemotron(transcriber, FakeNemotron(error=RuntimeError("exit 1: no model")))

        transcriber.transcribe(Path("incoming.m4a"), "incoming")

        self.assertEqual(pyannote_calls, [("incoming", {})])
        self.assertEqual(transcriber.embeddings, {"incoming:SPEAKER_00": [0.6, 0.8]})

    def test_the_receipt_names_nemotron_but_voices_keep_pyannotes_model_id(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            incoming, _ = write_bundle(root)
            database = root / "worker.sqlite"
            transcriber, _ = stub_transcriber({"incoming": [CUT_IN]}, {})
            with_nemotron(transcriber, FakeNemotron([(0.0, 3.0, "SPEAKER_00"), (3.0, 10.0, "SPEAKER_01")]))

            with patch("meeting_archive_worker.model_processor.speaker_centroids",
                       return_value={"SPEAKER_00": [0.6, 0.8], "SPEAKER_01": [0.8, -0.6]}):
                run_process(incoming, transcriber, database)

            processing = saved_transcript(incoming)["processing"]
            self.assertEqual(processing["diarization_model"], NEMOTRON_MODEL)
            self.assertEqual(processing["speaker_embedding_model"], "pyannote/speaker-diarization-community-1")
            self.assertEqual(processing["track_diarizers"], {"incoming": "nemotron"})
            meeting_id = verify_incoming(incoming).meeting_id
            with contextlib.closing(sqlite3.connect(database)) as connection:
                models = {row[0] for row in connection.execute(
                    "SELECT model_id FROM observed_voices WHERE meeting_id=?", (meeting_id,),
                )}
            # Profiles enrolled before the switch match only within this id.
            self.assertEqual(models, {MODEL_ID})


class SpeakerCentroidTests(unittest.TestCase):
    def test_each_speaker_averages_only_windows_where_they_talk_alone(self) -> None:
        samples = np.zeros(30 * RATE, dtype="<i2")
        turns = [
            (0.0, 12.0, "SPEAKER_00"),
            (12.0, 30.0, "SPEAKER_01"),
            # Talking over speaker one: these frames count for nobody.
            (14.0, 16.0, "SPEAKER_00"),
        ]
        seen = []

        def embed(chunk, mask):
            seen.append((len(chunk), len(mask), int(mask.sum())))
            return [1.0, float(len(seen))]

        centroids = speaker_centroids(embed, samples, RATE, turns)

        self.assertEqual(set(centroids), {"SPEAKER_00", "SPEAKER_01"})
        # Every chunk is the window's audio, with a mask of the same length.
        self.assertTrue(all(chunk == mask * 160 for chunk, mask, _ in seen))
        self.assertTrue(all(alone >= 200 for _, _, alone in seen))
        self.assertEqual(centroids["SPEAKER_00"][0], 1.0)

    def test_a_speaker_never_alone_for_two_seconds_has_no_sample(self) -> None:
        samples = np.zeros(20 * RATE, dtype="<i2")
        turns = [(0.0, 20.0, "SPEAKER_00"), (5.0, 6.5, "SPEAKER_01")]

        centroids = speaker_centroids(lambda chunk, mask: [0.6, 0.8], samples, RATE, turns)

        self.assertEqual(centroids, {"SPEAKER_00": [0.6, 0.8]})

    def test_unusable_embeddings_are_dropped(self) -> None:
        samples = np.zeros(10 * RATE, dtype="<i2")

        centroids = speaker_centroids(lambda chunk, mask: [0.0, 0.0], samples, RATE, [(0.0, 10.0, "SPEAKER_00")])

        self.assertEqual(centroids, {})


class NemotronCliTests(unittest.TestCase):
    def test_rttm_turns_are_sorted_and_named_like_pyannote(self) -> None:
        rttm = (
            "SPEAKER incoming 1 7.520 2.400 <NA> <NA> speaker_1 <NA> <NA>\n"
            "SPEAKER incoming 1 3.960 1.230 <NA> <NA> speaker_0 <NA> <NA>\n"
            "garbage\n"
        )

        self.assertEqual(read_rttm(rttm), [(3.96, 5.19, "SPEAKER_00"), (7.52, 9.92, "SPEAKER_01")])

    def test_nemotron_is_used_only_when_chosen_and_installed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            cli = Path(temporary) / "fluidaudiocli"
            cli.write_text("#!/bin/sh\n")
            cli.chmod(cli.stat().st_mode | stat.S_IXUSR)
            with patch.dict(os.environ, {"MEETING_ARCHIVE_NEMOTRON_CLI": str(cli)}, clear=True):
                self.assertIsInstance(NemotronDiarizer.from_environment(), NemotronDiarizer)
            with patch.dict(os.environ, {"MEETING_ARCHIVE_NEMOTRON_CLI": str(cli), "MEETING_ARCHIVE_DIARIZER": "pyannote"}, clear=True):
                self.assertIsNone(NemotronDiarizer.from_environment())
            with patch.dict(os.environ, {"MEETING_ARCHIVE_NEMOTRON_CLI": str(Path(temporary) / "missing")}, clear=True):
                self.assertIsNone(NemotronDiarizer.from_environment())

    def test_the_cli_is_asked_for_rttm_and_its_failure_is_reported(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            cli = Path(temporary) / "fluidaudiocli"
            # A stand-in CLI: writes one turn to the --output path it was given.
            cli.write_text(
                "#!/bin/sh\n"
                'while [ "$1" != "--output" ]; do shift; done\n'
                'echo "SPEAKER x 1 1.000 2.000 <NA> <NA> speaker_0 <NA> <NA>" > "$2"\n'
            )
            cli.chmod(cli.stat().st_mode | stat.S_IXUSR)
            failing = Path(temporary) / "failing"
            failing.write_text("#!/bin/sh\necho 'model download failed' >&2\nexit 3\n")
            failing.chmod(failing.stat().st_mode | stat.S_IXUSR)
            with patch.dict(os.environ, {"MEETING_ARCHIVE_SCRATCH": temporary}, clear=True):
                self.assertEqual(NemotronDiarizer(str(cli)).speaker_turns(Path("a.m4a")), [(1.0, 3.0, "SPEAKER_00")])
                with self.assertRaisesRegex(RuntimeError, "exit 3: model download failed"):
                    NemotronDiarizer(str(failing)).speaker_turns(Path("a.m4a"))
                # No RTTM is left behind in scratch either way.
                self.assertEqual(sorted(path.name for path in Path(temporary).iterdir()), ["failing", "fluidaudiocli"])


if __name__ == "__main__":
    unittest.main()
