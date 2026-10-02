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
from contextlib import closing, redirect_stdout

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "worker"))

from meeting_archive_worker.speaker_evidence import (  # noqa: E402
    automatic_names,
    refresh_speaker_matches,
)
from meeting_archive_worker.cli import (  # noqa: E402
    _calendar_candidates,
    _speaker_counts_for_status,
    main as cli_main,
)
from meeting_archive_worker.queue import JobQueue  # noqa: E402
from meeting_archive_worker.speakers import SpeakerRegistry  # noqa: E402


# Events exactly as the Mac app writes them under metadata["calendar"]: its
# CalendarSuggestion type encoded by ModelCodec, then re-serialized with sorted
# keys by SpoolBundle. "email" is left out when unknown and "response" is
# EKParticipantStatus's raw value as a string. Generated with the app's types.
PORT_GEO_ATTENDEES = [
    {"email": "mike.cann@gmail.com", "name": "Mike Cann", "response": "2"},
    {"email": "priya@example.com", "name": "Priya Shah", "response": "4"},
    {"name": "Unnamed guest", "response": "0"},
]
PORT_GEO_EVENT = {
    "attendees": PORT_GEO_ATTENDEES,
    "end": "2026-10-01T01:30:00.000Z",
    "id": "7D1A6C2E-1F00-4C55-9D2B-3C1D5F2A9B10:1790816400.0",
    "start": "2026-10-01T01:00:00.000Z",
    "title": "Acme sync",
}
FAMILY_EVENT = {
    "attendees": [{"email": "kelsie@example.com", "name": "Kelsie Cann", "response": "1"}],
    "end": "2026-10-01T01:15:00.000Z",
    "id": "0B5E9F3A-77C4-4E0B-8A61-2D4C9E8F1A23:1790816400.0",
    "start": "2026-10-01T01:00:00.000Z",
    "title": "School pickup",
}


def app_metadata(events, attendees=None):
    """metadata.json as the app writes it; top-level attendees are new in v2."""
    metadata = {
        "calendar": events,
        "duration_seconds": 1800,
        "ended_at": "2026-10-01T01:30:00.000Z",
        "manifest_revision": 2,
        "meeting_id": "current",
        "schema_version": 1,
        "source_app": "com.google.Chrome",
        "started_at": "2026-10-01T01:00:00.000Z",
        "timezone": "Australia/Perth",
        "title": "Acme sync",
        "tracks": {
            "incoming": {"endOffset": 1800.2, "firstOffset": 0.41, "lastOffset": 1800.18, "sampleCount": 84390},
            "microphone": {"endOffset": 1800.1, "firstOffset": 0.38, "lastOffset": 1800.08, "sampleCount": 84385},
        },
    }
    if attendees is not None:
        metadata["attendees"] = attendees
    return metadata


PORT_GEO_CANDIDATES = [
    {"name": "Mike Cann", "email": "mike.cann@gmail.com", "response_status": "2", "source": None},
    {"name": "Priya Shah", "email": "priya@example.com", "response_status": "4", "source": None},
    {"name": "Unnamed guest", "email": None, "response_status": "0", "source": None},
]


def transcript(speaker="microphone:SPEAKER_00"):
    return {
        "schema_version": 1, "meeting_id": "current", "manifest_revision": 2,
        "processing": {"manifest_sha256": "a" * 64},
        "turns": [{"speaker": speaker, "start": 1.0, "end": 31.0,
                   "text": "A different recording", "channel_origin": speaker.split(":")[0]}],
    }


def match(kind="tentative"):
    automatic = kind in ("strong", "own_microphone", "same_meeting")
    return {"suggested_name": "Mike Cann", "automatic_name": "Mike Cann" if automatic else None,
            "suggestion_kind": kind, "suggestion_score": .9 if kind == "strong" else .70,
            "suggestion_margin": None, "confirmation_count": 2}


class SpeakerEvidenceTests(unittest.TestCase):
    def registry(self, kind="tentative"):
        registry = Mock()
        registry.assignments.return_value = {}
        registry.meeting_matches.return_value = {"microphone:SPEAKER_00": match(kind)}
        return registry

    def test_tentative_match_never_writes_transcript_name_or_assignment(self):
        result = transcript()
        registry = self.registry()
        refresh_speaker_matches(result, registry)
        self.assertNotIn("name", result["turns"][0])
        self.assertEqual(result["speaker_matches"]["microphone:SPEAKER_00"]["suggested_name"], "Mike Cann")
        self.assertEqual(automatic_names(result), {})
        registry.meeting_matches.assert_called_once_with("current", 2, ["microphone:SPEAKER_00"])
        registry.confirm_observation.assert_not_called()
        registry.confirm_observations.assert_not_called()
        registry.enroll_confirmed.assert_not_called()

    def test_every_kind_of_automatic_name_is_written_and_acknowledged(self):
        for kind in ("strong", "own_microphone", "same_meeting"):
            with self.subTest(kind=kind):
                result = transcript()
                refresh_speaker_matches(result, self.registry(kind))
                self.assertEqual(result["turns"][0]["name_source"], "voice_match")
                self.assertEqual(automatic_names(result), {"microphone:SPEAKER_00": "Mike Cann"})

    def test_a_strong_match_below_its_gates_is_not_acknowledged(self):
        result = transcript()
        refresh_speaker_matches(result, self.registry("strong"))
        result["speaker_matches"]["microphone:SPEAKER_00"]["suggestion_score"] = 0.7
        self.assertEqual(automatic_names(result), {})

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


class CalendarCandidateTests(unittest.TestCase):
    def test_top_level_attendees_of_the_matched_event_come_first(self):
        metadata = app_metadata([PORT_GEO_EVENT, FAMILY_EVENT], attendees=PORT_GEO_ATTENDEES)
        self.assertEqual(_calendar_candidates(metadata), PORT_GEO_CANDIDATES)

    def test_a_bundle_without_top_level_attendees_uses_its_only_calendar_event(self):
        self.assertEqual(_calendar_candidates(app_metadata([PORT_GEO_EVENT])), PORT_GEO_CANDIDATES)

    def test_several_calendar_events_without_a_matched_one_suggest_nobody(self):
        self.assertEqual(_calendar_candidates(app_metadata([PORT_GEO_EVENT, FAMILY_EVENT])), [])
        self.assertEqual(_calendar_candidates(app_metadata([])), [])

    def test_empty_top_level_attendees_are_not_replaced_by_the_calendar(self):
        self.assertEqual(_calendar_candidates(app_metadata([FAMILY_EVENT], attendees=[])), [])


class ReviewIntegrationTests(unittest.TestCase):
    def setup_archive(self, root, score, speaker="microphone:SPEAKER_00"):
        database = root / "worker.sqlite"
        JobQueue(database)
        registry = SpeakerRegistry(database)
        for previous in ("previous-a", "previous-b"):
            registry.save_observation(previous, 1, speaker, [1.0, 0.0], "model")
            registry.confirm_observation(previous, 1, speaker, "Mike Cann")
        registry.save_observation("current", 2, speaker, [score, math.sqrt(1 - score * score)], "model")
        archive = root / "archive"
        (archive / "transcripts/v2").mkdir(parents=True)
        (archive / "transcripts/v2/transcript.json").write_text(json.dumps(transcript(speaker)))
        (archive / "metadata.json").write_text(json.dumps(
            app_metadata([PORT_GEO_EVENT, FAMILY_EVENT], attendees=PORT_GEO_ATTENDEES),
            sort_keys=True,
        ))
        return database, registry, archive

    def test_two_confirmations_prefill_tentative_review_without_naming_or_enrolling(self):
        with tempfile.TemporaryDirectory() as temporary:
            database, registry, archive = self.setup_archive(Path(temporary), .70, "incoming:SPEAKER_00")
            output = io.StringIO()
            with redirect_stdout(output):
                code = cli_main(["review-speakers", "--archive-dir", str(archive), "--revision", "2", "--db", str(database)])
            response = json.loads(output.getvalue())
            self.assertEqual(code, 0)
            self.assertEqual(response["calendar_candidates"], PORT_GEO_CANDIDATES)
            speaker = response["speakers"][0]
            self.assertEqual(speaker["suggested_name"], "Mike Cann")
            self.assertEqual(speaker["suggestion_kind"], "tentative")
            self.assertEqual(speaker["confirmation_count"], 2)
            self.assertIsNone(speaker["automatic_name"])
            self.assertIsNone(speaker["name"])
            saved = json.loads((archive / "transcripts/v2/transcript.json").read_text())
            self.assertNotIn("name", saved["turns"][0])
            self.assertEqual(registry.assignments("current", 2), {})
            with closing(sqlite3.connect(database)) as connection:
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
            with closing(sqlite3.connect(database)) as connection:
                self.assertEqual(connection.execute("SELECT COUNT(*) FROM voice_profiles").fetchone()[0], 2)

    def test_review_keeps_an_empty_evidence_list_and_ignores_old_video_labels(self):
        with tempfile.TemporaryDirectory() as temporary:
            database, _, archive = self.setup_archive(Path(temporary), .70)
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

    def test_the_only_mic_voice_is_named_as_its_owner_and_counts_as_done(self):
        with tempfile.TemporaryDirectory() as temporary:
            database, registry, archive = self.setup_archive(Path(temporary), .70)
            output = io.StringIO()
            with redirect_stdout(output):
                code = cli_main(["review-speakers", "--archive-dir", str(archive), "--revision", "2", "--db", str(database)])
            self.assertEqual(code, 0)
            speaker = json.loads(output.getvalue())["speakers"][0]
            self.assertEqual(speaker["automatic_name"], "Mike Cann")
            self.assertEqual(speaker["suggestion_kind"], "own_microphone")
            saved = json.loads((archive / "transcripts/v2/transcript.json").read_text())
            self.assertEqual(saved["turns"][0]["name_source"], "voice_match")
            job = {"state": "succeeded", "archive_path": str(archive), "meeting_id": "current",
                   "manifest_revision": 2, "manifest_sha256": "a" * 64}
            self.assertEqual(_speaker_counts_for_status(job, database), (1, 0))
            # Recognizing him never makes his voice a confirmed sample.
            self.assertEqual(registry.assignments("current", 2), {})
            with closing(sqlite3.connect(database)) as connection:
                self.assertEqual(connection.execute("SELECT COUNT(*) FROM voice_profiles").fetchone()[0], 2)

    def test_a_voice_split_from_a_saved_one_counts_as_done(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            database = root / "worker.sqlite"
            JobQueue(database)
            registry = SpeakerRegistry(database)
            registry.save_observation("current", 2, "incoming:SPEAKER_00", [1.0, 0.0], "model")
            registry.save_observation("current", 2, "incoming:SPEAKER_01", [0.73, math.sqrt(1 - 0.73 ** 2)], "model")
            registry.save_observation("current", 2, "incoming:SPEAKER_02", [0.0, 1.0], "model")
            registry.confirm_observation("current", 2, "incoming:SPEAKER_00", "Micah")
            archive = root / "archive"
            (archive / "transcripts/v2").mkdir(parents=True)
            document = transcript("incoming:SPEAKER_00")
            for speaker in ("incoming:SPEAKER_01", "incoming:SPEAKER_02"):
                document["turns"].append({"speaker": speaker, "start": 32.0, "end": 60.0,
                                          "text": "Later", "channel_origin": "incoming"})
            refresh_speaker_matches(document, registry)
            (archive / "transcripts/v2/transcript.json").write_text(json.dumps(document))
            job = {"state": "succeeded", "archive_path": str(archive), "meeting_id": "current",
                   "manifest_revision": 2, "manifest_sha256": "a" * 64}

            self.assertEqual(document["turns"][1]["name"], "Micah")
            self.assertEqual(document["speaker_matches"]["incoming:SPEAKER_01"]["suggestion_kind"], "same_meeting")
            self.assertEqual(_speaker_counts_for_status(job, database), (3, 1))

    def test_review_samples_the_wordiest_lines_in_order(self):
        with tempfile.TemporaryDirectory() as temporary:
            database, _, archive = self.setup_archive(Path(temporary), .70, "incoming:SPEAKER_00")
            document = json.loads((archive / "transcripts/v2/transcript.json").read_text())
            document["turns"] = [
                {"speaker": "incoming:SPEAKER_00", "start": float(index), "end": index + 1.0,
                 "text": text, "channel_origin": "incoming"}
                for index, text in enumerate([
                    "Yeah.", "We should ship the archive on Friday.", "Okay.",
                    "Can you send me the transcript after?", "Yes.", "Thanks, that is everything from me today.",
                ])
            ]
            (archive / "transcripts/v2/transcript.json").write_text(json.dumps(document))
            output = io.StringIO()
            with redirect_stdout(output):
                code = cli_main(["review-speakers", "--archive-dir", str(archive), "--revision", "2", "--db", str(database)])
            self.assertEqual(code, 0)
            excerpts = json.loads(output.getvalue())["speakers"][0]["excerpts"]
            self.assertEqual([excerpt["start"] for excerpt in excerpts], [1.0, 3.0, 5.0])

    def test_status_does_not_hide_a_name_that_was_not_persisted(self):
        with tempfile.TemporaryDirectory() as temporary:
            database, _, archive = self.setup_archive(Path(temporary), .9)
            job = {"state": "succeeded", "archive_path": str(archive), "meeting_id": "current",
                   "manifest_revision": 2, "manifest_sha256": "a" * 64}
            self.assertEqual(_speaker_counts_for_status(job, database), (1, 1))


class ShortVoiceTests(unittest.TestCase):
    def test_a_voice_heard_for_a_few_seconds_isnt_asked_about(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            database = root / "worker.sqlite"
            SpeakerRegistry(database)
            archive = root / "archive"
            (archive / "transcripts/v2").mkdir(parents=True)
            document = transcript("incoming:SPEAKER_00")
            # Two lines adding up to 14 seconds: under the bar, so not counted.
            document["turns"] += [
                {"speaker": "incoming:SPEAKER_01", "start": 40.0, "end": 47.0, "text": "Hi", "channel_origin": "incoming"},
                {"speaker": "incoming:SPEAKER_01", "start": 50.0, "end": 57.0, "text": "Bye", "channel_origin": "incoming"},
            ]
            (archive / "transcripts/v2/transcript.json").write_text(json.dumps(document))
            job = {"state": "succeeded", "archive_path": str(archive), "meeting_id": "current",
                   "manifest_revision": 2, "manifest_sha256": "a" * 64}

            self.assertEqual(_speaker_counts_for_status(job, database), (2, 1))


if __name__ == "__main__":
    unittest.main()
