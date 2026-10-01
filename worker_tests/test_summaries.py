"""AI titles and summaries, with urllib's urlopen standing in for OpenRouter: no network, no key."""

from __future__ import annotations

import email.message
import email.utils
import http.client
import io
import json
import os
import socket
import sqlite3
import sys
import tempfile
import unittest
import urllib.error
import uuid
from contextlib import closing, redirect_stdout
from datetime import UTC, datetime, timedelta
from pathlib import Path
from unittest.mock import patch


WORKER_ROOT = Path(__file__).resolve().parents[1] / "worker"
sys.path.insert(0, str(WORKER_ROOT))

from meeting_archive_worker.cli import main as cli_main  # noqa: E402
from meeting_archive_worker.queue import MAX_ATTEMPTS, JobQueue  # noqa: E402
from meeting_archive_worker.service import PublicationQueue, run_once, run_summary  # noqa: E402
from meeting_archive_worker.summaries import (  # noqa: E402
    DEFAULT_MODEL,
    ENDPOINT,
    LONG_MAX_TOKENS,
    MAX_RETRY_AFTER_SECONDS,
    MAX_TOKENS,
    OUTPUT_SCHEMA,
    OpenRouterSummarizer,
    PermanentSummaryError,
    SummaryError,
    SummaryQueue,
    TransientSummaryError,
    build_prompt,
    read_summary,
    summaries_disabled_reason,
    summarize_archive,
    summary_model,
)
from meeting_archive_worker.titles import effective_title, write_title  # noqa: E402


MEETING_ID = "22222222-2222-4222-8222-222222222222"
API_KEY = "sk-or-v1-private-key"
SERVED_BY = "anthropic/claude-opus-5.5-20260921"
ANSWER = {
    "title": "Budget revision with Sam",
    "summary": ["Sam is revising the budget.", "The deck needs updating too."],
    "action_items": ["Sam to send the revised numbers by Friday."],
}
USAGE = {
    "prompt_tokens": 1200,
    "completion_tokens": 300,
    "total_tokens": 1500,
    "cost": 0.0108,
    "is_byok": False,
    "prompt_tokens_details": {"cached_tokens": 0},
    "completion_tokens_details": {"reasoning_tokens": 120},
}


def completion(
    answer=ANSWER,
    *,
    content: str | None = None,
    finish_reason: str = "stop",
    native_finish_reason: str = "end_turn",
    refusal: str | None = None,
    model: str = SERVED_BY,
) -> dict:
    """A chat completion shaped like OpenRouter's."""
    return {
        "id": "gen-1",
        "provider": "Anthropic",
        "model": model,
        "object": "chat.completion",
        "created": 1790000000,
        "choices": [{
            "index": 0,
            "finish_reason": finish_reason,
            "native_finish_reason": native_finish_reason,
            "message": {
                "role": "assistant",
                "content": json.dumps(answer) if content is None else content,
                "refusal": refusal,
                "reasoning": "Thinking about what the meeting decided.",
            },
        }],
        "usage": USAGE,
    }


def http_error(
    status: int,
    message: str = "error",
    *,
    headers: dict[str, str] | None = None,
    body: bytes | None = None,
    metadata: dict | None = None,
) -> urllib.error.HTTPError:
    fields = email.message.Message()
    for name, value in (headers or {}).items():
        fields[name] = value
    if body is None:
        error = {"code": status, "message": message}
        if metadata is not None:
            error["metadata"] = metadata
        body = json.dumps({"error": error}).encode("utf-8")
    return urllib.error.HTTPError(ENDPOINT, status, "Error", fields, io.BytesIO(body))


class FakeResponse(io.BytesIO):
    """What urlopen returns: readable, and closed by its with block."""


class StalledResponse(FakeResponse):
    def read(self, size: int = -1) -> bytes:
        raise TimeoutError("The read operation timed out")


class FakeOpenRouter:
    """Stands in for urllib.request.urlopen: records each request and plays back an outcome."""

    def __init__(self, *outcomes) -> None:
        self.outcomes = list(outcomes)
        self.requests: list[dict] = []
        self.responses: list[FakeResponse] = []

    def __call__(self, request, timeout=None):
        self.requests.append({
            "url": request.full_url,
            "method": request.get_method(),
            "headers": {name.lower(): value for name, value in request.header_items()},
            "unredirected": {name.lower() for name in request.unredirected_hdrs},
            "body": json.loads(request.data.decode("utf-8")),
            "timeout": timeout,
        })
        outcome = self.outcomes.pop(0)
        if isinstance(outcome, BaseException):
            raise outcome
        if not isinstance(outcome, FakeResponse):
            outcome = FakeResponse(outcome if isinstance(outcome, bytes) else json.dumps(outcome).encode("utf-8"))
        self.responses.append(outcome)
        return outcome

    @property
    def bodies(self) -> list[dict]:
        return [request["body"] for request in self.requests]

    def prompt(self, index: int = 0) -> str:
        return self.bodies[index]["messages"][1]["content"]


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
        "title": "Zoom call 17 Sep 2026 at 9:00 am",
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

    def summarize(self, *outcomes, archive: Path | None = None, model: str = DEFAULT_MODEL):
        self.openrouter = FakeOpenRouter(*outcomes)
        with patch("urllib.request.urlopen", self.openrouter):
            result = summarize_archive(archive or self.archive, OpenRouterSummarizer(API_KEY, model=model))
        return result, self.openrouter

    def summary_file(self) -> Path:
        return self.archive / "transcripts" / "v1" / "summary.json"

    def metadata(self) -> dict:
        return json.loads((self.archive / "metadata.json").read_text(encoding="utf-8"))


class OpenRouterRequestTests(SummarizerTestCase):
    def test_success_writes_summary_with_usage_and_replaces_the_automatic_title(self) -> None:
        result, openrouter = self.summarize(completion())

        self.assertEqual(result, {"summary_written": True, "title_changed": True})
        summary = json.loads(self.summary_file().read_text(encoding="utf-8"))
        self.assertEqual(summary["schema_version"], 1)
        self.assertEqual(summary["meeting_id"], MEETING_ID)
        self.assertEqual(summary["manifest_revision"], 1)
        self.assertEqual(summary["provider"], "openrouter")
        self.assertEqual(summary["model"], "anthropic/claude-opus-5.5")
        self.assertEqual(summary["served_by"], SERVED_BY)
        self.assertEqual(summary["title"], ANSWER["title"])
        self.assertEqual(summary["summary"], ANSWER["summary"])
        self.assertEqual(summary["action_items"], ANSWER["action_items"])
        self.assertEqual(summary["usage"], {
            "requests": 1, "prompt_tokens": 1200, "completion_tokens": 300, "reasoning_tokens": 120, "cost": 0.0108,
        })
        self.assertEqual(len(summary["input_sha256"]), 64)
        self.assertEqual(effective_title(self.archive, self.metadata()), "Budget revision with Sam")
        record = json.loads((self.archive / "title.json").read_text(encoding="utf-8"))
        self.assertEqual((record["source"], record["model"]), ("ai", SERVED_BY))
        self.assertTrue(all(response.closed for response in openrouter.responses))
        self.assertNotIn(API_KEY, self.summary_file().read_text(encoding="utf-8"))

    def test_request_asks_openrouter_for_strict_json_at_low_effort(self) -> None:
        _, openrouter = self.summarize(completion())

        request = openrouter.requests[0]
        self.assertEqual(request["url"], "https://openrouter.ai/api/v1/chat/completions")
        self.assertEqual(request["method"], "POST")
        self.assertEqual(request["timeout"], 300.0)
        self.assertEqual(request["headers"]["authorization"], f"Bearer {API_KEY}")
        self.assertIn("authorization", request["unredirected"], "a redirect never carries the key")
        self.assertEqual(request["headers"]["content-type"], "application/json")
        self.assertEqual(request["headers"]["x-title"], "Meeting Archive")
        body = request["body"]
        self.assertEqual(body["model"], "anthropic/claude-opus-5.5")
        self.assertEqual(body["max_tokens"], MAX_TOKENS)
        self.assertEqual(MAX_TOKENS, 2_000)
        self.assertEqual(body["reasoning"], {"effort": "low"})
        self.assertEqual(body["usage"], {"include": True})
        self.assertEqual(body["response_format"], {
            "type": "json_schema",
            "json_schema": {"name": "meeting_summary", "strict": True, "schema": OUTPUT_SCHEMA},
        })
        # Endpoints that don't enforce strict JSON are skipped.
        self.assertEqual(body["provider"], {"require_parameters": True})
        self.assertEqual(set(OUTPUT_SCHEMA["required"]), {"title", "summary", "action_items"})
        self.assertFalse(OUTPUT_SCHEMA["additionalProperties"])
        # The system prompt, then the meeting. No assistant prefill.
        self.assertEqual([message["role"] for message in body["messages"]], ["system", "user"])
        self.assertIn("em dashes", body["messages"][0]["content"])
        self.assertNotIn("temperature", body)
        self.assertNotIn(API_KEY, json.dumps(body))

    def test_another_model_can_be_chosen_and_summarizes_afresh(self) -> None:
        self.assertEqual(summary_model({}), "anthropic/claude-opus-5.5")
        self.assertEqual(summary_model({"MEETING_ARCHIVE_SUMMARY_MODEL": "  "}), "anthropic/claude-opus-5.5")
        self.assertEqual(summary_model({"MEETING_ARCHIVE_SUMMARY_MODEL": " openai/gpt-6 "}), "openai/gpt-6")
        self.summarize(completion())

        result, openrouter = self.summarize(completion(model="openai/gpt-6"), model="openai/gpt-6")

        self.assertTrue(result["summary_written"], "a different model is a different request")
        self.assertEqual(openrouter.bodies[0]["model"], "openai/gpt-6")
        summary = json.loads(self.summary_file().read_text(encoding="utf-8"))
        self.assertEqual((summary["model"], summary["served_by"]), ("openai/gpt-6", "openai/gpt-6"))

    def test_whitespace_before_the_json_is_fine(self) -> None:
        # OpenRouter may keep a slow request alive with whitespace before the body.
        result, _ = self.summarize(b"\n\n   " + json.dumps(completion()).encode("utf-8"))

        self.assertTrue(result["summary_written"])

    def test_prompt_has_speakers_rough_times_app_date_and_attendees(self) -> None:
        _, openrouter = self.summarize(completion())

        prompt = openrouter.prompt()
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

        result, openrouter = self.summarize(completion(), archive=archive)

        self.assertIn("- Title: Acme catch up", openrouter.prompt())
        self.assertTrue(result["summary_written"])
        self.assertFalse(result["title_changed"])
        self.assertFalse((archive / "title.json").exists())

    def test_a_user_title_from_the_app_or_a_rename_is_kept(self) -> None:
        archive = write_meeting(self.root / "named", title="Mum's birthday plans", title_source="user")
        result, _ = self.summarize(completion(), archive=archive)
        self.assertFalse(result["title_changed"])

        write_title(self.archive, "Mike's budget chat")
        result, _ = self.summarize(completion())
        self.assertFalse(result["title_changed"])
        self.assertEqual(effective_title(self.archive, self.metadata()), "Mike's budget chat")

    def test_a_v1_default_title_without_a_source_is_replaced(self) -> None:
        archive = write_meeting(
            self.root / "v1", title="Meeting 23 Sep 2026 at 6:47 am", title_source=None, capture=None,
        )

        result, openrouter = self.summarize(completion(), archive=archive)

        self.assertTrue(result["title_changed"])
        record = json.loads((archive / "title.json").read_text(encoding="utf-8"))
        self.assertEqual((record["title"], record["source"]), ("Budget revision with Sam", "ai"))
        self.assertIn("- App: us.zoom.xos", openrouter.prompt())

    def test_a_v1_title_someone_chose_is_kept(self) -> None:
        archive = write_meeting(self.root / "v1-named", title="Weekly sync", title_source=None)

        result, _ = self.summarize(completion(), archive=archive)

        self.assertFalse(result["title_changed"])
        self.assertFalse((archive / "title.json").exists())

    def test_rerun_reuses_the_summary_without_calling_openrouter(self) -> None:
        self.summarize(completion())
        first = self.summary_file().read_bytes()

        result, openrouter = self.summarize()

        self.assertEqual(result, {"summary_written": False, "title_changed": False})
        self.assertEqual(openrouter.requests, [])
        self.assertEqual(self.summary_file().read_bytes(), first)

    def test_new_speaker_names_are_summarized_again(self) -> None:
        self.summarize(completion())
        path = self.archive / "transcripts" / "v1" / "transcript.json"
        transcript = json.loads(path.read_text(encoding="utf-8"))
        for turn in transcript["turns"]:
            if turn.get("speaker") == "incoming:SPEAKER_00":
                turn["name"] = "Sam Example"
        path.write_text(json.dumps(transcript), encoding="utf-8")
        renamed = dict(ANSWER, title="Budget revision with Sam Example")

        result, openrouter = self.summarize(completion(renamed))

        self.assertIn("Sam Example: Yes.", openrouter.prompt())
        self.assertEqual(result, {"summary_written": True, "title_changed": True})
        self.assertEqual(effective_title(self.archive, self.metadata()), "Budget revision with Sam Example")

    def test_a_meeting_with_no_speech_is_not_sent(self) -> None:
        archive = write_meeting(self.root / "silent", turns=[{"start": 0, "end": 1, "text": "  "}])

        result, openrouter = self.summarize(archive=archive)

        self.assertEqual(result["reason"], "no_speech")
        self.assertEqual(openrouter.requests, [])
        self.assertFalse((archive / "transcripts" / "v1" / "summary.json").exists())

    def test_a_messy_answer_is_tidied(self) -> None:
        messy = {"title": ' "Budget revision." ', "summary": ["- Sam is revising it.", "  "], "action_items": []}

        result, _ = self.summarize(completion(messy))

        self.assertTrue(result["summary_written"])
        summary = json.loads(self.summary_file().read_text(encoding="utf-8"))
        self.assertEqual(summary["title"], "Budget revision")
        self.assertEqual(summary["summary"], ["Sam is revising it."])
        self.assertEqual(summary["action_items"], [])


class OpenRouterFailureTests(SummarizerTestCase):
    def failure(self, *outcomes, expected: type[SummaryError]) -> SummaryError:
        """Summarize, expecting this error, and check nothing was written or leaked."""
        with self.assertRaises(expected) as raised:
            self.summarize(*outcomes)
        self.assertFalse(self.summary_file().exists())
        self.assertFalse((self.archive / "title.json").exists())
        message = str(raised.exception)
        self.assertNotIn(API_KEY, message)
        self.assertNotIn("Morning Sam", message, "the transcript never reaches an error")
        return raised.exception

    def test_running_out_of_room_retries_once_with_more_tokens(self) -> None:
        cut = completion(content='{"title": "Bud', finish_reason="length", native_finish_reason="max_tokens")

        result, openrouter = self.summarize(cut, completion())

        self.assertTrue(result["summary_written"])
        self.assertEqual([body["max_tokens"] for body in openrouter.bodies], [MAX_TOKENS, LONG_MAX_TOKENS])
        self.assertEqual(LONG_MAX_TOKENS, 16_000)
        usage = json.loads(self.summary_file().read_text(encoding="utf-8"))["usage"]
        self.assertEqual(usage, {
            "requests": 2, "prompt_tokens": 2400, "completion_tokens": 600, "reasoning_tokens": 240, "cost": 0.0216,
        })

    def test_running_out_of_room_twice_is_permanent(self) -> None:
        cut = completion(content='{"title": "Bud', finish_reason="length", native_finish_reason="max_tokens")

        error = self.failure(cut, cut, expected=PermanentSummaryError)

        self.assertIn("ran past 16000 tokens", str(error))
        self.assertEqual(len(self.openrouter.requests), 2)

    def test_invalid_json_is_asked_for_once_more(self) -> None:
        result, openrouter = self.summarize(completion(content="Here's the summary you asked for."), completion())

        self.assertTrue(result["summary_written"])
        self.assertEqual([body["max_tokens"] for body in openrouter.bodies], [MAX_TOKENS, MAX_TOKENS])
        self.assertEqual(json.loads(self.summary_file().read_text(encoding="utf-8"))["usage"]["requests"], 2)

    def test_invalid_json_twice_is_permanent(self) -> None:
        prose = completion(content="Here's the summary you asked for.")

        error = self.failure(prose, prose, expected=PermanentSummaryError)

        self.assertIn("not valid JSON", str(error))
        self.assertEqual(len(self.openrouter.requests), 2)

    def test_answers_outside_the_schema_are_asked_for_once_more_then_permanent(self) -> None:
        for bad in (
            {"title": "", "summary": ["x"], "action_items": []},
            {"title": "T", "summary": [], "action_items": []},
            {"title": "Line\nbreak" * 30, "summary": ["x"], "action_items": [3]},
            {"title": "T", "summary": ["x"]},
            {"title": "T", "summary": ["x"], "action_items": [], "notes": "extra"},
            ["T", ["x"], []],
        ):
            with self.subTest(answer=bad):
                self.failure(completion(bad), completion(bad), expected=PermanentSummaryError)
                self.assertEqual(len(self.openrouter.requests), 2)
        result, _ = self.summarize(completion({"title": "T", "summary": []}), completion())
        self.assertTrue(result["summary_written"])

    def test_refusals_and_content_filters_are_permanent_at_once(self) -> None:
        for refused, reason in (
            (completion(content="", finish_reason="content_filter", native_finish_reason="refusal",
                        refusal="I can't help with that."), "declined"),
            (completion(content="", finish_reason="stop", refusal="I can't help with that."), "declined"),
            (completion(content="", finish_reason="content_filter", native_finish_reason="SAFETY"), "content filter"),
        ):
            with self.subTest(reason=reason, native=refused["choices"][0]["native_finish_reason"]):
                error = self.failure(refused, expected=PermanentSummaryError)
                self.assertIn(reason, str(error))
                self.assertEqual(len(self.openrouter.requests), 1)

    def test_a_rejected_key_is_permanent(self) -> None:
        error = self.failure(http_error(401, "User not found."), expected=PermanentSummaryError)

        self.assertIn("HTTP 401", str(error))
        self.assertIn("openRouterApiKey", str(error))
        self.assertEqual(len(self.openrouter.requests), 1)

    def test_forbidden_and_bad_requests_are_permanent(self) -> None:
        for status, message in (
            (403, "This key is not allowed to use this model"),
            (400, "response_format is not supported"),
            (404, "No endpoints found for this model"),
        ):
            with self.subTest(status=status):
                error = self.failure(http_error(status, message), expected=PermanentSummaryError)
                self.assertIn(f"HTTP {status}: {message}", str(error))

    def test_a_moderation_block_never_quotes_the_transcript(self) -> None:
        blocked = http_error(403, "Input was flagged by moderation.", metadata={
            "reasons": ["harassment"],
            "flagged_input": "Morning Sam, shall we go through the budget?",
            "provider_name": "Anthropic",
            "model_slug": "anthropic/claude-opus-5.5",
        })

        error = self.failure(blocked, expected=PermanentSummaryError)

        self.assertIn("flagged by moderation", str(error))

    def test_running_out_of_credits_waits_an_hour_between_tries(self) -> None:
        error = self.failure(http_error(402, "Insufficient credits"), expected=TransientSummaryError)
        self.assertEqual(error.retry_after, 3600.0)
        self.assertIn("HTTP 402: Insufficient credits", str(error))

        error = self.failure(
            http_error(402, "Insufficient credits", headers={"Retry-After": "7200"}), expected=TransientSummaryError,
        )
        self.assertEqual(error.retry_after, 7200.0)

    def test_rate_limits_honour_retry_after(self) -> None:
        soon = email.utils.format_datetime(datetime.now(UTC) + timedelta(seconds=120), usegmt=True)
        for header, low, high in (
            ("30", 30.0, 30.0),
            (soon, 100.0, 120.0),
            ("1e12", MAX_RETRY_AFTER_SECONDS, MAX_RETRY_AFTER_SECONDS),
            ("-5", 0.0, 0.0),
            ("soon", 0.0, 0.0),
        ):
            with self.subTest(retry_after=header):
                error = self.failure(
                    http_error(429, "Rate limit exceeded", headers={"Retry-After": header}),
                    expected=TransientSummaryError,
                )
                self.assertGreaterEqual(error.retry_after, low)
                self.assertLessEqual(error.retry_after, high)
        error = self.failure(http_error(429, "Rate limit exceeded"), expected=TransientSummaryError)
        self.assertEqual(error.retry_after, 0.0)
        self.assertIn("rate limiting", str(error))

    def test_server_errors_and_timeouts_retry_later(self) -> None:
        for status in (500, 502, 503, 504, 408):
            with self.subTest(status=status):
                error = self.failure(
                    http_error(status, "Provider returned error", headers={"Retry-After": "90"}),
                    expected=TransientSummaryError,
                )
                self.assertIn(f"HTTP {status}: Provider returned error", str(error))
                self.assertEqual(error.retry_after, 90.0)
        error = self.failure(http_error(502, body=b"<html>Bad gateway</html>"), expected=TransientSummaryError)
        self.assertIn("HTTP 502", str(error))

    def test_network_errors_retry_later(self) -> None:
        for failure, name in (
            (urllib.error.URLError(socket.gaierror(8, "nodename nor servname provided")), "gaierror"),
            (urllib.error.URLError("no route"), "URLError"),
            (TimeoutError("timed out"), "TimeoutError"),
            (http.client.RemoteDisconnected("Remote end closed connection without response"), "RemoteDisconnected"),
            (ConnectionResetError(54, "Connection reset by peer"), "ConnectionResetError"),
            (StalledResponse(), "TimeoutError"),
        ):
            with self.subTest(error=name):
                error = self.failure(failure, expected=TransientSummaryError)
                self.assertEqual(str(error), f"Couldn't reach OpenRouter ({name}).")
        self.assertTrue(self.openrouter.responses[0].closed, "a stalled response is still closed")

    def test_errors_inside_a_200_response_are_sorted_like_http_errors(self) -> None:
        error = self.failure({"error": {"code": 502, "message": "Provider disconnected"}}, expected=TransientSummaryError)
        self.assertIn("HTTP 502: Provider disconnected", str(error))

        failed = completion(content="", finish_reason="error", native_finish_reason="error")
        failed["choices"][0]["error"] = {"code": 500, "message": "Upstream error"}
        error = self.failure(failed, expected=TransientSummaryError)
        self.assertIn("HTTP 500: Upstream error", str(error))

        self.failure({"error": {"code": 400, "message": "Invalid request"}}, expected=PermanentSummaryError)
        for reply in (b"not json", b"[]", {"id": "gen-1", "choices": []}, {"error": "busy"}):
            with self.subTest(reply=reply):
                self.failure(reply, expected=TransientSummaryError)

    def test_a_key_that_could_end_up_in_an_error_is_refused_without_repeating_it(self) -> None:
        for key in ("sk-or-v1 private", "sk-or-v1-private\r\nX-Other: 1", "sk-or-v1-privateé", ""):
            with self.subTest(key=key):
                with self.assertRaises(PermanentSummaryError) as raised:
                    OpenRouterSummarizer(key)
                self.assertNotIn("private", str(raised.exception))
                self.assertIn("openRouterApiKey", str(raised.exception))


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
        self.assertEqual(summaries_disabled_reason({}), "OPENROUTER_API_KEY is not set")
        self.assertEqual(summaries_disabled_reason({"OPENROUTER_API_KEY": "  "}), "OPENROUTER_API_KEY is not set")
        self.assertEqual(
            summaries_disabled_reason({"ANTHROPIC_API_KEY": "sk-ant-old"}), "OPENROUTER_API_KEY is not set",
        )
        self.assertIsNone(summaries_disabled_reason({"OPENROUTER_API_KEY": API_KEY}))
        openrouter = FakeOpenRouter()
        with patch.dict(os.environ), patch("urllib.request.urlopen", openrouter):
            os.environ.pop("OPENROUTER_API_KEY", None)
            self.assertFalse(run_summary(self.database))
        self.assertEqual(openrouter.requests, [])
        self.assertEqual(SummaryQueue(self.database).status()["jobs"], [])
        self.assertFalse((self.archive / "transcripts" / "v1" / "summary.json").exists())

    def test_with_a_key_the_service_summarizes_through_openrouter(self) -> None:
        self.complete_processing()
        openrouter = FakeOpenRouter(completion())
        with patch.dict(os.environ, {"OPENROUTER_API_KEY": f"  {API_KEY}\n"}), \
                patch("urllib.request.urlopen", openrouter):
            os.environ.pop("MEETING_ARCHIVE_SUMMARY_MODEL", None)
            self.assertTrue(run_summary(self.database))

        self.assertEqual(openrouter.requests[0]["headers"]["authorization"], f"Bearer {API_KEY}")
        self.assertEqual(openrouter.bodies[0]["model"], "anthropic/claude-opus-5.5")
        metadata = json.loads((self.archive / "metadata.json").read_text(encoding="utf-8"))
        self.assertEqual(read_summary(self.archive, metadata)["summary"], ANSWER["summary"])
        self.assertEqual(effective_title(self.archive, metadata), ANSWER["title"])
        self.assertEqual(self.summary_job()["state"], "succeeded")
        self.assertEqual(PublicationQueue(self.database).status({self.job_id})["jobs"][0]["state"], "ready")

    def test_the_service_uses_the_chosen_model(self) -> None:
        self.complete_processing()
        openrouter = FakeOpenRouter(completion(model="openai/gpt-6"))
        with patch.dict(os.environ, {
            "OPENROUTER_API_KEY": API_KEY, "MEETING_ARCHIVE_SUMMARY_MODEL": "openai/gpt-6",
        }), patch("urllib.request.urlopen", openrouter):
            self.assertTrue(run_summary(self.database))

        self.assertEqual(openrouter.bodies[0]["model"], "openai/gpt-6")

    def test_a_rejected_key_is_a_permanent_summary_failure(self) -> None:
        self.complete_processing()
        openrouter = FakeOpenRouter(http_error(401, "User not found."))
        with patch.dict(os.environ, {"OPENROUTER_API_KEY": API_KEY}), patch("urllib.request.urlopen", openrouter):
            os.environ.pop("MEETING_ARCHIVE_SUMMARY_MODEL", None)
            self.assertFalse(run_summary(self.database))

        job = self.summary_job()
        self.assertEqual((job["state"], job["attempts"]), ("permanent_failure", 1))
        self.assertIn("openRouterApiKey", job["last_error"])
        self.assertNotIn(API_KEY, job["last_error"])

    def test_success_requests_a_notion_update_with_the_summary(self) -> None:
        self.complete_processing()
        summarized: list[Path] = []

        self.assertTrue(run_summary(self.database, summarize=summarized.append))

        self.assertEqual(summarized, [self.archive])
        self.assertEqual(self.summary_job()["state"], "succeeded")
        publication = PublicationQueue(self.database).status({self.job_id})["jobs"][0]
        self.assertEqual(publication["state"], "ready")
        self.assertFalse(run_summary(self.database, summarize=summarized.append), "nothing is due twice")

    def test_an_openrouter_outage_never_blocks_transcription_or_notion(self) -> None:
        published: list[Path] = []

        def outage(_archive):
            raise TransientSummaryError("OpenRouter is unavailable (HTTP 503: No available provider).")

        result = run_once(
            self.database, processor=lambda *_: None, publisher=published.append,
            summarize=outage, lease_seconds=60,
        )

        self.assertTrue(result["processed"])
        self.assertTrue(result["published"])
        self.assertEqual(published, [self.archive])
        job = self.summary_job()
        self.assertEqual(job["state"], "retry_wait")
        self.assertIn("HTTP 503", job["last_error"])

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
            raise TransientSummaryError("Couldn't reach OpenRouter (TimeoutError).")

        for attempt in range(1, MAX_ATTEMPTS + 1):
            self.assertFalse(summaries.run_one(outage))
            job = summaries.status()["jobs"][0]
            self.assertEqual(job["attempts"], attempt)
            if attempt < MAX_ATTEMPTS:
                self.assertEqual(job["state"], "retry_wait")
                self.assertFalse(summaries.run_one(outage), "not due yet")
                now[0] = job["available_at"]
        self.assertEqual(job["state"], "permanent_failure")

    def test_retry_after_and_an_empty_balance_push_the_next_try_back(self) -> None:
        self.complete_processing()
        now = [1000.0]
        summaries = SummaryQueue(self.database, clock=lambda: now[0])
        summaries.reconcile(self.queue.status()["jobs"])

        # The usual backoff is 1, 2, 4 then 8 minutes. A longer wait asked for wins.
        for attempt, (error, wait) in enumerate((
            (TransientSummaryError("OpenRouter is unavailable (HTTP 502)."), 60.0),
            (TransientSummaryError("OpenRouter is rate limiting summaries (HTTP 429).", retry_after=900.0), 900.0),
            (TransientSummaryError("The OpenRouter key is out of credits (HTTP 402).", retry_after=3600.0), 3600.0),
            (TransientSummaryError("OpenRouter is unavailable (HTTP 503).", retry_after=5.0), 480.0),
        ), start=1):
            def fail(_archive, error=error):
                raise error

            self.assertFalse(summaries.run_one(fail))
            job = summaries.status()["jobs"][0]
            self.assertEqual((job["state"], job["attempts"]), ("retry_wait", attempt))
            self.assertEqual(job["available_at"], now[0] + wait)
            now[0] = job["available_at"]

    def test_permanent_failure_waits_for_an_explicit_retry(self) -> None:
        self.complete_processing()
        summaries = SummaryQueue(self.database)
        summaries.reconcile(self.queue.status()["jobs"])

        def refused(_archive):
            raise PermanentSummaryError("The model declined to summarize this meeting.")

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
