from __future__ import annotations

import json
import math
import sqlite3
import tempfile
import unittest
import uuid
from contextlib import closing
from pathlib import Path

from meeting_archive_worker.speakers import (
    KNOWN_VOICE_MEETINGS,
    MATCH_MARGIN,
    OWN_MICROPHONE_THRESHOLD,
    SAME_VOICE_THRESHOLD,
    STRONG_MATCH_THRESHOLD,
    TENTATIVE_MATCH_THRESHOLD,
    SpeakerRegistry,
    classify_match,
)


def embedding_with_cosine(score: float) -> list[float]:
    return [score, math.sqrt(1.0 - score * score)]


class SpeakerReviewMatchingTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.database = Path(self.temporary.name) / "worker.sqlite"
        self.registry = SpeakerRegistry(self.database)
        self.query = [1.0, 0.0]

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _confirm(
        self,
        name: str,
        embedding: list[float],
        *,
        meeting_id: str | None = None,
        speaker_id: str = "microphone:SPEAKER_00",
        model_id: str = "model@1",
    ) -> str:
        meeting_id = meeting_id or str(uuid.uuid4())
        self.registry.save_observation(
            meeting_id,
            1,
            speaker_id,
            embedding,
            model_id,
        )
        self.assertTrue(
            self.registry.confirm_observation(meeting_id, 1, speaker_id, name)
        )
        return meeting_id

    def test_thresholds_are_pinned_to_the_measured_voice_data(self) -> None:
        # Different people scored at most 0.654 on Bruce. Changing these
        # changes how often Mike is asked, and how often a name is wrong.
        self.assertEqual(STRONG_MATCH_THRESHOLD, 0.82)
        self.assertEqual(SAME_VOICE_THRESHOLD, 0.72)
        self.assertEqual(KNOWN_VOICE_MEETINGS, 2)
        self.assertEqual(TENTATIVE_MATCH_THRESHOLD, 0.65)
        self.assertEqual(OWN_MICROPHONE_THRESHOLD, 0.65)
        self.assertEqual(MATCH_MARGIN, 0.08)

    def test_one_confirmed_meeting_names_only_a_strong_match(self) -> None:
        meeting_id = self._confirm("Mike Cann", embedding_with_cosine(0.81))
        self.assertEqual(
            self.registry.review_match(self.query, model_id="model@1"),
            {
                "suggested_name": None,
                "automatic_name": None,
                "suggestion_kind": None,
                "suggestion_score": 0.81,
                "suggestion_margin": None,
                "confirmation_count": 1,
            },
        )

        # Another of his voices from the same meeting is still one meeting.
        self._confirm("Mike Cann", embedding_with_cosine(0.82), meeting_id=meeting_id, speaker_id="incoming:SPEAKER_01")
        strong = self.registry.review_match(self.query, model_id="model@1")
        self.assertEqual(strong["automatic_name"], "Mike Cann")
        self.assertEqual(strong["suggestion_kind"], "strong")
        self.assertEqual(strong["confirmation_count"], 1)

    def test_two_confirmed_meetings_name_a_same_voice_and_suggest_a_close_one(self) -> None:
        self._confirm("Mike Cann", embedding_with_cosine(0.63))
        self._confirm("Mike Cann", embedding_with_cosine(0.64))
        below = self.registry.review_match(self.query, model_id="model@1")
        self.assertIsNone(below["suggested_name"])
        self.assertEqual(below["confirmation_count"], 2)

        self._confirm("Mike Cann", embedding_with_cosine(0.65))
        tentative = self.registry.review_match(self.query, model_id="model@1")
        self.assertEqual(tentative["suggested_name"], "Mike Cann")
        self.assertIsNone(tentative["automatic_name"])
        self.assertEqual(tentative["suggestion_kind"], "tentative")

        self._confirm("Mike Cann", embedding_with_cosine(0.719))
        self.assertIsNone(self.registry.review_match(self.query, model_id="model@1")["automatic_name"])

        self._confirm("Mike Cann", embedding_with_cosine(0.72))
        known = self.registry.review_match(self.query, model_id="model@1")
        self.assertEqual(known["automatic_name"], "Mike Cann")
        self.assertEqual(known["suggestion_kind"], "strong")
        self.assertAlmostEqual(known["suggestion_score"], 0.72)
        self.assertEqual(known["confirmation_count"], 5)

    def test_classification_rejects_missing_or_unusable_numbers(self) -> None:
        self.assertEqual(classify_match(0.9, None, 1), "automatic")
        self.assertIsNone(classify_match(0.9, 0.079, 5))
        self.assertIsNone(classify_match(0.9, None, 0))
        self.assertIsNone(classify_match(float("nan"), None, 3))
        self.assertIsNone(classify_match(None, None, 3))
        self.assertIsNone(classify_match(0.9, float("inf"), 3))
        self.assertIsNone(classify_match(True, None, 3))

    def test_competing_candidate_must_clear_margin(self) -> None:
        self._confirm("Mike Cann", embedding_with_cosine(0.72))
        self._confirm("Mike Cann", embedding_with_cosine(0.70))
        self._confirm("James", embedding_with_cosine(0.68))

        match = self.registry.review_match(self.query, model_id="model@1")

        self.assertIsNone(match["suggested_name"])
        self.assertIsNone(match["automatic_name"])
        self.assertIsNone(match["suggestion_kind"])
        self.assertAlmostEqual(match["suggestion_score"], 0.72)
        self.assertAlmostEqual(match["suggestion_margin"], 0.04)
        self.assertEqual(match["confirmation_count"], 2)

    def test_tentative_match_counts_distinct_source_meetings_not_speakers(self) -> None:
        meeting_id = str(uuid.uuid4())
        for speaker_id, score in (
            ("microphone:SPEAKER_00", 0.71),
            ("microphone:SPEAKER_01", 0.70),
        ):
            self.registry.save_observation(
                meeting_id,
                1,
                speaker_id,
                embedding_with_cosine(score),
                "model@1",
            )
            self.assertTrue(
                self.registry.confirm_observation(
                    meeting_id,
                    1,
                    speaker_id,
                    "Mike Cann",
                )
            )

        match = self.registry.review_match(self.query, model_id="model@1")

        self.assertIsNone(match["suggested_name"])
        self.assertAlmostEqual(match["suggestion_score"], 0.71)
        self.assertEqual(match["confirmation_count"], 1)

    def test_repeat_confirmation_deduplicates_and_rename_replaces_old_name(self) -> None:
        meeting_id = self._confirm("Mike", self.query)
        self.assertTrue(
            self.registry.confirm_observation(
                meeting_id,
                1,
                "microphone:SPEAKER_00",
                "Mike",
            )
        )
        self.assertTrue(
            self.registry.confirm_observation(
                meeting_id,
                1,
                "microphone:SPEAKER_00",
                "Mike Cann",
            )
        )

        with closing(sqlite3.connect(self.database)) as connection:
            profiles = connection.execute(
                "SELECT display_name, source_meeting_id FROM voice_profiles"
            ).fetchall()
        self.assertEqual(profiles, [("Mike Cann", meeting_id)])
        self.assertEqual(
            self.registry.assignments(meeting_id, 1),
            {"microphone:SPEAKER_00": "Mike Cann"},
        )

    def test_an_all_zero_profile_from_an_older_worker_counts_for_nothing(self) -> None:
        self._confirm("Alex", embedding_with_cosine(0.75))
        # pyannote pads a voice it could not cluster with zeros. Before the
        # worker dropped those, saving that voice's name enrolled them.
        self.registry.enroll_confirmed(
            "Alex", [0.0, 0.0], "model@1",
            source_meeting_id=str(uuid.uuid4()), source_revision=1, source_speaker_id="incoming:SPEAKER_00",
        )

        match = self.registry.review_match(self.query, model_id="model@1")

        # One real meeting, so 0.75 isn't enough to name Alex.
        self.assertIsNone(match["automatic_name"])
        self.assertEqual(match["confirmation_count"], 1)

    def test_excluding_current_meeting_prevents_self_match(self) -> None:
        meeting_id = self._confirm("Mike Cann", self.query)

        included = self.registry.review_match(self.query, model_id="model@1")
        excluded = self.registry.review_match(
            self.query,
            model_id="model@1",
            exclude_meeting_id=meeting_id,
        )

        self.assertEqual(included["suggestion_kind"], "strong")
        self.assertEqual(excluded["suggested_name"], None)
        self.assertEqual(excluded["confirmation_count"], 0)

    def test_model_mismatch_and_unproven_profiles_do_not_enter_review_match(self) -> None:
        self._confirm("Wrong model", self.query, model_id="other@1")
        self.registry.enroll_confirmed("Legacy without provenance", self.query, "model@1")

        match = self.registry.review_match(self.query, model_id="model@1")

        self.assertEqual(match["suggested_name"], None)
        self.assertEqual(match["suggestion_score"], None)
        self.assertEqual(match["confirmation_count"], 0)
        self.assertEqual(self.registry.suggest(self.query, model_id="model@1"), "Legacy without provenance")

    def test_connection_helper_is_read_only_and_rejects_invalid_query_embedding(self) -> None:
        self._confirm("Mike Cann", self.query)
        with closing(
            sqlite3.connect(self.database.resolve().as_uri() + "?mode=ro", uri=True)
        ) as connection:
            match = SpeakerRegistry.review_match_from_connection(
                connection,
                self.query,
                model_id="model@1",
            )
        self.assertEqual(match["automatic_name"], "Mike Cann")

        for invalid in ([], [float("nan"), 0.0], [float("inf"), 0.0]):
            with self.subTest(invalid=invalid):
                with self.assertRaises(ValueError):
                    self.registry.review_match(invalid, model_id="model@1")

    def test_unambiguous_legacy_profile_is_backfilled_from_exact_observation(self) -> None:
        database = Path(self.temporary.name) / "legacy.sqlite"
        meeting_id = str(uuid.uuid4())
        self._create_legacy_database(
            database,
            [(meeting_id, "Mike Cann", self.query)],
            [("Mike Cann", self.query), ("Mike Cann", self.query)],
        )

        registry = SpeakerRegistry(database)

        match = registry.review_match(self.query, model_id="model@1")
        self.assertEqual(match["automatic_name"], "Mike Cann")
        self.assertEqual(match["confirmation_count"], 1)
        with closing(sqlite3.connect(database)) as connection:
            profiles = connection.execute(
                "SELECT source_meeting_id, source_revision, source_speaker_id "
                "FROM voice_profiles"
            ).fetchall()
        self.assertEqual(
            profiles,
            [(meeting_id, 1, "microphone:SPEAKER_00")],
        )

    def test_ambiguous_legacy_profile_is_not_counted_as_confirmed_evidence(self) -> None:
        database = Path(self.temporary.name) / "ambiguous.sqlite"
        first = str(uuid.uuid4())
        second = str(uuid.uuid4())
        self._create_legacy_database(
            database,
            [
                (first, "Mike Cann", self.query),
                (second, "Mike Cann", self.query),
            ],
            [("Mike Cann", self.query)],
        )

        registry = SpeakerRegistry(database)

        match = registry.review_match(self.query, model_id="model@1")
        self.assertIsNone(match["suggested_name"])
        self.assertEqual(match["confirmation_count"], 0)
        with closing(sqlite3.connect(database)) as connection:
            source = connection.execute(
                "SELECT source_meeting_id FROM voice_profiles"
            ).fetchone()[0]
        self.assertIsNone(source)

    @staticmethod
    def _create_legacy_database(
        database: Path,
        observations: list[tuple[str, str, list[float]]],
        profiles: list[tuple[str, list[float]]],
    ) -> None:
        with closing(sqlite3.connect(database)) as connection:
            with connection:
                connection.execute(
                    """CREATE TABLE speaker_assignments (
                    meeting_id TEXT NOT NULL, manifest_revision INTEGER NOT NULL,
                    speaker_id TEXT NOT NULL, display_name TEXT NOT NULL,
                    confirmed_at TEXT NOT NULL,
                    PRIMARY KEY(meeting_id, manifest_revision, speaker_id))"""
                )
                connection.execute(
                    """CREATE TABLE observed_voices (
                    meeting_id TEXT NOT NULL, manifest_revision INTEGER NOT NULL,
                    speaker_id TEXT NOT NULL, embedding_json TEXT NOT NULL,
                    model_id TEXT NOT NULL, dimension INTEGER NOT NULL,
                    PRIMARY KEY(meeting_id, manifest_revision, speaker_id))"""
                )
                connection.execute(
                    """CREATE TABLE voice_profiles (
                    display_name TEXT NOT NULL, embedding_json TEXT NOT NULL,
                    confirmed_at TEXT NOT NULL, model_id TEXT NOT NULL,
                    dimension INTEGER NOT NULL)"""
                )
                for meeting_id, name, embedding in observations:
                    connection.execute(
                        "INSERT INTO speaker_assignments VALUES (?, 1, ?, ?, ?)",
                        (meeting_id, "microphone:SPEAKER_00", name, "2026-09-17T00:00:00Z"),
                    )
                    connection.execute(
                        "INSERT INTO observed_voices VALUES (?, 1, ?, ?, ?, ?)",
                        (
                            meeting_id,
                            "microphone:SPEAKER_00",
                            json.dumps(embedding),
                            "model@1",
                            len(embedding),
                        ),
                    )
                for name, embedding in profiles:
                    connection.execute(
                        "INSERT INTO voice_profiles VALUES (?, ?, ?, ?, ?)",
                        (
                            name,
                            json.dumps(embedding),
                            "2026-09-17T00:00:00Z",
                            "model@1",
                            len(embedding),
                        ),
                    )


def unit(*values: float) -> list[float]:
    norm = math.sqrt(sum(value * value for value in values))
    return [value / norm for value in values]


def turned(score: float) -> list[float]:
    """A 3-D voice whose cosine with [1, 0, 0] is score."""
    return [score, math.sqrt(1.0 - score * score), 0.0]


class MeetingMatchTests(unittest.TestCase):
    """Rules that need the rest of the meeting: the mic owner and split voices."""

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.database = Path(self.temporary.name) / "worker.sqlite"
        self.registry = SpeakerRegistry(self.database)
        self.meeting = str(uuid.uuid4())

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _observe(self, speaker_id: str, embedding: list[float], meeting_id: str | None = None) -> None:
        self.registry.save_observation(meeting_id or self.meeting, 1, speaker_id, embedding, "model@1")

    def _confirm_elsewhere(self, name: str, embedding: list[float], speaker_id: str = "microphone:SPEAKER_00") -> str:
        meeting_id = str(uuid.uuid4())
        self._observe(speaker_id, embedding, meeting_id)
        self.registry.confirm_observation(meeting_id, 1, speaker_id, name)
        return meeting_id

    def _matches(self, *speaker_ids: str) -> dict:
        return self.registry.meeting_matches(self.meeting, 1, list(speaker_ids))

    def test_the_only_mic_speaker_is_named_as_its_owner_once_his_voice_is_saved(self) -> None:
        self._confirm_elsewhere("Mike Cann", [1.0, 0.0, 0.0])
        self._observe("microphone:SPEAKER_00", turned(OWN_MICROPHONE_THRESHOLD))
        self._observe("incoming:SPEAKER_00", [0.0, 0.0, 1.0])

        match = self._matches("microphone:SPEAKER_00", "incoming:SPEAKER_00")["microphone:SPEAKER_00"]

        self.assertEqual(match["automatic_name"], "Mike Cann")
        self.assertEqual(match["suggestion_kind"], "own_microphone")
        self.assertEqual(match["confirmation_count"], 1)

    def test_a_mic_voice_below_the_owner_gate_is_left_for_review(self) -> None:
        self._confirm_elsewhere("Mike Cann", [1.0, 0.0, 0.0])
        self._observe("microphone:SPEAKER_00", turned(0.64))

        match = self._matches("microphone:SPEAKER_00")["microphone:SPEAKER_00"]

        self.assertIsNone(match["automatic_name"])
        self.assertIsNone(match["suggested_name"])

    def test_a_diarized_mic_with_several_voices_has_no_owner_shortcut(self) -> None:
        self._confirm_elsewhere("Mike Cann", [1.0, 0.0, 0.0])
        self._observe("microphone:SPEAKER_00", turned(0.70))
        self._observe("microphone:SPEAKER_01", [0.0, 0.0, 1.0])

        matches = self._matches("microphone:SPEAKER_00", "microphone:SPEAKER_01")

        self.assertIsNone(matches["microphone:SPEAKER_00"]["automatic_name"])

    def test_the_owner_is_whoever_was_confirmed_on_the_mic_in_most_meetings(self) -> None:
        self._confirm_elsewhere("Mike Cann", [1.0, 0.0, 0.0])
        self._confirm_elsewhere("Mike Cann", [1.0, 0.0, 0.0])
        # Heard through the speakers on an old diarized recording.
        self._confirm_elsewhere("Gavin", [0.0, 0.0, 1.0], speaker_id="microphone:SPEAKER_01")
        self._observe("microphone:SPEAKER_00", turned(0.66))

        match = self._matches("microphone:SPEAKER_00")["microphone:SPEAKER_00"]

        self.assertEqual(match["automatic_name"], "Mike Cann")

    def test_no_owner_when_two_people_are_tied_on_the_mic(self) -> None:
        self._confirm_elsewhere("Mike Cann", [1.0, 0.0, 0.0])
        self._confirm_elsewhere("Gavin", [0.0, 1.0, 0.0])
        self._observe("microphone:SPEAKER_00", unit(0.7, 0.0, 0.714))

        match = self._matches("microphone:SPEAKER_00")["microphone:SPEAKER_00"]

        self.assertIsNone(match["automatic_name"])

    def test_the_owner_must_be_the_best_match_for_the_mic_voice(self) -> None:
        self._confirm_elsewhere("Mike Cann", [1.0, 0.0, 0.0])
        self._confirm_elsewhere("Mike Cann", [1.0, 0.0, 0.0])
        self._confirm_elsewhere("Blake", unit(1.0, 1.0, 0.0), speaker_id="incoming:SPEAKER_00")
        # 0.67 against Mike but 0.95 against Blake.
        self._observe("microphone:SPEAKER_00", unit(0.66, 0.66, 0.3))

        match = self._matches("microphone:SPEAKER_00")["microphone:SPEAKER_00"]

        self.assertEqual(match["automatic_name"], "Blake")
        self.assertEqual(match["suggestion_kind"], "strong")

    def test_a_split_voice_takes_the_name_saved_for_its_twin_in_the_same_meeting(self) -> None:
        self._observe("incoming:SPEAKER_00", [1.0, 0.0, 0.0])
        self._observe("incoming:SPEAKER_01", turned(SAME_VOICE_THRESHOLD))
        self._observe("incoming:SPEAKER_02", turned(0.71))
        self.registry.confirm_observation(self.meeting, 1, "incoming:SPEAKER_00", "Micah")

        matches = self._matches("incoming:SPEAKER_00", "incoming:SPEAKER_01", "incoming:SPEAKER_02")

        self.assertEqual(matches["incoming:SPEAKER_01"]["automatic_name"], "Micah")
        self.assertEqual(matches["incoming:SPEAKER_01"]["suggestion_kind"], "same_meeting")
        self.assertIsNone(matches["incoming:SPEAKER_02"]["automatic_name"])
        self.assertIsNone(matches["incoming:SPEAKER_00"]["automatic_name"])
        # Automatic names are never confirmations or profiles.
        self.assertEqual(self.registry.assignments(self.meeting, 1), {"incoming:SPEAKER_00": "Micah"})
        with closing(sqlite3.connect(self.database)) as connection:
            self.assertEqual(connection.execute("SELECT COUNT(*) FROM voice_profiles").fetchone()[0], 1)

    def test_a_split_voice_between_two_saved_people_is_left_alone(self) -> None:
        self._observe("incoming:SPEAKER_00", [1.0, 0.0, 0.0])
        self._observe("incoming:SPEAKER_01", [0.0, 1.0, 0.0])
        self._observe("incoming:SPEAKER_02", unit(1.0, 0.9, 0.0))
        self.registry.confirm_observations(
            self.meeting, 1, {"incoming:SPEAKER_00": "Micah", "incoming:SPEAKER_01": "Sean"},
        )

        match = self._matches("incoming:SPEAKER_00", "incoming:SPEAKER_01", "incoming:SPEAKER_02")["incoming:SPEAKER_02"]

        self.assertIsNone(match["automatic_name"])

    def test_disagreeing_evidence_becomes_a_suggestion_not_a_name(self) -> None:
        self._confirm_elsewhere("Blake", unit(1.0, 0.3, 0.0), speaker_id="incoming:SPEAKER_00")
        self._observe("incoming:SPEAKER_00", unit(1.0, 0.0, 0.8))
        self._observe("incoming:SPEAKER_01", [1.0, 0.0, 0.0])
        self.registry.confirm_observation(self.meeting, 1, "incoming:SPEAKER_00", "Alex")

        match = self._matches("incoming:SPEAKER_00", "incoming:SPEAKER_01")["incoming:SPEAKER_01"]

        # 0.96 to Blake beats 0.78 to the Alex saved here, so Blake is filled in.
        self.assertIsNone(match["automatic_name"])
        self.assertEqual(match["suggested_name"], "Blake")
        self.assertEqual(match["suggestion_kind"], "tentative")

    def test_disagreeing_evidence_suggests_whichever_voice_is_closer(self) -> None:
        self._confirm_elsewhere("Blake", unit(1.0, 0.0, 0.9), speaker_id="incoming:SPEAKER_00")
        self._confirm_elsewhere("Blake", unit(1.0, 0.0, 0.9), speaker_id="incoming:SPEAKER_00")
        self._observe("incoming:SPEAKER_00", unit(1.0, 0.3, 0.0))
        self._observe("incoming:SPEAKER_01", [1.0, 0.0, 0.0])
        self.registry.confirm_observation(self.meeting, 1, "incoming:SPEAKER_00", "Alex")

        match = self._matches("incoming:SPEAKER_00", "incoming:SPEAKER_01")["incoming:SPEAKER_01"]

        # 0.96 to the Alex saved here beats 0.74 to Blake from two meetings.
        self.assertIsNone(match["automatic_name"])
        self.assertEqual(match["suggested_name"], "Alex")
        self.assertEqual(match["suggestion_kind"], "tentative")

    def test_a_saved_name_hides_any_other_name_for_that_voice(self) -> None:
        self._confirm_elsewhere("Blake", [1.0, 0.0, 0.0], speaker_id="incoming:SPEAKER_00")
        self._observe("incoming:SPEAKER_00", turned(0.95))
        self.registry.confirm_observation(self.meeting, 1, "incoming:SPEAKER_00", "Alex")

        match = self._matches("incoming:SPEAKER_00")["incoming:SPEAKER_00"]

        # 0.95 to Blake would name him, but Mike saved this voice as Alex.
        self.assertIsNone(match["automatic_name"])
        self.assertIsNone(match["suggested_name"])
        self.assertIsNone(match["suggestion_kind"])

    def test_targets_limit_the_work_without_changing_the_answer(self) -> None:
        self._confirm_elsewhere("Mike Cann", [1.0, 0.0, 0.0])
        self._observe("microphone:SPEAKER_00", turned(0.9))
        self._observe("incoming:SPEAKER_00", [0.0, 0.0, 1.0])
        everyone = self._matches("microphone:SPEAKER_00", "incoming:SPEAKER_00")

        with closing(sqlite3.connect(self.database.resolve().as_uri() + "?mode=ro", uri=True)) as connection:
            targeted = SpeakerRegistry.meeting_matches_from_connection(
                connection, self.meeting, 1, ["microphone:SPEAKER_00", "incoming:SPEAKER_00"],
                targets=["microphone:SPEAKER_00"],
            )

        self.assertEqual(targeted, {"microphone:SPEAKER_00": everyone["microphone:SPEAKER_00"]})


class SaveNamesTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.database = Path(self.temporary.name) / "worker.sqlite"
        from meeting_archive_worker.queue import JobQueue

        JobQueue(self.database)
        self.registry = SpeakerRegistry(self.database)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _accept(self, meeting_id: str) -> None:
        with closing(sqlite3.connect(self.database)) as connection:
            with connection:
                connection.execute(
                    "INSERT INTO acceptances VALUES (?, 1, ?, ?, ?, ?)",
                    (meeting_id, "a" * 64, "/archive/" + meeting_id, "{}", "2026-10-02T00:00:00Z"),
                )

    def _refreshes(self) -> set[str]:
        with closing(sqlite3.connect(self.database)) as connection:
            return {row[0] for row in connection.execute("SELECT meeting_id FROM speaker_refreshes")}

    def test_names_for_several_speakers_are_saved_and_enrolled_together(self) -> None:
        meeting = str(uuid.uuid4())
        self.registry.save_observation(meeting, 1, "incoming:SPEAKER_00", [1.0, 0.0], "model@1")
        self.registry.save_observation(meeting, 1, "incoming:SPEAKER_01", [0.9, 0.1], "model@1")

        enrolled = self.registry.confirm_observations(meeting, 1, {
            "incoming:SPEAKER_00": "Micah",
            "incoming:SPEAKER_01": " Micah ",
            "incoming:SPEAKER_02": "Sean",
        })

        self.assertEqual(enrolled, {"incoming:SPEAKER_00": True, "incoming:SPEAKER_01": True, "incoming:SPEAKER_02": False})
        self.assertEqual(self.registry.assignments(meeting, 1), {
            "incoming:SPEAKER_00": "Micah", "incoming:SPEAKER_01": "Micah", "incoming:SPEAKER_02": "Sean",
        })
        with closing(sqlite3.connect(self.database)) as connection:
            profiles = connection.execute(
                "SELECT display_name, source_speaker_id FROM voice_profiles ORDER BY source_speaker_id",
            ).fetchall()
            generation = connection.execute(
                "SELECT generation FROM speaker_refreshes WHERE meeting_id=?", (meeting,),
            ).fetchone()
        self.assertEqual(profiles, [("Micah", "incoming:SPEAKER_00"), ("Micah", "incoming:SPEAKER_01")])
        self.assertEqual(generation, (1,))

    def test_an_all_zero_voice_is_named_but_never_enrolled(self) -> None:
        meeting = str(uuid.uuid4())
        # An older worker could save pyannote's zero padding as a voice.
        self.registry.save_observation(meeting, 1, "incoming:SPEAKER_00", [0.0, 0.0], "model@1")
        self.registry.save_observation(meeting, 1, "incoming:SPEAKER_01", [1.0, 0.0], "model@1")

        enrolled = self.registry.confirm_observations(meeting, 1, {
            "incoming:SPEAKER_00": "Alex",
            "incoming:SPEAKER_01": "Blake",
        })

        self.assertEqual(enrolled, {"incoming:SPEAKER_00": False, "incoming:SPEAKER_01": True})
        self.assertEqual(self.registry.assignments(meeting, 1), {
            "incoming:SPEAKER_00": "Alex", "incoming:SPEAKER_01": "Blake",
        })
        with closing(sqlite3.connect(self.database)) as connection:
            profiles = connection.execute("SELECT display_name FROM voice_profiles").fetchall()
        self.assertEqual(profiles, [("Blake",)])

    def test_one_blank_name_saves_nothing(self) -> None:
        meeting = str(uuid.uuid4())
        self.registry.save_observation(meeting, 1, "incoming:SPEAKER_00", [1.0, 0.0], "model@1")

        for names in ({}, {"incoming:SPEAKER_00": "Micah", "incoming:SPEAKER_01": "  "}, {"": "Micah"}):
            with self.subTest(names=names), self.assertRaises(ValueError):
                self.registry.confirm_observations(meeting, 1, names)

        self.assertEqual(self.registry.assignments(meeting, 1), {})
        self.assertEqual(self._refreshes(), set())

    def test_saving_a_voice_refreshes_other_meetings_with_that_voice_unnamed(self) -> None:
        current, similar, different, named, unaccepted = (str(uuid.uuid4()) for _ in range(5))
        for meeting in (similar, different, named):
            self._accept(meeting)
        self.registry.save_observation(current, 1, "incoming:SPEAKER_00", [1.0, 0.0], "model@1")
        self.registry.save_observation(similar, 1, "incoming:SPEAKER_03", embedding_with_cosine(0.6), "model@1")
        self.registry.save_observation(different, 1, "incoming:SPEAKER_00", embedding_with_cosine(0.5), "model@1")
        self.registry.save_observation(named, 1, "incoming:SPEAKER_00", [1.0, 0.0], "model@1")
        self.registry.confirm_observation(named, 1, "incoming:SPEAKER_00", "Micah")
        self.registry.save_observation(unaccepted, 1, "incoming:SPEAKER_00", [1.0, 0.0], "model@1")
        with closing(sqlite3.connect(self.database)) as connection:
            with connection:
                connection.execute("DELETE FROM speaker_refreshes")

        self.registry.confirm_observation(current, 1, "incoming:SPEAKER_00", "Micah")

        self.assertEqual(self._refreshes(), {current, similar})

    def _clear_refreshes(self) -> None:
        with closing(sqlite3.connect(self.database)) as connection:
            with connection:
                connection.execute("DELETE FROM speaker_refreshes")

    def _confirm(self, meeting: str, speaker: str, embedding: list[float], name: str) -> None:
        self.registry.save_observation(meeting, 1, speaker, embedding, "model@1")
        self.registry.confirm_observation(meeting, 1, speaker, name)

    def test_a_second_confirmed_meeting_refreshes_voices_close_to_the_first(self) -> None:
        first, second, waiting = (str(uuid.uuid4()) for _ in range(3))
        self._accept(waiting)
        self._confirm(first, "incoming:SPEAKER_00", [1.0, 0.0, 0.0], "Alice")
        # 0.75 to Alice's first sample: suggested at one meeting, named at two.
        self.registry.save_observation(waiting, 1, "incoming:SPEAKER_00", turned(0.75), "model@1")
        self._clear_refreshes()

        # Her second sample sounds nothing like the waiting voice.
        self._confirm(second, "incoming:SPEAKER_00", [0.0, 0.0, 1.0], "Alice")

        self.assertEqual(self._refreshes(), {second, waiting})
        match = self.registry.meeting_matches(waiting, 1, ["incoming:SPEAKER_00"])["incoming:SPEAKER_00"]
        self.assertEqual(match["automatic_name"], "Alice")

    def test_renaming_away_a_second_meeting_refreshes_what_it_named(self) -> None:
        first, second, waiting = (str(uuid.uuid4()) for _ in range(3))
        self._accept(waiting)
        self._confirm(first, "incoming:SPEAKER_00", [1.0, 0.0, 0.0], "Alice")
        self._confirm(second, "incoming:SPEAKER_00", [0.0, 0.0, 1.0], "Alice")
        self.registry.save_observation(waiting, 1, "incoming:SPEAKER_00", turned(0.75), "model@1")
        self._clear_refreshes()

        self.registry.confirm_observation(second, 1, "incoming:SPEAKER_00", "Bob")

        self.assertEqual(self._refreshes(), {second, waiting})
        match = self.registry.meeting_matches(waiting, 1, ["incoming:SPEAKER_00"])["incoming:SPEAKER_00"]
        self.assertIsNone(match["automatic_name"])

    def test_a_new_mic_owner_refreshes_meetings_whose_mic_he_now_owns(self) -> None:
        mike_a, mike_b, mike_c, gavin_a, gavin_b, waiting = (str(uuid.uuid4()) for _ in range(6))
        self._accept(waiting)
        self._confirm(mike_a, "microphone:SPEAKER_00", [1.0, 0.0, 0.0], "Mike Cann")
        self._confirm(mike_b, "microphone:SPEAKER_00", [1.0, 0.0, 0.0], "Mike Cann")
        self._confirm(gavin_a, "microphone:SPEAKER_00", [0.0, 0.0, 1.0], "Gavin")
        self._confirm(gavin_b, "microphone:SPEAKER_00", [0.0, 0.0, 1.0], "Gavin")
        # Tied on the mic, so nobody owns it and 0.66 is only a suggestion.
        self.registry.save_observation(waiting, 1, "microphone:SPEAKER_00", turned(0.66), "model@1")
        self.assertIsNone(
            self.registry.meeting_matches(waiting, 1, ["microphone:SPEAKER_00"])["microphone:SPEAKER_00"]["automatic_name"],
        )
        self._clear_refreshes()

        # A third Mike sample far from the waiting voice changes no count
        # boundary, only who owns the mic.
        self._confirm(mike_c, "microphone:SPEAKER_00", unit(0.0, -1.0, 0.2), "Mike Cann")

        self.assertEqual(self._refreshes(), {mike_c, waiting})
        match = self.registry.meeting_matches(waiting, 1, ["microphone:SPEAKER_00"])["microphone:SPEAKER_00"]
        self.assertEqual(match["suggestion_kind"], "own_microphone")


if __name__ == "__main__":
    unittest.main()
