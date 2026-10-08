"""Naming voices from the conversation, with urllib's urlopen standing in for OpenRouter."""

from __future__ import annotations

import io
import json
import os
import sqlite3
import sys
import tempfile
import unittest
from contextlib import closing, redirect_stdout
from pathlib import Path
from unittest.mock import patch


WORKER_ROOT = Path(__file__).resolve().parents[1] / "worker"
sys.path.insert(0, str(WORKER_ROOT))

from meeting_archive_worker.cli import main as cli_main  # noqa: E402
from meeting_archive_worker.naming import (  # noqa: E402
    OUTPUT_SCHEMA,
    SYSTEM_PROMPT,
    NamingQueue,
    OpenRouterNamer,
    build_naming_prompt,
    name_archive,
    naming_enabled,
    naming_is_stale,
    naming_model,
    read_naming,
)
from meeting_archive_worker.queue import JobQueue  # noqa: E402
from meeting_archive_worker.service import run_naming, run_once, run_summary  # noqa: E402
from meeting_archive_worker.speaker_refresh import reconcile_speaker_refresh  # noqa: E402
from meeting_archive_worker.speakers import SpeakerRegistry  # noqa: E402
from meeting_archive_worker.summaries import (  # noqa: E402
    DEFAULT_MODEL,
    SummaryQueue,
    TransientSummaryError,
)
from meeting_archive_worker.titles import apply_generated_title  # noqa: E402

from test_summaries import (  # noqa: E402
    API_KEY,
    MEETING_ID,
    FakeOpenRouter,
    completion,
    http_error,
    write_meeting,
)
from test_summaries import ANSWER as SUMMARY_ANSWER  # noqa: E402


def entry(speaker: str, name: str | None, confidence: str = "high", evidence: str = "I'm Sam") -> dict:
    return {"speaker": speaker, "name": name, "confidence": confidence, "evidence": evidence}


NAMES = {
    "speakers": [
        entry("microphone:SPEAKER_00", "Mike Cann", "high", "Morning Sam"),
        entry("incoming:SPEAKER_00", "Sam", "high", "Thanks, Sam"),
        entry("incoming:SPEAKER_01", "Priya", "medium", "Priya, can you share"),
        entry("incoming:SPEAKER_02", None, "low", "only says okay"),
    ],
}


def words(count: int) -> str:
    return " ".join(["word"] * count)


# Raw labels only: no turn has a name unless a test adds one.
TURNS = [
    {"start": 1.0, "end": 3.0, "speaker": "microphone:SPEAKER_00", "channel_origin": "microphone",
     "text": "Morning Sam, shall we go through the budget?"},
    {"start": 4.0, "end": 25.0, "speaker": "incoming:SPEAKER_00", "channel_origin": "incoming",
     "text": "Yes. I'm Sam. " + words(45)},
    {"start": 26.0, "end": 30.0, "speaker": "incoming:SPEAKER_01", "channel_origin": "incoming",
     "text": "Hello from the other side."},
    {"start": 75.0, "end": 76.0, "speaker": "incoming:SPEAKER_02", "channel_origin": "incoming",
     "text": "Okay."},
]


class NamingTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.database = self.root / "worker.sqlite"
        self.archive = write_meeting(self.root, turns=TURNS)
        self.registry = SpeakerRegistry(self.database)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def name(self, *outcomes, model: str = DEFAULT_MODEL, archive: Path | None = None):
        openrouter = FakeOpenRouter(*outcomes)
        with patch("urllib.request.urlopen", openrouter):
            result = name_archive(archive or self.archive, OpenRouterNamer(API_KEY, model=model), self.registry)
        return result, openrouter

    def metadata(self) -> dict:
        return json.loads((self.archive / "metadata.json").read_text(encoding="utf-8"))

    def transcript(self) -> dict:
        return json.loads((self.archive / "transcripts" / "v1" / "transcript.json").read_text(encoding="utf-8"))

    def write_transcript(self, transcript: dict) -> None:
        (self.archive / "transcripts" / "v1" / "transcript.json").write_text(json.dumps(transcript), encoding="utf-8")


class PromptTests(NamingTestCase):
    def test_prompt_has_details_a_roster_and_raw_labelled_lines(self) -> None:
        prompt = build_naming_prompt(self.metadata(), self.transcript())

        self.assertEqual(prompt, "\n".join([
            "Meeting details",
            "- App: Zoom",
            "- Length: 47 minutes",
            "- Recorded by: Mike Cann",
            "- Calendar attendees: Sam Example",
            "",
            "Speakers",
            "- incoming:SPEAKER_00: 1 turn, 48 words",
            "- incoming:SPEAKER_01: 1 turn, 5 words",
            "- incoming:SPEAKER_02: 1 turn, 1 word",
            "- microphone:SPEAKER_00: 1 turn, 8 words",
            "",
            "Transcript",
            "[0:01] microphone:SPEAKER_00: Morning Sam, shall we go through the budget?",
            f"[0:04] incoming:SPEAKER_00: Yes. I'm Sam. {words(45)}",
            "[0:26] incoming:SPEAKER_01: Hello from the other side.",
            "[1:15] incoming:SPEAKER_02: Okay.",
            "",
        ]))

    def test_names_already_on_the_transcript_never_reach_the_prompt(self) -> None:
        before = build_naming_prompt(self.metadata(), self.transcript())
        named = self.transcript()
        for turn in named["turns"]:
            turn.update(name="Somebody Else", name_source="context")

        after = build_naming_prompt(self.metadata(), named)

        self.assertEqual(before, after)
        self.assertNotIn("Somebody Else", after)

    def test_a_title_someone_chose_is_context_but_the_ai_title_is_not(self) -> None:
        self.assertNotIn("- Title:", build_naming_prompt(self.metadata(), self.transcript()))
        chosen = write_meeting(self.root / "chosen", turns=TURNS, title="Acme catch up", title_source="calendar")
        metadata = json.loads((chosen / "metadata.json").read_text(encoding="utf-8"))
        self.assertIn("- Title: Acme catch up\n", build_naming_prompt(metadata, self.transcript(), given_title="Acme catch up"))
        # The summary writes an AI title after naming; reading it would change
        # the prompt, and so rename the same meeting twice.
        apply_generated_title(self.archive, "Budget revision with Priya", self.metadata(), model="test")
        openrouter = FakeOpenRouter(completion(NAMES))
        with patch("urllib.request.urlopen", openrouter):
            name_archive(self.archive, OpenRouterNamer(API_KEY), self.registry)
        self.assertNotIn("Budget revision", openrouter.prompt())

    def test_a_meeting_nobody_spoke_in_is_not_sent(self) -> None:
        empty = write_meeting(self.root / "empty", turns=[{"start": 0, "end": 1, "text": "  "}])

        result, openrouter = self.name(archive=empty)

        self.assertEqual(result, {"naming_written": False, "names": 0, "reason": "no_speech"})
        self.assertEqual(openrouter.requests, [])


class RequestTests(NamingTestCase):
    def test_request_is_the_summarys_with_the_naming_prompt_and_schema(self) -> None:
        _, openrouter = self.name(completion(NAMES))

        request = openrouter.requests[0]
        self.assertEqual(request["url"], "https://openrouter.ai/api/v1/chat/completions")
        self.assertEqual(request["headers"]["authorization"], f"Bearer {API_KEY}")
        self.assertIn("authorization", request["unredirected"])
        body = request["body"]
        self.assertEqual(body["model"], "anthropic/claude-opus-5.5")
        self.assertEqual(body["reasoning"], {"effort": "low"})
        self.assertEqual(body["usage"], {"include": True})
        self.assertEqual(body["provider"], {"require_parameters": True})
        self.assertEqual(body["response_format"], {
            "type": "json_schema",
            "json_schema": {"name": "speaker_names", "strict": True, "schema": OUTPUT_SCHEMA},
        })
        self.assertEqual(body["messages"][0], {"role": "system", "content": SYSTEM_PROMPT})
        self.assertEqual(body["messages"][1]["content"], build_naming_prompt(self.metadata(), self.transcript()))
        self.assertEqual(set(OUTPUT_SCHEMA["properties"]["speakers"]["items"]["required"]), {"speaker", "name", "confidence", "evidence"})
        self.assertIn("a wrong name is much worse than null", SYSTEM_PROMPT)
        self.assertNotIn(chr(0x2014), SYSTEM_PROMPT)

    def test_the_model_is_chosen_like_the_summarys(self) -> None:
        self.assertEqual(naming_model({}), "anthropic/claude-opus-5.5")
        self.assertEqual(naming_model({"MEETING_ARCHIVE_NAMING_MODEL": "  "}), "anthropic/claude-opus-5.5")
        self.assertEqual(naming_model({"MEETING_ARCHIVE_NAMING_MODEL": " openai/gpt-6 "}), "openai/gpt-6")
        # The summary's setting does not change which model names voices.
        self.assertEqual(naming_model({"MEETING_ARCHIVE_SUMMARY_MODEL": "openai/gpt-6"}), "anthropic/claude-opus-5.5")
        self.assertFalse(naming_enabled({}))
        self.assertTrue(naming_enabled({"OPENROUTER_API_KEY": API_KEY}))

    def test_failures_sort_like_the_summarys(self) -> None:
        for error, name in (
            (http_error(401, "User not found."), "PermanentSummaryError"),
            (http_error(429, "Slow down"), "TransientSummaryError"),
            (http_error(402, "No credits"), "TransientSummaryError"),
        ):
            with self.assertRaises(Exception) as caught:
                self.name(error)
            self.assertEqual(type(caught.exception).__name__, name)

    def test_an_answer_outside_the_schema_is_asked_for_once_more_then_permanent(self) -> None:
        for bad in (
            {"speakers": "nobody"},
            {"speakers": [entry("incoming:SPEAKER_00", "Sam", "certain")]},
            {"speakers": [{"speaker": "incoming:SPEAKER_00", "name": "Sam"}]},
            {"names": []},
        ):
            with self.subTest(bad=bad):
                result, openrouter = self.name(completion(bad), completion(NAMES))
                self.assertEqual(len(openrouter.requests), 2)
                self.assertTrue(result["naming_written"])
                (self.archive / "transcripts" / "v1" / "naming.json").unlink()
        with self.assertRaises(Exception) as caught:
            self.name(completion({"names": []}), completion({"names": []}))
        self.assertEqual(type(caught.exception).__name__, "PermanentSummaryError")


class NamingFileTests(NamingTestCase):
    def test_names_are_saved_with_what_they_cost_and_only_confident_ones_are_kept(self) -> None:
        result, _ = self.name(completion(NAMES))

        self.assertEqual(result, {"naming_written": True, "names": 3, "voices_learned": 0})
        naming = read_naming(self.archive, self.metadata())
        self.assertEqual(naming["model"], "anthropic/claude-opus-5.5")
        self.assertEqual(len(naming["input_sha256"]), 64)
        self.assertEqual(naming["speakers"], NAMES["speakers"])
        self.assertEqual(naming["usage"]["requests"], 1)
        self.assertNotIn(API_KEY, (self.archive / "transcripts" / "v1" / "naming.json").read_text(encoding="utf-8"))
        stored = self.registry.context_names(MEETING_ID, 1)
        self.assertEqual({speaker: row["name"] for speaker, row in stored.items()}, {
            "microphone:SPEAKER_00": "Mike Cann", "incoming:SPEAKER_00": "Sam", "incoming:SPEAKER_01": "Priya",
        })
        self.assertEqual(stored["incoming:SPEAKER_01"]["confidence"], "medium")
        self.assertEqual(stored["incoming:SPEAKER_00"]["evidence"], "Thanks, Sam")
        self.assertEqual(stored["incoming:SPEAKER_00"]["word_count"], 48)
        self.assertEqual(stored["incoming:SPEAKER_00"]["speech_seconds"], 21.0)

    def test_low_confidence_and_invented_speakers_are_not_kept(self) -> None:
        answer = {"speakers": [
            entry("incoming:SPEAKER_00", "Sam", "low"),
            entry("incoming:SPEAKER_09", "Ghost", "high"),
            entry("incoming:SPEAKER_01", "Priya", "high"),
            entry("incoming:SPEAKER_01", "Someone Else", "high"),
            entry("incoming:SPEAKER_02", None, "high"),
            entry("microphone:SPEAKER_00", "x" * 101, "high"),
        ]}

        result, _ = self.name(completion(answer))

        self.assertEqual(result["names"], 1)
        self.assertEqual(
            {speaker: row["name"] for speaker, row in self.registry.context_names(MEETING_ID, 1).items()},
            {"incoming:SPEAKER_01": "Priya"},
        )

    def test_the_same_transcript_is_not_paid_for_twice_but_names_are_saved_again(self) -> None:
        self.name(completion(NAMES))
        with closing(sqlite3.connect(self.database)) as connection, connection:
            connection.execute("DELETE FROM context_names")

        result, openrouter = self.name()

        self.assertEqual(result, {"naming_written": False, "names": 3, "voices_learned": 0})
        self.assertEqual(openrouter.requests, [])
        self.assertEqual(len(self.registry.context_names(MEETING_ID, 1)), 3)

    def test_a_changed_transcript_or_model_is_asked_afresh_and_replaces_the_names(self) -> None:
        self.name(completion(NAMES))
        changed = self.transcript()
        changed["turns"][2]["text"] = "Hello, this is Priya Example."
        self.write_transcript(changed)

        result, openrouter = self.name(completion({"speakers": [entry("incoming:SPEAKER_01", "Priya Example", "high")]}))

        self.assertTrue(result["naming_written"])
        self.assertEqual(len(openrouter.requests), 1)
        self.assertEqual(
            {speaker: row["name"] for speaker, row in self.registry.context_names(MEETING_ID, 1).items()},
            {"incoming:SPEAKER_01": "Priya Example"},
        )
        result, openrouter = self.name(completion(NAMES), model="openai/gpt-6")
        self.assertTrue(result["naming_written"])
        self.assertEqual(openrouter.bodies[0]["model"], "openai/gpt-6")

    def test_naming_is_stale_only_when_the_request_would_differ(self) -> None:
        self.assertTrue(naming_is_stale(self.archive, DEFAULT_MODEL), "never named")
        self.name(completion(NAMES))
        self.assertFalse(naming_is_stale(self.archive, DEFAULT_MODEL))
        named = self.transcript()
        for turn in named["turns"]:
            turn.update(name="Somebody", name_source="context")
        self.write_transcript(named)
        self.assertFalse(naming_is_stale(self.archive, DEFAULT_MODEL), "writing names changes nothing it reads")
        self.assertTrue(naming_is_stale(self.archive, "openai/gpt-6"))
        named["turns"][1]["text"] = "Different words."
        self.write_transcript(named)
        self.assertTrue(naming_is_stale(self.archive, DEFAULT_MODEL))


class VoiceMatchTests(NamingTestCase):
    """What the stored names do to a meeting's speaker_matches."""

    def setUp(self) -> None:
        super().setUp()
        for speaker, vector in {
            "microphone:SPEAKER_00": [1.0, 0.0, 0.0],
            "incoming:SPEAKER_00": [0.0, 1.0, 0.0],
            "incoming:SPEAKER_01": [0.0, 0.0, 1.0],
        }.items():
            self.registry.save_observation(MEETING_ID, 1, speaker, vector, "model@1")
        self.speakers = [turn["speaker"] for turn in TURNS]
        self.registry.set_context_names(MEETING_ID, 1, NAMES["speakers"], {})

    def matches(self) -> dict:
        return self.registry.meeting_matches(MEETING_ID, 1, self.speakers)

    def test_an_unnamed_voice_gets_the_name_the_conversation_gave_it(self) -> None:
        match = self.matches()["incoming:SPEAKER_00"]

        self.assertEqual(match["automatic_name"], "Sam")
        self.assertEqual(match["suggestion_kind"], "context")
        self.assertEqual(match["context_name"], "Sam")
        self.assertEqual(match["context_confidence"], "high")
        self.assertEqual(match["context_evidence"], "Thanks, Sam")
        self.assertEqual(self.matches()["incoming:SPEAKER_01"]["context_confidence"], "medium")

    def test_a_voice_with_no_embedding_is_still_named(self) -> None:
        # incoming:SPEAKER_02 has none, and was not named; give it a name.
        self.registry.set_context_names(MEETING_ID, 1, [entry("incoming:SPEAKER_02", "Kim", "high")], {})

        match = self.matches()["incoming:SPEAKER_02"]

        self.assertEqual((match["automatic_name"], match["suggestion_kind"]), ("Kim", "context"))

    def test_a_saved_name_always_wins(self) -> None:
        self.registry.confirm_observation(MEETING_ID, 1, "incoming:SPEAKER_00", "Samuel")

        match = self.matches()["incoming:SPEAKER_00"]

        self.assertIsNone(match["automatic_name"])
        self.assertNotIn("context_name", match)

    def test_a_voice_match_wins_over_a_conflicting_context_name(self) -> None:
        for index in range(2):
            self.registry.save_observation(f"other-{index}", 1, "incoming:SPEAKER_00", [0.0, 1.0, 0.0], "model@1")
            self.registry.confirm_observation(f"other-{index}", 1, "incoming:SPEAKER_00", "Samuel")

        match = self.matches()["incoming:SPEAKER_00"]

        self.assertEqual((match["automatic_name"], match["suggestion_kind"]), ("Samuel", "strong"))
        self.assertEqual(match["context_name"], "Sam", "kept as evidence")

    def test_a_tentative_voice_suggestion_does_not_hold_back_the_conversation(self) -> None:
        for index, meeting in enumerate(("other-0", "other-1")):
            vector = [0.0, 0.7, 0.714]
            self.registry.save_observation(meeting, 1, "incoming:SPEAKER_00", vector, "model@1")
            self.registry.confirm_observation(meeting, 1, "incoming:SPEAKER_00", "Samuel")

        match = self.matches()["incoming:SPEAKER_00"]

        self.assertEqual(match["suggestion_kind"], "context")
        self.assertEqual(match["automatic_name"], "Sam")

    def test_turns_carry_the_name_and_where_it_came_from(self) -> None:
        from meeting_archive_worker.speaker_evidence import automatic_names, refresh_speaker_matches

        transcript = self.transcript()
        refresh_speaker_matches(transcript, self.registry)

        sam = next(turn for turn in transcript["turns"] if turn["speaker"] == "incoming:SPEAKER_00")
        self.assertEqual((sam["name"], sam["name_source"]), ("Sam", "context"))
        okay = next(turn for turn in transcript["turns"] if turn["speaker"] == "incoming:SPEAKER_02")
        self.assertNotIn("name", okay)
        self.assertEqual(automatic_names(transcript), {
            "microphone:SPEAKER_00": "Mike Cann", "incoming:SPEAKER_00": "Sam", "incoming:SPEAKER_01": "Priya",
        })


class FakeServiceTestCase(NamingTestCase):
    """Naming and the summary through the service's stages."""

    def setUp(self) -> None:
        super().setUp()
        self.queue = JobQueue(self.database)
        self.job_id = self.queue.enqueue(MEETING_ID, 1, "a" * 64, str(self.archive))
        self.queue.complete(self.queue.claim_ready("worker", 60))  # type: ignore[arg-type]
        acknowledgement = {
            "schema_version": 1, "meeting_id": MEETING_ID, "manifest_revision": 1,
            "manifest_sha256": "a" * 64, "archive_path": str(self.archive), "queue_job_id": str(self.job_id),
        }
        with closing(sqlite3.connect(self.database)) as connection, connection:
            connection.execute(
                "INSERT INTO acceptances VALUES (?, ?, ?, ?, ?, ?)",
                (MEETING_ID, 1, "a" * 64, str(self.archive), json.dumps(acknowledgement), "2026-09-17T00:00:00Z"),
            )
        for speaker, vector in {"incoming:SPEAKER_00": [0.0, 1.0], "incoming:SPEAKER_01": [1.0, 0.0]}.items():
            self.registry.save_observation(MEETING_ID, 1, speaker, vector, "model@1")
        # The transcript the processor wrote: automatic names, if any, are in
        # place; here there are none yet.
        self.environment = patch.dict(os.environ, {"OPENROUTER_API_KEY": API_KEY})
        self.environment.start()
        os.environ.pop("MEETING_ARCHIVE_NAMING_MODEL", None)
        os.environ.pop("MEETING_ARCHIVE_SUMMARY_MODEL", None)

    def tearDown(self) -> None:
        self.environment.stop()
        super().tearDown()

    def naming_job(self) -> dict:
        return NamingQueue(self.database).status({self.job_id})["jobs"][0]

    def summary_job(self) -> dict:
        return SummaryQueue(self.database).status({self.job_id})["jobs"][0]

    def run_naming(self, *outcomes) -> tuple[bool, FakeOpenRouter]:
        openrouter = FakeOpenRouter(*outcomes)
        with patch("urllib.request.urlopen", openrouter):
            return run_naming(self.database), openrouter

    def run_summary(self, *outcomes) -> tuple[bool, FakeOpenRouter]:
        openrouter = FakeOpenRouter(*outcomes)
        with patch("urllib.request.urlopen", openrouter):
            return run_summary(self.database), openrouter


class NamingStageTests(FakeServiceTestCase):
    def test_run_once_names_the_meeting_before_its_summary(self) -> None:
        summarized: list[Path] = []
        with patch("urllib.request.urlopen", FakeOpenRouter(completion(NAMES))):
            result = run_once(
                self.database, processor=lambda *_: None, publisher=lambda *_: None,
                summarize=summarized.append,
            )

        self.assertEqual(self.naming_job()["state"], "succeeded")
        self.assertTrue(result["summarized"])
        self.assertEqual(summarized, [self.archive])

    def test_without_a_key_nothing_is_queued_or_run(self) -> None:
        os.environ.pop("OPENROUTER_API_KEY")
        openrouter = FakeOpenRouter()
        with patch("urllib.request.urlopen", openrouter):
            self.assertFalse(run_naming(self.database))
            self.assertFalse(run_summary(self.database))

        self.assertEqual(openrouter.requests, [])
        self.assertEqual(NamingQueue(self.database).status()["jobs"], [])

    def test_names_reach_the_transcript_the_markdown_and_notion_straight_away(self) -> None:
        ran, openrouter = self.run_naming(completion(NAMES))

        self.assertTrue(ran)
        self.assertEqual(self.naming_job()["state"], "succeeded")
        transcript = self.transcript()
        by_speaker = {turn["speaker"]: turn for turn in transcript["turns"]}
        self.assertEqual(
            (by_speaker["incoming:SPEAKER_00"]["name"], by_speaker["incoming:SPEAKER_00"]["name_source"]),
            ("Sam", "context"),
        )
        self.assertEqual(by_speaker["microphone:SPEAKER_00"]["name"], "Mike Cann")
        self.assertNotIn("name", by_speaker["incoming:SPEAKER_02"])
        match = transcript["speaker_matches"]["incoming:SPEAKER_01"]
        self.assertEqual((match["context_name"], match["context_confidence"]), ("Priya", "medium"))
        self.assertEqual(match["context_evidence"], "Priya, can you share")
        markdown = (self.archive / "transcripts" / "v1" / "transcript.md").read_text(encoding="utf-8")
        self.assertIn("**Sam** [4.0s]", markdown)
        from meeting_archive_worker.service import PublicationQueue

        self.assertEqual(PublicationQueue(self.database).status({self.job_id})["jobs"][0]["state"], "ready")

    def test_the_summary_waits_for_naming_and_then_uses_the_names(self) -> None:
        # Naming is queued by the summary's pass, so the summary can't jump the queue.
        ran, openrouter = self.run_summary(completion(SUMMARY_ANSWER))
        self.assertFalse(ran)
        self.assertEqual(openrouter.requests, [])
        self.assertEqual(self.naming_job()["state"], "ready")

        self.run_naming(completion(NAMES))
        ran, openrouter = self.run_summary(completion(SUMMARY_ANSWER))

        self.assertTrue(ran)
        prompt = openrouter.prompt()
        self.assertIn("] Sam: Yes. I'm Sam.", prompt)
        self.assertIn("] Mike Cann: Morning Sam", prompt)
        self.assertNotIn("Remote speaker 1", prompt)
        self.assertEqual(self.summary_job()["state"], "succeeded")

    def check_failed_naming_does_not_block_the_summary(self, outcome, state: str) -> None:
        ran, _ = self.run_naming(outcome)
        self.assertFalse(ran)
        self.assertEqual(self.naming_job()["state"], state)

        ran, openrouter = self.run_summary(completion(SUMMARY_ANSWER))

        self.assertTrue(ran)
        self.assertIn("Remote speaker 1", openrouter.prompt(), "no names to use")

    def test_naming_waiting_to_retry_never_blocks_the_summary(self) -> None:
        self.check_failed_naming_does_not_block_the_summary(http_error(503, "No provider"), "retry_wait")

    def test_naming_that_failed_for_good_never_blocks_the_summary(self) -> None:
        self.check_failed_naming_does_not_block_the_summary(http_error(401, "User not found."), "permanent_failure")

    def test_names_that_arrive_later_ask_for_the_summary_again_at_once(self) -> None:
        self.run_naming(http_error(503, "No provider"))
        self.run_summary(completion(SUMMARY_ANSWER))
        self.assertEqual(self.summary_job()["state"], "succeeded")
        with closing(sqlite3.connect(self.database)) as connection, connection:
            connection.execute("UPDATE naming_jobs SET available_at=0")

        ran, _ = self.run_naming(completion(NAMES))

        self.assertTrue(ran)
        job = self.summary_job()
        self.assertEqual(job["state"], "ready")
        self.assertLess(job["available_at"], self.queue_clock() + 5, "not the five minute wait for hand-typed names")

    def test_a_failed_refresh_after_naming_still_asks_for_the_summary_at_once(self) -> None:
        self.run_naming(http_error(503, "No provider"))
        self.run_summary(completion(SUMMARY_ANSWER))
        with closing(sqlite3.connect(self.database)) as connection, connection:
            connection.execute("UPDATE naming_jobs SET available_at=0")

        with patch("meeting_archive_worker.speaker_evidence.refresh_speaker_matches", side_effect=OSError("locked")), \
                patch("sys.stderr", io.StringIO()):
            self.run_naming(completion(NAMES))
        self.assertEqual(self.summary_job()["state"], "succeeded", "the refresh failed, so no request yet")
        with closing(sqlite3.connect(self.database)) as connection, connection:
            connection.execute("UPDATE speaker_refreshes SET retry_after=NULL")

        self.assertTrue(reconcile_speaker_refresh(self.database, MEETING_ID, 1))

        job = self.summary_job()
        self.assertEqual(job["state"], "ready")
        self.assertLess(job["available_at"], self.queue_clock() + 5)

    def queue_clock(self) -> float:
        import time

        return time.time()

    def test_naming_then_refreshing_does_not_loop(self) -> None:
        self.run_naming(completion(NAMES))
        self.assertEqual(self.naming_job()["state"], "succeeded")

        self.registry.request_refresh(MEETING_ID, 1)
        self.assertTrue(reconcile_speaker_refresh(self.database, MEETING_ID, 1))

        self.assertEqual(self.naming_job()["state"], "succeeded", "names don't change what naming reads")
        ran, openrouter = self.run_naming()
        self.assertFalse(ran)
        self.assertEqual(openrouter.requests, [])
        self.assertEqual(self.naming_job()["attempts"], 1)

    def test_a_rewritten_transcript_is_named_again_after_a_refresh(self) -> None:
        self.run_naming(completion(NAMES))
        changed = self.transcript()
        changed["turns"][2]["text"] = "Hello, this is Priya Example."
        self.write_transcript(changed)

        self.registry.request_refresh(MEETING_ID, 1)
        self.assertTrue(reconcile_speaker_refresh(self.database, MEETING_ID, 1))

        self.assertEqual(self.naming_job()["state"], "ready")
        ran, openrouter = self.run_naming(completion({"speakers": [entry("incoming:SPEAKER_01", "Priya Example", "high")]}))
        self.assertTrue(ran)
        self.assertEqual(len(openrouter.requests), 1)
        self.assertIn("Priya Example", {turn.get("name") for turn in self.transcript()["turns"]})

    def test_a_saved_name_beats_the_conversations_in_the_transcript(self) -> None:
        self.registry.confirm_observation(MEETING_ID, 1, "incoming:SPEAKER_00", "Samuel")
        reconcile_speaker_refresh(self.database, MEETING_ID, 1)

        self.run_naming(completion(NAMES))

        sam = next(turn for turn in self.transcript()["turns"] if turn["speaker"] == "incoming:SPEAKER_00")
        self.assertEqual((sam["name"], sam["name_source"]), ("Samuel", "confirmed"))

    def test_a_transient_failure_backs_off_like_the_summary(self) -> None:
        ran, _ = self.run_naming(http_error(429, "Slow down", headers={"Retry-After": "600"}))

        self.assertFalse(ran)
        job = self.naming_job()
        self.assertEqual((job["state"], job["attempts"]), ("retry_wait", 1))
        self.assertIn("HTTP 429", job["last_error"])
        self.assertGreaterEqual(job["available_at"] - self.queue_clock(), 590)

    def test_a_high_name_that_the_voice_agrees_with_is_learned_and_a_medium_one_is_not(self) -> None:
        other = "44444444-4444-4444-8444-444444444444"
        self.registry.save_observation(other, 1, "incoming:SPEAKER_00", [0.0, 1.0], "model@1")
        self.registry.confirm_observation(other, 1, "incoming:SPEAKER_00", "Sam")

        self.run_naming(completion(NAMES))

        with closing(sqlite3.connect(self.database)) as connection:
            learned = connection.execute(
                "SELECT display_name, source_speaker_id FROM voice_profiles WHERE source='context'",
            ).fetchall()
        # Sam is high and sounds like Sam; Priya is only medium.
        self.assertEqual(learned, [("Sam", "incoming:SPEAKER_00")])

    def test_the_naming_model_can_be_chosen(self) -> None:
        os.environ["MEETING_ARCHIVE_NAMING_MODEL"] = "openai/gpt-6"

        _, openrouter = self.run_naming(completion(NAMES, model="openai/gpt-6"))

        self.assertEqual(openrouter.bodies[0]["model"], "openai/gpt-6")


class NamingCommandTests(FakeServiceTestCase):
    def run_cli(self, *argv: str) -> dict:
        output = io.StringIO()
        with redirect_stdout(output):
            self.assertEqual(cli_main(list(argv)), 0)
        return json.loads(output.getvalue())

    def test_name_speakers_queues_every_meeting_or_the_ones_asked_for(self) -> None:
        self.run_naming(completion(NAMES))
        self.assertEqual(self.naming_job()["state"], "succeeded")

        result = self.run_cli("name-speakers", "--db", str(self.database))

        self.assertEqual(result["queued"], [{"meeting_id": MEETING_ID, "manifest_revision": 1}])
        self.assertEqual(self.naming_job()["state"], "ready")
        # Asking again for a transcript that hasn't changed is free.
        ran, openrouter = self.run_naming()
        self.assertTrue(ran)
        self.assertEqual(openrouter.requests, [])
        other = "33333333-3333-4333-8333-333333333333"
        self.assertEqual(self.run_cli("name-speakers", "--meeting-id", other, "--db", str(self.database))["queued"], [])

    def test_name_speakers_does_not_claim_a_failed_job_was_queued(self) -> None:
        self.run_naming(http_error(401, "User not found."))
        self.assertEqual(self.naming_job()["state"], "permanent_failure")

        result = self.run_cli("name-speakers", "--db", str(self.database))

        self.assertEqual(result["queued"], [])
        self.assertEqual(result["needs_retry"], [{"meeting_id": MEETING_ID, "manifest_revision": 1}])
        self.assertIn("retry", result["message"])
        self.assertEqual(self.naming_job()["state"], "permanent_failure")

    def test_status_and_retry_cover_naming(self) -> None:
        self.run_naming(http_error(401, "User not found."))
        self.assertEqual(self.naming_job()["state"], "permanent_failure")

        status = self.run_cli("status", "--db", str(self.database))
        self.assertEqual(status["naming"]["phase"], "permanent_failure")
        retried = self.run_cli("retry", "--meeting-id", MEETING_ID, "--db", str(self.database))

        self.assertTrue(retried["retried"])
        self.assertEqual(retried["naming"]["state"], "ready")


if __name__ == "__main__":
    unittest.main()
