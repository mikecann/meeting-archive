from __future__ import annotations

import json
import io
import math
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock
from contextlib import redirect_stdout

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "worker"))

from meeting_archive_worker.speaker_evidence import (  # noqa: E402
    automatic_names,
    refresh_speaker_matches,
)
from meeting_archive_worker.cli import main as cli_main, _speaker_counts_for_status  # noqa: E402
from meeting_archive_worker.queue import JobQueue  # noqa: E402
from meeting_archive_worker.speakers import SpeakerRegistry  # noqa: E402


def transcript():
    return {
        "schema_version": 1, "meeting_id": "current", "manifest_revision": 2,
        "processing": {"manifest_sha256": "a" * 64},
        "turns": [{"speaker": "microphone:SPEAKER_00", "start": 1.0,
                   "end": 9.0, "text": "A different recording", "channel_origin": "microphone"}],
    }


def match(kind="tentative"):
    return {"suggested_name": "Mike Cann", "automatic_name": "Mike Cann" if kind == "strong" else None,
            "suggestion_kind": kind, "suggestion_score": .9 if kind == "strong" else .72,
            "suggestion_margin": None, "confirmation_count": 2}


class SpeakerEvidenceTests(unittest.TestCase):
    def registry(self, kind="tentative"):
        registry = Mock()
        registry.assignments.return_value = {}
        registry.observation_record.return_value = ([1.0, 0.0], "model")
        registry.review_match.return_value = match(kind)
        return registry

    def test_tentative_match_never_writes_transcript_name_or_assignment(self):
        result = transcript()
        registry = self.registry()
        refresh_speaker_matches(result, registry)
        self.assertNotIn("name", result["turns"][0])
        self.assertEqual(result["speaker_matches"]["microphone:SPEAKER_00"]["suggested_name"], "Mike Cann")
        self.assertEqual(automatic_names(result), {})
        registry.review_match.assert_called_once_with([1.0, 0.0], model_id="model", exclude_meeting_id="current")
        registry.confirm_observation.assert_not_called()
        registry.enroll_confirmed.assert_not_called()

    def test_strong_match_is_named_but_not_enrolled(self):
        result = transcript()
        registry = self.registry("strong")
        refresh_speaker_matches(result, registry)
        self.assertEqual(result["turns"][0]["name"], "Mike Cann")
        self.assertEqual(result["turns"][0]["name_source"], "voice_match")
        self.assertEqual(automatic_names(result), {"microphone:SPEAKER_00": "Mike Cann"})
        registry.confirm_observation.assert_not_called()

    def test_explicit_assignment_overrides_automatic_match(self):
        result = transcript()
        registry = self.registry("strong")
        registry.assignments.return_value = {"microphone:SPEAKER_00": "Other person"}
        refresh_speaker_matches(result, registry)
        self.assertEqual(result["turns"][0]["name"], "Other person")
        self.assertEqual(result["turns"][0]["name_source"], "confirmed")
        self.assertEqual(automatic_names(result), {})

    def test_old_automatic_name_is_removed_when_match_no_longer_qualifies(self):
        result = transcript()
        result["turns"][0].update(name="Mike Cann", name_source="voice_match")
        refresh_speaker_matches(result, self.registry())
        self.assertNotIn("name", result["turns"][0])
        self.assertNotIn("name_source", result["turns"][0])

    def test_status_requires_all_turns_to_have_the_same_automatic_name(self):
        result = transcript()
        refresh_speaker_matches(result, self.registry("strong"))
        result["turns"].append({"speaker": "microphone:SPEAKER_00", "text": "unnamed"})
        self.assertEqual(automatic_names(result), {})


class ReviewIntegrationTests(unittest.TestCase):
    def setup_archive(self, root, score):
        database = root / "worker.sqlite"
        JobQueue(database)
        registry = SpeakerRegistry(database)
        for previous in ("previous-a", "previous-b"):
            registry.save_observation(previous, 1, "microphone:SPEAKER_00", [1.0, 0.0], "model")
            registry.confirm_observation(previous, 1, "microphone:SPEAKER_00", "Mike Cann")
        registry.save_observation("current", 2, "microphone:SPEAKER_00", [score, math.sqrt(1 - score * score)], "model")
        archive = root / "archive"
        (archive / "transcripts/v2").mkdir(parents=True)
        (archive / "transcripts/v2/transcript.json").write_text(json.dumps(transcript()))
        (archive / "metadata.json").write_text('{"attendees":[]}')
        return database, registry, archive

    def test_two_confirmations_prefill_tentative_review_without_naming_or_enrolling(self):
        with tempfile.TemporaryDirectory() as temporary:
            database, registry, archive = self.setup_archive(Path(temporary), .72)
            output = io.StringIO()
            with redirect_stdout(output):
                code = cli_main(["review-speakers", "--archive-dir", str(archive), "--revision", "2", "--db", str(database)])
            response = json.loads(output.getvalue())
            self.assertEqual(code, 0)
            speaker = response["speakers"][0]
            self.assertEqual(speaker["suggested_name"], "Mike Cann")
            self.assertEqual(speaker["suggestion_kind"], "tentative")
            self.assertEqual(speaker["confirmation_count"], 2)
            self.assertIsNone(speaker["automatic_name"])
            self.assertIsNone(speaker["name"])
            saved = json.loads((archive / "transcripts/v2/transcript.json").read_text())
            self.assertNotIn("name", saved["turns"][0])
            self.assertEqual(registry.assignments("current", 2), {})
            with sqlite3.connect(database) as connection:
                self.assertEqual(connection.execute("SELECT COUNT(*) FROM voice_profiles").fetchone()[0], 2)

    def test_strong_review_persists_automatic_name_and_speaker_count_is_read_only(self):
        with tempfile.TemporaryDirectory() as temporary:
            database, registry, archive = self.setup_archive(Path(temporary), .9)
            output = io.StringIO()
            with redirect_stdout(output):
                code = cli_main(["review-speakers", "--archive-dir", str(archive), "--revision", "2", "--db", str(database)])
            self.assertEqual(code, 0)
            self.assertEqual(json.loads(output.getvalue())["speakers"][0]["automatic_name"], "Mike Cann")
            job = {"state": "succeeded", "archive_path": str(archive), "meeting_id": "current",
                   "manifest_revision": 2, "manifest_sha256": "a" * 64}
            before = database.read_bytes()
            self.assertEqual(_speaker_counts_for_status(job, database), (1, 0))
            self.assertEqual(database.read_bytes(), before)
            self.assertEqual(registry.assignments("current", 2), {})
            with sqlite3.connect(database) as connection:
                self.assertEqual(connection.execute("SELECT COUNT(*) FROM voice_profiles").fetchone()[0], 2)

    def test_review_keeps_an_empty_evidence_list_and_ignores_old_video_labels(self):
        with tempfile.TemporaryDirectory() as temporary:
            database, _, archive = self.setup_archive(Path(temporary), .72)
            (archive / "playback").mkdir()
            (archive / "playback/meeting.mp4").write_bytes(b"old video playback")
            # A v1 meeting can still hold the cache the removed OCR step wrote.
            (archive / "transcripts/v2/visual-labels.json").write_text(json.dumps({
                "key": "stale",
                "labels": {"microphone:SPEAKER_00": [
                    {"name": "Mike Cann", "timestamps": [2.0], "source": "video_label"},
                ]},
            }))
            output = io.StringIO()
            with redirect_stdout(output):
                code = cli_main(["review-speakers", "--archive-dir", str(archive), "--revision", "2", "--db", str(database)])
            self.assertEqual(code, 0)
            speakers = json.loads(output.getvalue())["speakers"]
            self.assertEqual([speaker["evidence_labels"] for speaker in speakers], [[]])

    def test_status_does_not_hide_a_name_that_was_not_persisted(self):
        with tempfile.TemporaryDirectory() as temporary:
            database, _, archive = self.setup_archive(Path(temporary), .9)
            job = {"state": "succeeded", "archive_path": str(archive), "meeting_id": "current",
                   "manifest_revision": 2, "manifest_sha256": "a" * 64}
            self.assertEqual(_speaker_counts_for_status(job, database), (1, 1))


if __name__ == "__main__":
    unittest.main()
