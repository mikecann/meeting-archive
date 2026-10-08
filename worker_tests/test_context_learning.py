"""Learning a voice when the conversation and the voice agree."""

from __future__ import annotations

import io
import json
import math
import sqlite3
import tempfile
import unittest
import uuid
from contextlib import closing, redirect_stdout
from pathlib import Path

from meeting_archive_worker.cli import main as cli_main
from meeting_archive_worker.queue import JobQueue
from meeting_archive_worker.speakers import (
    CONTEXT_ENROLL_THRESHOLD,
    CONTEXT_MINIMUM_SPEECH_SECONDS,
    CONTEXT_MINIMUM_WORDS,
    SpeakerRegistry,
)


def with_cosine(score: float) -> list[float]:
    """A vector scoring `score` against [1, 0]."""
    return [score, math.sqrt(1.0 - score * score)]


def entry(speaker: str, name: str | None, confidence: str = "high") -> dict:
    return {"speaker": speaker, "name": name, "confidence": confidence, "evidence": "quote"}


class ContextLearningTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.database = Path(self.temporary.name) / "worker.sqlite"
        JobQueue(self.database)
        self.registry = SpeakerRegistry(self.database)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def saved(self, name: str, vector: list[float] | None = None) -> str:
        """Mike saved this name for a voice in a new meeting."""
        meeting = str(uuid.uuid4())
        self.registry.save_observation(meeting, 1, "incoming:SPEAKER_00", vector or [1.0, 0.0], "model@1")
        self.registry.confirm_observation(meeting, 1, "incoming:SPEAKER_00", name)
        return meeting

    def heard(
        self,
        name: str | None,
        vector: list[float],
        *,
        confidence: str = "high",
        speaker: str = "incoming:SPEAKER_00",
        seconds: float = 60.0,
        words: int = 200,
        meeting: str | None = None,
    ) -> str:
        """A meeting whose conversation gave a voice this name."""
        meeting = meeting or str(uuid.uuid4())
        self.registry.save_observation(meeting, 1, speaker, vector, "model@1")
        self.registry.set_context_names(
            meeting, 1, [entry(speaker, name, confidence)] if name else [], {speaker: (seconds, words)},
        )
        return meeting

    def profiles(self) -> list[tuple]:
        with closing(sqlite3.connect(self.database)) as connection:
            return connection.execute(
                "SELECT display_name, source, source_meeting_id, source_speaker_id FROM voice_profiles "
                "ORDER BY rowid",
            ).fetchall()

    def context_profiles(self) -> list[tuple]:
        return [profile for profile in self.profiles() if profile[1] == "context"]


class MatchingProfileTests(ContextLearningTestCase):
    def test_a_high_name_and_a_voice_that_matches_that_name_is_enrolled_as_context(self) -> None:
        self.saved("Sam")
        meeting = self.heard("Sam", with_cosine(0.6))

        learned = self.registry.learn_from_context(meeting, 1)

        self.assertEqual(learned, [{"speaker": "incoming:SPEAKER_00", "name": "Sam", "rule": "matching_profile"}])
        self.assertEqual(self.context_profiles(), [("Sam", "context", meeting, "incoming:SPEAKER_00")])
        self.assertEqual(self.registry.context_profiles()[0]["name"], "Sam")

    def test_the_threshold_is_the_measured_one(self) -> None:
        self.assertEqual(CONTEXT_ENROLL_THRESHOLD, 0.55)
        self.assertEqual((CONTEXT_MINIMUM_SPEECH_SECONDS, CONTEXT_MINIMUM_WORDS), (15.0, 40))
        self.saved("Sam")
        below = self.heard("Sam", with_cosine(0.54))
        at = self.heard("Sam", with_cosine(0.55))

        self.assertEqual(self.registry.learn_from_context(below, 1), [])
        self.assertEqual(len(self.registry.learn_from_context(at, 1)), 1)

    def test_the_name_has_to_match_the_profile_not_just_the_sound(self) -> None:
        # 0.9 against Priya says nothing about a voice the conversation calls Sam.
        self.saved("Priya")
        meeting = self.heard("Sam", with_cosine(0.9))

        self.assertEqual(self.registry.learn_from_context(meeting, 1), [])
        self.assertEqual(self.context_profiles(), [])

    def test_medium_confidence_never_teaches(self) -> None:
        self.saved("Sam")
        meeting = self.heard("Sam", with_cosine(0.9), confidence="medium")

        self.assertEqual(self.registry.learn_from_context(meeting, 1), [])

    def test_the_profiles_spelling_and_case_are_kept(self) -> None:
        self.saved("Sam Example")
        meeting = self.heard("sam example", with_cosine(0.7))

        learned = self.registry.learn_from_context(meeting, 1)

        self.assertEqual(learned[0]["name"], "Sam Example")
        self.assertEqual(self.context_profiles()[0][0], "Sam Example")

    def test_a_learned_profile_names_voices_in_other_meetings(self) -> None:
        self.saved("Sam")
        meeting = self.heard("Sam", with_cosine(0.6))
        self.registry.learn_from_context(meeting, 1)
        later = str(uuid.uuid4())
        self.registry.save_observation(later, 1, "incoming:SPEAKER_03", with_cosine(0.6), "model@1")

        match = self.registry.meeting_matches(later, 1, ["incoming:SPEAKER_03"])["incoming:SPEAKER_03"]

        self.assertEqual((match["automatic_name"], match["suggestion_kind"]), ("Sam", "strong"))
        self.assertEqual(match["confirmation_count"], 2, "two meetings now know Sam")


class TwoMeetingTests(ContextLearningTestCase):
    def test_the_same_high_name_in_two_meetings_with_matching_voices_enrolls_both(self) -> None:
        first = self.heard("Priya", [1.0, 0.0])
        self.assertEqual(self.registry.learn_from_context(first, 1), [], "one meeting is not enough")
        second = self.heard("Priya", with_cosine(0.6))

        learned = self.registry.learn_from_context(second, 1)

        self.assertEqual(learned, [{"speaker": "incoming:SPEAKER_00", "name": "Priya", "rule": "two_meetings"}])
        self.assertEqual(
            {(name, meeting) for name, _, meeting, _ in self.context_profiles()},
            {("Priya", first), ("Priya", second)},
        )

    def test_voices_that_do_not_match_each_other_are_not_one_person(self) -> None:
        self.heard("Priya", [1.0, 0.0])
        second = self.heard("Priya", with_cosine(0.5))

        self.assertEqual(self.registry.learn_from_context(second, 1), [])
        self.assertEqual(self.context_profiles(), [])

    def test_two_voices_in_one_meeting_are_not_two_meetings(self) -> None:
        meeting = str(uuid.uuid4())
        for speaker in ("incoming:SPEAKER_00", "incoming:SPEAKER_01"):
            self.registry.save_observation(meeting, 1, speaker, [1.0, 0.0], "model@1")
        self.registry.set_context_names(
            meeting, 1, [entry("incoming:SPEAKER_00", "Priya"), entry("incoming:SPEAKER_01", "Priya")],
            {"incoming:SPEAKER_00": (60, 200), "incoming:SPEAKER_01": (60, 200)},
        )

        self.assertEqual(self.registry.learn_from_context(meeting, 1), [])

    def test_a_medium_or_junk_partner_does_not_count(self) -> None:
        self.heard("Priya", [1.0, 0.0], confidence="medium")
        self.heard("Priya", [1.0, 0.0], seconds=5.0)
        second = self.heard("Priya", with_cosine(0.9))

        self.assertEqual(self.registry.learn_from_context(second, 1), [])

    def test_someone_already_enrolled_must_match_their_profile_instead(self) -> None:
        # A Priya exists, and this voice isn't her; a second meeting calling it
        # Priya could be a different Priya, so nothing is learned.
        self.saved("Priya", [0.0, 1.0])
        self.heard("Priya", [1.0, 0.0])
        second = self.heard("Priya", with_cosine(0.9))

        self.assertEqual(self.registry.learn_from_context(second, 1), [])
        self.assertEqual(self.context_profiles(), [])

    def test_only_the_closest_partner_joins(self) -> None:
        near = self.heard("Priya", with_cosine(0.8))
        far = self.heard("Priya", with_cosine(0.6))
        meeting = self.heard("Priya", [1.0, 0.0])

        self.registry.learn_from_context(meeting, 1)

        self.assertEqual({profile[2] for profile in self.context_profiles()}, {meeting, near})
        self.assertNotIn(far, {profile[2] for profile in self.context_profiles()})


class NeverEnrollTests(ContextLearningTestCase):
    def assert_nothing_learned(self, meeting: str) -> None:
        self.assertEqual(self.registry.learn_from_context(meeting, 1), [])
        self.assertEqual(self.context_profiles(), [])

    def test_junk_voices_by_seconds_or_words(self) -> None:
        self.saved("Sam")
        self.assert_nothing_learned(self.heard("Sam", with_cosine(0.9), seconds=14.9))
        self.assert_nothing_learned(self.heard("Sam", with_cosine(0.9), words=39))
        self.assertEqual(len(self.registry.learn_from_context(self.heard("Sam", with_cosine(0.9), seconds=15.0, words=40), 1)), 1)

    def test_zero_and_non_finite_embeddings(self) -> None:
        self.saved("Sam")
        zeros = self.heard("Sam", [0.0, 0.0])
        self.assert_nothing_learned(zeros)
        broken = self.heard("Sam", [1.0, 0.0])
        with closing(sqlite3.connect(self.database)) as connection, connection:
            connection.execute("UPDATE observed_voices SET embedding_json='[NaN, 1.0]' WHERE meeting_id=?", (broken,))
        self.assert_nothing_learned(broken)

    def test_a_voice_with_no_saved_observation(self) -> None:
        self.saved("Sam")
        meeting = str(uuid.uuid4())
        self.registry.set_context_names(meeting, 1, [entry("incoming:SPEAKER_00", "Sam")], {"incoming:SPEAKER_00": (60, 200)})

        self.assert_nothing_learned(meeting)

    def test_the_microphone(self) -> None:
        self.saved("Mike Cann")
        self.assert_nothing_learned(self.heard("Mike Cann", with_cosine(0.9), speaker="microphone:SPEAKER_00"))

    def test_an_automated_voice(self) -> None:
        self.saved("AI")
        self.assert_nothing_learned(self.heard("AI", with_cosine(0.9)))

    def test_a_voice_mike_named(self) -> None:
        self.saved("Sam")
        meeting = self.heard("Sam", with_cosine(0.9))
        self.registry.confirm_observation(meeting, 1, "incoming:SPEAKER_00", "Samuel")

        self.assert_nothing_learned(meeting)
        self.assertEqual(self.profiles()[-1][:2], ("Samuel", "confirmed"))

    def test_a_voice_not_named_at_all_or_only_in_a_guess(self) -> None:
        self.saved("Sam")
        self.assert_nothing_learned(self.heard(None, with_cosine(0.9)))
        self.assert_nothing_learned(self.heard("Sam", with_cosine(0.9), confidence="low"))


class LifecycleTests(ContextLearningTestCase):
    def test_a_name_that_changes_replaces_what_the_meeting_taught(self) -> None:
        self.saved("Sam")
        self.saved("Priya", [0.0, 1.0])
        meeting = self.heard("Sam", with_cosine(0.6))
        self.registry.learn_from_context(meeting, 1)
        self.assertEqual([profile[0] for profile in self.context_profiles()], ["Sam"])

        self.registry.set_context_names(meeting, 1, [entry("incoming:SPEAKER_00", "Dana")], {"incoming:SPEAKER_00": (60, 200)})
        self.assertEqual(self.registry.learn_from_context(meeting, 1), [])

        self.assertEqual(self.context_profiles(), [], "no profile of Sam left from a voice now called Dana")

    def test_learning_twice_does_not_duplicate(self) -> None:
        self.saved("Sam")
        meeting = self.heard("Sam", with_cosine(0.6))

        self.registry.learn_from_context(meeting, 1)
        self.registry.learn_from_context(meeting, 1)

        self.assertEqual(len(self.context_profiles()), 1)

    def test_a_name_saved_later_replaces_the_automatic_profile(self) -> None:
        self.saved("Sam")
        meeting = self.heard("Sam", with_cosine(0.6))
        self.registry.learn_from_context(meeting, 1)

        self.registry.confirm_observation(meeting, 1, "incoming:SPEAKER_00", "Sam Example")

        self.assertEqual(self.context_profiles(), [])
        self.assertEqual(self.profiles()[-1], ("Sam Example", "confirmed", meeting, "incoming:SPEAKER_00"))
        self.assertEqual(len([p for p in self.profiles() if p[2] == meeting]), 1)

    def test_older_databases_gain_the_column_and_keep_their_profiles_as_confirmed(self) -> None:
        database = Path(self.temporary.name) / "old.sqlite"
        with closing(sqlite3.connect(database)) as connection, connection:
            connection.execute(
                "CREATE TABLE voice_profiles (display_name TEXT NOT NULL, embedding_json TEXT NOT NULL, "
                "confirmed_at TEXT NOT NULL, model_id TEXT NOT NULL, dimension INTEGER NOT NULL, "
                "source_meeting_id TEXT, source_revision INTEGER, source_speaker_id TEXT)",
            )
            connection.execute(
                "INSERT INTO voice_profiles VALUES ('Sam', '[1.0, 0.0]', '2026-09-01T00:00:00Z', 'm', 2, 'm1', 1, 'incoming:SPEAKER_00')",
            )

        SpeakerRegistry(database)

        with closing(sqlite3.connect(database)) as connection:
            self.assertEqual(connection.execute("SELECT source FROM voice_profiles").fetchall(), [("confirmed",)])

    def test_new_profiles_ask_other_meetings_with_unnamed_voices_to_refresh(self) -> None:
        self.saved("Sam")
        elsewhere = str(uuid.uuid4())
        self.registry.save_observation(elsewhere, 1, "incoming:SPEAKER_00", with_cosine(0.6), "model@1")
        with closing(sqlite3.connect(self.database)) as connection, connection:
            connection.execute(
                "INSERT INTO acceptances VALUES (?, 1, ?, ?, ?, ?)",
                (elsewhere, "a" * 64, "/archive", json.dumps({"meeting_id": elsewhere}), "2026-09-17T00:00:00Z"),
            )
        meeting = self.heard("Sam", with_cosine(0.6))

        self.registry.learn_from_context(meeting, 1)

        with closing(sqlite3.connect(self.database)) as connection:
            queued = connection.execute("SELECT meeting_id FROM speaker_refreshes").fetchall()
        self.assertIn((elsewhere,), queued)


class CommandTests(ContextLearningTestCase):
    def run_cli(self, *argv: str) -> dict:
        output = io.StringIO()
        with redirect_stdout(output):
            self.assertEqual(cli_main([*argv, "--db", str(self.database)]), 0)
        return json.loads(output.getvalue())

    def learn_two(self) -> tuple[str, str]:
        """Sam via a saved profile, and Priya via two meetings."""
        self.saved("Sam")
        sam = self.heard("Sam", with_cosine(0.6))
        first = self.heard("Priya", [0.0, 1.0])
        second = self.heard("Priya", [0.1, 0.995])
        for meeting in (sam, second):
            self.registry.learn_from_context(meeting, 1)
        return sam, first

    def test_list_shows_only_what_was_learned(self) -> None:
        sam, first = self.learn_two()

        profiles = self.run_cli("context-voices")["profiles"]

        self.assertEqual(sorted(p["name"] for p in profiles), ["Priya", "Priya", "Sam"])
        self.assertIn(first, {p["meeting_id"] for p in profiles})
        self.assertEqual({p["speaker_id"] for p in profiles}, {"incoming:SPEAKER_00"})

    def test_forget_removes_all_or_by_name_or_meeting_and_never_saved_profiles(self) -> None:
        sam, first = self.learn_two()
        self.assertEqual(self.run_cli("forget-context-voices", "--name", "priya")["removed"], 2)
        self.assertEqual([p[0] for p in self.context_profiles()], ["Sam"])
        self.assertEqual(self.run_cli("forget-context-voices", "--meeting-id", str(uuid.uuid4()))["removed"], 0)
        self.assertEqual(self.run_cli("forget-context-voices", "--meeting-id", sam.upper())["removed"], 1)
        self.learn_two()
        result = self.run_cli("forget-context-voices")
        self.assertGreaterEqual(result["removed"], 3)
        self.assertEqual(self.context_profiles(), [])
        self.assertEqual({p[0] for p in self.profiles() if p[1] == "confirmed"}, {"Sam"}, "Mike's own survives")

    def test_forget_queues_a_refresh_of_every_meeting_with_an_unnamed_voice(self) -> None:
        sam, _ = self.learn_two()
        with closing(sqlite3.connect(self.database)) as connection, connection:
            connection.execute(
                "INSERT INTO acceptances VALUES (?, 1, ?, ?, ?, ?)",
                (sam, "a" * 64, "/archive", json.dumps({"meeting_id": sam}), "2026-09-17T00:00:00Z"),
            )
            connection.execute("DELETE FROM speaker_refreshes")

        result = self.run_cli("forget-context-voices")

        self.assertGreaterEqual(result["refreshes_queued"], 1)
        with closing(sqlite3.connect(self.database)) as connection:
            self.assertIn((sam,), connection.execute("SELECT meeting_id FROM speaker_refreshes").fetchall())

    def test_learn_again_after_forgetting(self) -> None:
        self.learn_two()
        self.run_cli("forget-context-voices")

        enrolled = self.run_cli("learn-context-voices")["enrolled"]

        self.assertEqual({item["name"] for item in enrolled}, {"Priya", "Sam"})
        self.assertEqual(len(self.context_profiles()), 3)


if __name__ == "__main__":
    unittest.main()
