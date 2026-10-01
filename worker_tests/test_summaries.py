"""AI titles and summaries, with a stand-in for the anthropic SDK: no network, no key."""

from __future__ import annotations

import io
import json
import os
import sqlite3
import sys
import tempfile
import types
import unittest
import uuid
from contextlib import closing, redirect_stdout
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch


WORKER_ROOT = Path(__file__).resolve().parents[1] / "worker"
sys.path.insert(0, str(WORKER_ROOT))

from meeting_archive_worker.cli import main as cli_main  # noqa: E402
from meeting_archive_worker.queue import MAX_ATTEMPTS, JobQueue  # noqa: E402
from meeting_archive_worker.service import PublicationQueue, run_once, run_summary  # noqa: E402
from meeting_archive_worker.summaries import (  # noqa: E402
    FALLBACK_BETA,
    LONG_MAX_TOKENS,
    MAX_TOKENS,
    MODEL,
    ClaudeSummarizer,
    PermanentSummaryError,
    SummaryQueue,
    TransientSummaryError,
    build_prompt,
    read_summary,
    summaries_disabled_reason,
    summarize_archive,
)
from meeting_archive_worker.titles import effective_title, write_title  # noqa: E402


MEETING_ID = "22222222-2222-4222-8222-222222222222"
ANSWER = {
    "title": "Budget revision with Sam",
    "summary": ["Sam is revising the budget.", "The deck needs updating too."],
    "action_items": ["Sam to send the revised numbers by Friday."],
}


def fake_anthropic() -> types.ModuleType:
    """The parts of the anthropic package the summarizer touches, with the SDK's hierarchy."""
    module = types.ModuleType("anthropic")

    class APIError(Exception):
        def __init__(self, message: str = "error") -> None:
            super().__init__(message)
            self.message = message

    class APIStatusError(APIError):
        status_code = 0

        def __init__(self, message: str = "error", status_code: int | None = None) -> None:
            super().__init__(message)
            if status_code is not None:
                self.status_code = status_code

    class APIConnectionError(APIError):
        pass

    module.APIError = APIError
    module.APIStatusError = APIStatusError
    module.APIConnectionError = APIConnectionError
    module.APITimeoutError = type("APITimeoutError", (APIConnectionError,), {})
    for name, code in (
        ("BadRequestError", 400), ("AuthenticationError", 401), ("PermissionDeniedError", 403),
        ("NotFoundError", 404), ("RateLimitError", 429), ("InternalServerError", 500),
        ("OverloadedError", 529),
    ):
        setattr(module, name, type(name, (APIStatusError,), {"status_code": code}))
    module.constructed = []
    module.client = None

    def construct(**kwargs):
        module.constructed.append(kwargs)
        return module.client

    module.Anthropic = construct
    return module


class FakeClient:
    def __init__(self, *outcomes) -> None:
        self.outcomes = list(outcomes)
        self.calls: list[dict] = []
        self.closed = False
        self.beta = SimpleNamespace(messages=SimpleNamespace(create=self._create))

    def __enter__(self):
        return self

    def __exit__(self, *_exception) -> None:
        self.closed = True

    def _create(self, **kwargs):
        self.calls.append(kwargs)
        outcome = self.outcomes.pop(0)
        if isinstance(outcome, BaseException):
            raise outcome
        return outcome


def response(answer=ANSWER, *, stop_reason="end_turn", stop_details=None, model=MODEL, text=None):
    content = [] if stop_reason == "refusal" else [
        SimpleNamespace(type="thinking", thinking=""),
        SimpleNamespace(type="text", text=text if text is not None else json.dumps(answer)),
    ]
    return SimpleNamespace(
        stop_reason=stop_reason,
        stop_details=stop_details,
        content=content,
        model=model,
        usage=SimpleNamespace(input_tokens=1200, output_tokens=300),
    )


TURNS = [
    {"start": 1.0, "end": 3.0, "speaker": "microphone:SPEAKER_00", "name": "Mike Cann",
     "channel_origin": "microphone", "text": "Morning Sam, shall we go through the budget?"},
    {"start": 4.0, "end": 9.0, "speaker": "incoming:SPEAKER_00", "channel_origin": "incoming",
     "text": "Yes. I'll send the revised numbers by Friday."},
    {"start": 10.0, "end": 12.0, "speaker": "incoming:SPEAKER_00", "channel_origin": "incoming",
     "text": "  And the   deck too. "},
    {"start": 75.0, "end": 80.0, "speaker": "incoming:SPEAKER_01", "channel_origin": "incoming",
     "text": "Thanks both."},
]


def write_meeting(root: Path, *, turns=None, **metadata_changes) -> Path:
    archive = root / "meetings" / "2026" / "09" / MEETING_ID
    transcript_directory = archive / "transcripts" / "v1"
    transcript_directory.mkdir(parents=True)
    (archive / "manifest.json").write_text(json.dumps({
        "schema_version": 1, "meeting_id": MEETING_ID, "revision": 1,
        "files": [{"path": "metadata.json", "size_bytes": 1, "sha256": "a" * 64, "kind": "metadata"}],
    }), encoding="utf-8")
    metadata = {
        "schema_version": 1,
        "meeting_id": MEETING_ID,
        "manifest_revision": 1,
        "started_at": "2026-09-17T09:00:00+08:00",
        "ended_at": "2026-09-17T09:47:00+08:00",
        "duration_seconds": 2820,
        "timezone": "Australia/Perth",
        "source_app": "us.zoom.xos",
        "title": "Zoom call 17 Sep 2026 at 9:00 am",
        "title_source": "default",
        "capture": {"sourceApplication": {"bundleIdentifier": "us.zoom.xos", "displayName": "Zoom", "kind": "zoom"}},
        "attendees": [{"name": "Sam Example", "email": "sam@example.com", "response": "2"}],
    }
    metadata.update(metadata_changes)
    metadata = {key: value for key, value in metadata.items() if value is not None}
    (archive / "metadata.json").write_text(json.dumps(metadata), encoding="utf-8")
    (transcript_directory / "transcript.json").write_text(json.dumps({
        "schema_version": 1, "meeting_id": MEETING_ID, "manifest_revision": 1,
        "processing": {"manifest_sha256": "a" * 64},
        "turns": TURNS if turns is None else turns,
    }), encoding="utf-8")
    return archive


class SummarizerTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.archive = write_meeting(self.root)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def summarize(self, *outcomes, archive: Path | None = None, module: types.ModuleType | None = None):
        client = FakeClient(*outcomes)
        module = module or fake_anthropic()
        module.client = client
        with patch.dict(sys.modules, {"anthropic": module}):
            result = summarize_archive(archive or self.archive, ClaudeSummarizer("sk-ant-private-key"))
        return result, client, module

    def summary_file(self) -> Path:
        return self.archive / "transcripts" / "v1" / "summary.json"

    def metadata(self) -> dict:
        return json.loads((self.archive / "metadata.json").read_text(encoding="utf-8"))


class ClaudeRequestTests(SummarizerTestCase):
    def test_success_writes_summary_and_replaces_the_automatic_title(self) -> None:
        result, client, module = self.summarize(response())

        self.assertEqual(result, {"summary_written": True, "title_changed": True})
        summary = json.loads(self.summary_file().read_text(encoding="utf-8"))
        self.assertEqual(summary["schema_version"], 1)
        self.assertEqual(summary["meeting_id"], MEETING_ID)
        self.assertEqual(summary["manifest_revision"], 1)
        self.assertEqual(summary["model"], "claude-opus-5-5")
        self.assertEqual(summary["served_by"], "claude-opus-5-5")
        self.assertEqual(summary["title"], ANSWER["title"])
        self.assertEqual(summary["summary"], ANSWER["summary"])
        self.assertEqual(summary["action_items"], ANSWER["action_items"])
        self.assertEqual(summary["usage"], {"input_tokens": 1200, "output_tokens": 300})
        self.assertEqual(len(summary["input_sha256"]), 64)
        self.assertEqual(effective_title(self.archive, self.metadata()), "Budget revision with Sam")
        self.assertEqual(module.constructed, [{"api_key": "sk-ant-private-key", "timeout": 300.0}])
        self.assertTrue(client.closed, "the service keeps no idle connections between meetings")

    def test_request_uses_structured_output_low_effort_and_the_default_fallback(self) -> None:
        _, client, _ = self.summarize(response())

        request = client.calls[0]
        self.assertEqual(request["model"], "claude-opus-5-5")
        self.assertEqual(request["max_tokens"], MAX_TOKENS)
        self.assertEqual(request["betas"], [FALLBACK_BETA])
        self.assertEqual(request["betas"], ["server-side-fallback-2026-07-01"])
        self.assertEqual(request["fallbacks"], "default")
        self.assertEqual(request["output_config"]["effort"], "low")
        schema_format = request["output_config"]["format"]
        self.assertEqual(schema_format["type"], "json_schema")
        self.assertEqual(set(schema_format["schema"]["required"]), {"title", "summary", "action_items"})
        self.assertFalse(schema_format["schema"]["additionalProperties"])
        # Thinking is always on for this model: never sent, never disabled.
        self.assertNotIn("thinking", request)
        self.assertNotIn("temperature", request)
        # One user turn and no assistant prefill.
        self.assertEqual([message["role"] for message in request["messages"]], ["user"])
        self.assertIn("em dashes", request["system"])

    def test_prompt_has_speakers_rough_times_app_date_and_attendees(self) -> None:
        _, client, _ = self.summarize(response())

        prompt = client.calls[0]["messages"][0]["content"]
        self.assertIn("- App: Zoom", prompt)
        self.assertIn("- Started: Thursday 17 September 2026, 9:00 am (Australia/Perth)", prompt)
        self.assertIn("- Length: 47 minutes", prompt)
        self.assertIn("- Calendar attendees: Sam Example", prompt)
        self.assertIn("[0:01] Mike Cann: Morning Sam, shall we go through the budget?", prompt)
        self.assertIn("[0:04] Remote speaker 1: Yes. I'll send the revised numbers by Friday. And the deck too.", prompt)
        self.assertIn("[1:15] Remote speaker 2: Thanks both.", prompt)
        # The automatic title says nothing useful, so it isn't sent.
        self.assertNotIn("- Title:", prompt)

    def test_whole_transcript_is_sent_never_truncated(self) -> None:
        turns = [
            {"start": float(index * 200), "end": float(index * 200 + 5), "speaker": "incoming:SPEAKER_00",
             "channel_origin": "incoming", "text": f"Point number {index}."}
            for index in range(400)
        ]
        prompt = build_prompt(self.metadata(), {"turns": turns})
        self.assertIn("Point number 0.", prompt)
        self.assertIn("[22:10:00] Remote speaker 1: Point number 399.", prompt)

    def test_a_chosen_title_is_context_and_is_kept(self) -> None:
        archive = write_meeting(self.root / "calendar", title="Acme catch up", title_source="calendar")

        result, client, _ = self.summarize(response(), archive=archive)

        self.assertIn("- Title: Acme catch up", client.calls[0]["messages"][0]["content"])
        self.assertTrue(result["summary_written"])
        self.assertFalse(result["title_changed"])
        self.assertFalse((archive / "title.json").exists())

    def test_a_user_title_from_the_app_or_a_rename_is_kept(self) -> None:
        archive = write_meeting(self.root / "named", title="Mum's birthday plans", title_source="user")
        result, _, _ = self.summarize(response(), archive=archive)
        self.assertFalse(result["title_changed"])

        write_title(self.archive, "Mike's budget chat")
        result, _, _ = self.summarize(response())
        self.assertFalse(result["title_changed"])
        self.assertEqual(effective_title(self.archive, self.metadata()), "Mike's budget chat")

    def test_a_v1_default_title_without_a_source_is_replaced(self) -> None:
        archive = write_meeting(
            self.root / "v1", title="Meeting 23 Sep 2026 at 6:47 am", title_source=None, capture=None,
        )

        result, client, _ = self.summarize(response(), archive=archive)

        self.assertTrue(result["title_changed"])
        record = json.loads((archive / "title.json").read_text(encoding="utf-8"))
        self.assertEqual((record["title"], record["source"]), ("Budget revision with Sam", "ai"))
        self.assertIn("- App: us.zoom.xos", client.calls[0]["messages"][0]["content"])

    def test_a_v1_title_someone_chose_is_kept(self) -> None:
        archive = write_meeting(self.root / "v1-named", title="Weekly sync", title_source=None)

        result, _, _ = self.summarize(response(), archive=archive)

        self.assertFalse(result["title_changed"])
        self.assertFalse((archive / "title.json").exists())

    def test_rerun_reuses_the_summary_without_calling_claude(self) -> None:
        self.summarize(response())
        first = self.summary_file().read_bytes()

        result, client, _ = self.summarize()

        self.assertEqual(result, {"summary_written": False, "title_changed": False})
        self.assertEqual(client.calls, [])
        self.assertEqual(self.summary_file().read_bytes(), first)

    def test_new_speaker_names_are_summarized_again(self) -> None:
        self.summarize(response())
        path = self.archive / "transcripts" / "v1" / "transcript.json"
        transcript = json.loads(path.read_text(encoding="utf-8"))
        for turn in transcript["turns"]:
            if turn.get("speaker") == "incoming:SPEAKER_00":
                turn["name"] = "Sam Example"
        path.write_text(json.dumps(transcript), encoding="utf-8")
        renamed = dict(ANSWER, title="Budget revision with Sam Example")

        result, client, _ = self.summarize(response(renamed))

        self.assertIn("Sam Example: Yes.", client.calls[0]["messages"][0]["content"])
        self.assertEqual(result, {"summary_written": True, "title_changed": True})
        self.assertEqual(effective_title(self.archive, self.metadata()), "Budget revision with Sam Example")

    def test_a_meeting_with_no_speech_is_not_sent(self) -> None:
        archive = write_meeting(self.root / "silent", turns=[{"start": 0, "end": 1, "text": "  "}])

        result, client, _ = self.summarize(archive=archive)

        self.assertEqual(result["reason"], "no_speech")
        self.assertEqual(client.calls, [])
        self.assertFalse((archive / "transcripts" / "v1" / "summary.json").exists())

    def test_a_tidy_answer_is_kept_and_odd_shapes_are_retried(self) -> None:
        messy = {"title": ' "Budget revision." ', "summary": ["- Sam is revising it.", "  "], "action_items": []}
        result, _, _ = self.summarize(response(messy))
        self.assertTrue(result["summary_written"])
        summary = json.loads(self.summary_file().read_text(encoding="utf-8"))
        self.assertEqual(summary["title"], "Budget revision")
        self.assertEqual(summary["summary"], ["Sam is revising it."])
        self.assertEqual(summary["action_items"], [])

        for bad in (
            response(text="not json"),
            response({"title": "", "summary": ["x"], "action_items": []}),
            response({"title": "T", "summary": [], "action_items": []}),
            response({"title": "Line\nbreak" * 30, "summary": ["x"], "action_items": [3]}),
        ):
            archive = write_meeting(self.root / uuid.uuid4().hex)
            with self.subTest(answer=bad.content[-1].text[:40]):
                with self.assertRaises(TransientSummaryError):
                    self.summarize(bad, archive=archive)
                self.assertFalse((archive / "transcripts" / "v1" / "summary.json").exists())


class ClaudeFailureTests(SummarizerTestCase):
    def assert_nothing_written(self) -> None:
        self.assertFalse(self.summary_file().exists())
        self.assertFalse((self.archive / "title.json").exists())

    def test_refusal_is_permanent_and_writes_nothing(self) -> None:
        refused = response(stop_reason="refusal", stop_details=SimpleNamespace(category="cyber", recommended_model=None))

        with self.assertRaisesRegex(PermanentSummaryError, r"declined.*\(cyber\)"):
            self.summarize(refused)
        self.assert_nothing_written()

    def test_refusal_with_a_busy_fallback_is_tried_again_later(self) -> None:
        refused = response(
            stop_reason="refusal",
            stop_details=SimpleNamespace(category="bio", recommended_model="claude-opus-5"),
        )
        with self.assertRaises(TransientSummaryError):
            self.summarize(refused)
        self.assert_nothing_written()

    def test_running_out_of_tokens_retries_once_with_more_room(self) -> None:
        result, client, _ = self.summarize(response(stop_reason="max_tokens", text='{"title": "Bud'), response())

        self.assertTrue(result["summary_written"])
        self.assertEqual([call["max_tokens"] for call in client.calls], [MAX_TOKENS, LONG_MAX_TOKENS])

    def test_running_out_of_tokens_twice_is_permanent(self) -> None:
        cut = response(stop_reason="max_tokens", text='{"title": "Bud')
        with self.assertRaisesRegex(PermanentSummaryError, "ran past"):
            self.summarize(cut, cut)
        self.assert_nothing_written()

    def test_auth_and_request_errors_are_permanent_without_leaking_the_key(self) -> None:
        module = fake_anthropic()
        for error in (
            module.AuthenticationError("invalid x-api-key"),
            module.PermissionDeniedError("not allowed"),
            module.NotFoundError("model: claude-opus-5-5"),
            module.BadRequestError("fallbacks: unexpected value"),
            module.APIStatusError("billing problem", status_code=402),
        ):
            with self.subTest(error=type(error).__name__):
                with self.assertRaises(PermanentSummaryError) as raised:
                    self.summarize(error, module=module)
                self.assertNotIn("sk-ant-private-key", str(raised.exception))
                self.assert_nothing_written()
        with self.assertRaisesRegex(PermanentSummaryError, "anthropicApiKey"):
            self.summarize(module.AuthenticationError("invalid x-api-key"), module=module)

    def test_rate_limits_outages_and_network_errors_retry_later(self) -> None:
        module = fake_anthropic()
        for error in (
            module.RateLimitError("rate limited"),
            module.InternalServerError("internal"),
            module.OverloadedError("overloaded"),
            module.APIStatusError("timeout", status_code=408),
            module.APIConnectionError("connection reset"),
            module.APITimeoutError("timed out"),
        ):
            with self.subTest(error=type(error).__name__):
                with self.assertRaises(TransientSummaryError):
                    self.summarize(error, module=module)
                self.assert_nothing_written()


class SummaryStageTests(unittest.TestCase):
    """The durable stage: separate retries, never blocking transcription or Notion."""

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.database = self.root / "worker.sqlite"
        self.archive = write_meeting(self.root)
        self.queue = JobQueue(self.database)
        self.job_id = self.queue.enqueue(MEETING_ID, 1, "a" * 64, str(self.archive))

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def complete_processing(self) -> None:
        self.queue.complete(self.queue.claim_ready("worker", 60))  # type: ignore[arg-type]

    def summary_job(self) -> dict:
        return SummaryQueue(self.database).status({self.job_id})["jobs"][0]

    def test_missing_key_skips_quietly(self) -> None:
        self.complete_processing()
        self.assertEqual(summaries_disabled_reason({}), "ANTHROPIC_API_KEY is not set")
        self.assertEqual(summaries_disabled_reason({"ANTHROPIC_API_KEY": "  "}), "ANTHROPIC_API_KEY is not set")
        with patch.dict(os.environ):
            os.environ.pop("ANTHROPIC_API_KEY", None)
            self.assertFalse(run_summary(self.database))
        self.assertEqual(SummaryQueue(self.database).status()["jobs"], [])
        self.assertFalse((self.archive / "transcripts" / "v1" / "summary.json").exists())

    def test_with_a_key_the_service_summarizes_through_claude(self) -> None:
        import importlib.machinery

        self.complete_processing()
        module = fake_anthropic()
        module.client = FakeClient(response())
        module.__spec__ = importlib.machinery.ModuleSpec("anthropic", None)
        with patch.dict(os.environ, {"ANTHROPIC_API_KEY": "sk-ant-private-key"}), \
                patch.dict(sys.modules, {"anthropic": module}):
            self.assertTrue(run_summary(self.database))

        self.assertEqual(module.constructed[0]["api_key"], "sk-ant-private-key")
        metadata = json.loads((self.archive / "metadata.json").read_text(encoding="utf-8"))
        self.assertEqual(read_summary(self.archive, metadata)["summary"], ANSWER["summary"])
        self.assertEqual(effective_title(self.archive, metadata), ANSWER["title"])
        self.assertEqual(self.summary_job()["state"], "succeeded")
        self.assertEqual(PublicationQueue(self.database).status({self.job_id})["jobs"][0]["state"], "ready")

    def test_a_key_without_the_sdk_installed_is_reported(self) -> None:
        with patch("importlib.util.find_spec", return_value=None):
            reason = summaries_disabled_reason({"ANTHROPIC_API_KEY": "sk-ant-private-key"})
        self.assertIn("anthropic package", reason)
        self.assertNotIn("sk-ant", reason)

    def test_success_requests_a_notion_update_with_the_summary(self) -> None:
        self.complete_processing()
        summarized: list[Path] = []

        self.assertTrue(run_summary(self.database, summarize=summarized.append))

        self.assertEqual(summarized, [self.archive])
        self.assertEqual(self.summary_job()["state"], "succeeded")
        publication = PublicationQueue(self.database).status({self.job_id})["jobs"][0]
        self.assertEqual(publication["state"], "ready")
        self.assertFalse(run_summary(self.database, summarize=summarized.append), "nothing is due twice")

    def test_claude_outage_never_blocks_transcription_or_notion(self) -> None:
        published: list[Path] = []

        def outage(_archive):
            raise TransientSummaryError("Anthropic is unavailable (HTTP 529): overloaded")

        result = run_once(
            self.database, processor=lambda *_: None, publisher=published.append,
            summarize=outage, lease_seconds=60,
        )

        self.assertTrue(result["processed"])
        self.assertTrue(result["published"])
        self.assertEqual(published, [self.archive])
        job = self.summary_job()
        self.assertEqual(job["state"], "retry_wait")
        self.assertIn("HTTP 529", job["last_error"])

        # When the summary arrives, the page is republished with it.
        SummaryQueue(self.database).retry_failed(self.job_id)
        self.assertTrue(run_summary(self.database, summarize=lambda _archive: None))
        self.assertTrue(run_once(self.database, processor=lambda *_: None, publisher=published.append)["published"])
        self.assertEqual(published, [self.archive, self.archive])

    def test_transient_failures_back_off_then_become_permanent(self) -> None:
        self.complete_processing()
        now = [1000.0]
        summaries = SummaryQueue(self.database, clock=lambda: now[0])
        summaries.reconcile(self.queue.status()["jobs"])

        def outage(_archive):
            raise TransientSummaryError("Couldn't reach Anthropic (APIConnectionError).")

        for attempt in range(1, MAX_ATTEMPTS + 1):
            self.assertFalse(summaries.run_one(outage))
            job = summaries.status()["jobs"][0]
            self.assertEqual(job["attempts"], attempt)
            if attempt < MAX_ATTEMPTS:
                self.assertEqual(job["state"], "retry_wait")
                self.assertFalse(summaries.run_one(outage), "not due yet")
                now[0] = job["available_at"]
        self.assertEqual(job["state"], "permanent_failure")

    def test_permanent_failure_waits_for_an_explicit_retry(self) -> None:
        self.complete_processing()
        summaries = SummaryQueue(self.database)
        summaries.reconcile(self.queue.status()["jobs"])

        def refused(_archive):
            raise PermanentSummaryError("Claude declined to summarize this meeting (cyber).")

        self.assertFalse(summaries.run_one(refused))
        self.assertEqual(self.summary_job()["state"], "permanent_failure")
        self.assertFalse(summaries.run_one(refused))

        output = io.StringIO()
        with redirect_stdout(output):
            code = cli_main(["retry", "--db", str(self.database), "--meeting-id", MEETING_ID])
        response_body = json.loads(output.getvalue())
        self.assertEqual(code, 0)
        self.assertTrue(response_body["retried"])
        self.assertEqual(response_body["summary"], {"processing_job_id": self.job_id, "state": "ready", "retried": True})
        self.assertEqual(self.queue.status()["jobs"][0]["state"], "succeeded", "a summary retry never retranscribes")
        self.assertTrue(summaries.run_one(lambda _archive: None))

    def test_a_request_during_a_run_is_kept_for_another_pass(self) -> None:
        self.complete_processing()
        summaries = SummaryQueue(self.database)
        summaries.reconcile(self.queue.status()["jobs"])

        def names_arrive_meanwhile(_archive):
            summaries.request(self.job_id, str(self.archive))

        self.assertTrue(summaries.run_one(names_arrive_meanwhile))
        self.assertEqual(self.summary_job()["state"], "ready")
        self.assertTrue(summaries.run_one(lambda _archive: None))
        self.assertEqual(self.summary_job()["state"], "succeeded")

    def test_asking_again_only_rearms_meetings_that_have_summaries(self) -> None:
        summaries = SummaryQueue(self.database, clock=lambda: 500.0)
        self.assertFalse(summaries.request(self.job_id, str(self.archive), delay_seconds=300, create=False))
        self.assertEqual(summaries.status()["jobs"], [])

        self.assertTrue(summaries.request(self.job_id, str(self.archive)))
        self.assertTrue(summaries.run_one(lambda _archive: None))
        self.assertTrue(summaries.request(self.job_id, str(self.archive), delay_seconds=300, create=False))
        job = self.summary_job()
        self.assertEqual((job["state"], job["available_at"]), ("ready", 800.0))

    def test_an_interrupted_summary_counts_as_a_failed_attempt(self) -> None:
        self.complete_processing()
        now = [1000.0]
        summaries = SummaryQueue(self.database, clock=lambda: now[0])
        summaries.reconcile(self.queue.status()["jobs"])
        with closing(sqlite3.connect(self.database)) as connection, connection:
            connection.execute(
                "UPDATE summary_jobs SET state='summarizing', attempts=1, lease_owner='gone', lease_expires_at=1001",
            )
        now[0] = 1002.0

        self.assertFalse(summaries.run_one(lambda _archive: None))

        job = self.summary_job()
        self.assertEqual(job["state"], "retry_wait")
        self.assertIn("stopped", job["last_error"])

    def test_completed_processing_queues_a_summary_when_enabled(self) -> None:
        from meeting_archive_worker.service import run_processing

        with patch("meeting_archive_worker.service.summaries_enabled", return_value=True):
            self.assertTrue(run_processing(self.database, processor=lambda *_: None, lease_seconds=60))

        self.assertEqual(self.summary_job()["state"], "ready")

    def test_status_reports_display_titles_and_the_summary_stage(self) -> None:
        self.complete_processing()
        other_id = str(uuid.uuid4())
        self.queue.enqueue(other_id, 1, "b" * 64, str(self.root / "missing"))
        (self.archive / "title.json").write_text(json.dumps({
            "schema_version": 1, "title": "Budget revision with Sam", "source": "ai",
        }), encoding="utf-8")
        SummaryQueue(self.database).reconcile(self.queue.status()["jobs"])

        output = io.StringIO()
        with redirect_stdout(output):
            code = cli_main(["status", "--db", str(self.database)])
        status = json.loads(output.getvalue())

        self.assertEqual(code, 0)
        titles = {job["meeting_id"]: job.get("title") for job in status["jobs"]}
        self.assertEqual(titles, {MEETING_ID: "Budget revision with Sam", other_id: None})
        self.assertEqual(status["summary"]["phase"], "ready")
        self.assertEqual([job["processing_job_id"] for job in status["summary"]["jobs"]], [self.job_id])

    def test_speaker_names_ask_for_a_new_summary_once_they_settle(self) -> None:
        from meeting_archive_worker.speaker_refresh import reconcile_speaker_refresh
        from meeting_archive_worker.speakers import SpeakerRegistry

        self.complete_processing()
        acknowledgement = {
            "schema_version": 1, "meeting_id": MEETING_ID, "manifest_revision": 1,
            "manifest_sha256": "a" * 64, "archive_path": str(self.archive), "queue_job_id": str(self.job_id),
        }
        with closing(sqlite3.connect(self.database)) as connection, connection:
            connection.execute(
                "INSERT INTO acceptances VALUES (?, ?, ?, ?, ?, ?)",
                (MEETING_ID, 1, "a" * 64, str(self.archive), json.dumps(acknowledgement), "2026-09-17T00:00:00Z"),
            )
        summaries = SummaryQueue(self.database)
        summaries.reconcile(self.queue.status()["jobs"])
        self.assertTrue(summaries.run_one(lambda _archive: None))
        registry = SpeakerRegistry(self.database)
        registry.save_observation(MEETING_ID, 1, "incoming:SPEAKER_00", [1.0, 0.0], "model@1")
        registry.confirm_observation(MEETING_ID, 1, "incoming:SPEAKER_00", "Sam Example")

        self.assertTrue(reconcile_speaker_refresh(self.database, MEETING_ID, 1))

        job = self.summary_job()
        self.assertEqual(job["state"], "ready")
        self.assertGreater(job["available_at"], __import__("time").time() + 200, "waits for more names first")


class ReadSummaryTests(unittest.TestCase):
    def test_only_a_valid_summary_for_this_revision_is_read(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            archive = write_meeting(Path(temporary))
            metadata = json.loads((archive / "metadata.json").read_text(encoding="utf-8"))
            path = archive / "transcripts" / "v1" / "summary.json"
            self.assertIsNone(read_summary(archive, metadata))
            valid = {
                "schema_version": 1, "meeting_id": MEETING_ID, "manifest_revision": 1,
                "title": "T", "summary": ["One."], "action_items": [],
            }
            path.write_text(json.dumps(valid), encoding="utf-8")
            self.assertEqual(read_summary(archive, metadata)["summary"], ["One."])
            for broken in (dict(valid, manifest_revision=2), dict(valid, summary=[]), dict(valid, action_items=[1])):
                path.write_text(json.dumps(broken), encoding="utf-8")
                self.assertIsNone(read_summary(archive, metadata))
            path.write_text("{", encoding="utf-8")
            self.assertIsNone(read_summary(archive, metadata))


if __name__ == "__main__":
    unittest.main()
