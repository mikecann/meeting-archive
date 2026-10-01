"""AI titles and short summaries for transcribed meetings, written by Claude through OpenRouter.

This is its own durable stage, like Notion publication. It runs on its own
service thread, only when OPENROUTER_API_KEY is set, once a meeting's
transcript is written. An OpenRouter outage never holds up transcription or
Notion: the page is published without a summary and updated when one arrives.

Requests go through the standard library's urllib, so the worker needs no SDK
and the tests never touch the network.
"""

from __future__ import annotations

import email.utils
import hashlib
import http.client
import json
import math
import os
import re
import socket
import sqlite3
import stat
import sys
import time
import urllib.error
import urllib.request
import uuid
from collections.abc import Callable, Mapping
from datetime import UTC, datetime
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from .db import closing_connection
from .durable_files import atomic_write_text
from .queue import MAX_ATTEMPTS, RETRY_BASE_SECONDS, RETRY_MAXIMUM_SECONDS, _retry_delay
from .titles import apply_generated_title, effective_title, normalize_title, title_is_automatic


SUMMARY_NAME = "summary.json"
SCHEMA_VERSION = 1
PROVIDER = "openrouter"
ENDPOINT = "https://openrouter.ai/api/v1/chat/completions"
APP_TITLE = "Meeting Archive"
API_KEY_VARIABLE = "OPENROUTER_API_KEY"
MODEL_VARIABLE = "MEETING_ARCHIVE_SUMMARY_MODEL"
DEFAULT_MODEL = "anthropic/claude-opus-5.5"
# Claude always thinks before answering and the thinking counts towards
# max_tokens. Low effort keeps it short; if it still runs out, one retry gets
# more room.
MAX_TOKENS = 2_000
LONG_MAX_TOKENS = 16_000
REQUEST_TIMEOUT_SECONDS = 300.0
MAX_RESPONSE_BYTES = 8 * 1024 * 1024
MAX_ERROR_BODY_BYTES = 64 * 1024
# Credits come back when someone tops up, not a minute later, so running out
# waits the longest backoff between tries.
OUT_OF_CREDITS_WAIT_SECONDS = RETRY_MAXIMUM_SECONDS
# A longer Retry-After counts as a day, so one odd header can't park a summary
# for weeks.
MAX_RETRY_AFTER_SECONDS = 86_400.0
# About 750k tokens, inside the model's 1M context. A longer transcript fails
# visibly rather than being cut short.
MAX_PROMPT_CHARACTERS = 3_000_000
MAX_METADATA_BYTES = 1024 * 1024
MAX_TRANSCRIPT_BYTES = 16 * 1024 * 1024
MAX_SUMMARY_FILE_BYTES = 1024 * 1024
MAX_POINT_CHARACTERS = 1_000
# Consecutive turns from one speaker share a line for up to this long.
MERGE_TURN_SECONDS = 120.0
LEASE_SECONDS = 1800.0
# Speaker names arrive a few at a time from the review window. Summarize
# again once they have settled, so the summary can use them.
SPEAKER_NAMES_SETTLE_SECONDS = 300.0

SYSTEM_PROMPT = """You write the title and a short summary for one recording in a private meeting archive. You get the meeting's details and a transcript made by speech recognition, so expect misheard words and missing punctuation. Each transcript line starts with a rough timestamp and who spoke. Local speakers were heard by the recorder's own microphone and remote speakers came through the call.

Return:
- title: a specific title of at most eight words saying what the meeting was about, like "Q3 launch plan with the design team". No date or time, no app name, and don't start with "Meeting" or "Call".
- summary: three to five short bullet points covering the main topics, decisions and outcomes, most important first. One plain sentence each.
- action_items: concrete follow-ups someone agreed to do, saying who will do each one when the transcript makes that clear. An empty list when there are none.

Use people's names when the transcript or the attendee list gives them. Speakers without a name are labelled like "Remote speaker 1"; don't repeat those labels, describe the person or leave them out. A title in the details was chosen by a person or came from the calendar, so treat it as context. Write in plain Australian English, don't use em dashes, and never add anything the transcript doesn't support."""

OUTPUT_SCHEMA: dict[str, Any] = {
    "type": "object",
    "properties": {
        "title": {"type": "string"},
        "summary": {"type": "array", "items": {"type": "string"}},
        "action_items": {"type": "array", "items": {"type": "string"}},
    },
    "required": ["title", "summary", "action_items"],
    "additionalProperties": False,
}


class SummaryError(RuntimeError):
    """A summary attempt failed. The message is safe to show and store."""


class PermanentSummaryError(SummaryError):
    """Sending the same request again won't help. `retry` releases it."""


class TransientSummaryError(SummaryError):
    """OpenRouter, the model or the network had a problem. Retried with backoff."""

    def __init__(self, message: str, *, retry_after: float = 0.0) -> None:
        super().__init__(message)
        # The least time to wait before trying again, from Retry-After or an
        # empty credit balance. The queue's own backoff applies when longer.
        self.retry_after = retry_after


class UnusableAnswerError(TransientSummaryError):
    """The answer wasn't JSON in the expected shape. Asked for once more, then permanent."""


def _log(message: str) -> None:
    print(f"meeting-archive-service: {message}", file=sys.stderr, flush=True)


def summaries_disabled_reason(environment: Mapping[str, str] | None = None) -> str | None:
    """Why summaries are off, or None when they can run."""
    environment = os.environ if environment is None else environment
    if not environment.get(API_KEY_VARIABLE, "").strip():
        return f"{API_KEY_VARIABLE} is not set"
    return None


def summaries_enabled(environment: Mapping[str, str] | None = None) -> bool:
    return summaries_disabled_reason(environment) is None


def summary_model(environment: Mapping[str, str] | None = None) -> str:
    """The OpenRouter model to ask: MEETING_ARCHIVE_SUMMARY_MODEL, or Claude Opus 5.5."""
    environment = os.environ if environment is None else environment
    return environment.get(MODEL_VARIABLE, "").strip() or DEFAULT_MODEL


# Prompt


def _clock(seconds: float) -> str:
    total = int(seconds)
    hours, remainder = divmod(total, 3600)
    minutes, seconds_part = divmod(remainder, 60)
    if hours:
        return f"{hours}:{minutes:02d}:{seconds_part:02d}"
    return f"{minutes}:{seconds_part:02d}"


def _speaker_label(turn: dict[str, Any]) -> str:
    name = turn.get("name")
    if isinstance(name, str) and name.strip():
        return " ".join(name.split())
    speaker = turn.get("speaker")
    origin = turn.get("channel_origin")
    number = None
    if isinstance(speaker, str) and speaker.strip():
        if ":" not in speaker:
            return " ".join(speaker.split())
        origin, _, raw = speaker.partition(":")
        match = re.fullmatch(r"SPEAKER_(\d+)", raw)
        number = int(match.group(1)) + 1 if match else None
    side = {"microphone": "Local", "incoming": "Remote"}.get(origin) if isinstance(origin, str) else None
    if side is None:
        return "Unknown speaker"
    return f"{side} speaker {number}" if number is not None else f"{side} speaker"


def _transcript_lines(transcript: dict[str, Any]) -> list[str]:
    lines: list[str] = []
    label: str | None = None
    started = 0.0
    parts: list[str] = []

    def flush() -> None:
        if label is not None and parts:
            lines.append(f"[{_clock(started)}] {label}: {' '.join(parts)}")

    for turn in transcript.get("turns", []):
        if not isinstance(turn, dict):
            continue
        text = " ".join(str(turn.get("text", "")).split())
        if not text:
            continue
        try:
            start = float(turn.get("start", 0.0))
        except (TypeError, ValueError):
            start = 0.0
        if not math.isfinite(start) or start < 0:
            start = 0.0
        speaker = _speaker_label(turn)
        if speaker == label and start - started <= MERGE_TURN_SECONDS:
            parts.append(text)
            continue
        flush()
        label, started, parts = speaker, start, [text]
    flush()
    return lines


def _app_name(metadata: dict[str, Any]) -> str:
    if metadata.get("source_app") == "manual":
        return "none, started with Record now (probably an in-person meeting)"
    capture = metadata.get("capture")
    source = capture.get("sourceApplication") if isinstance(capture, dict) else None
    name = source.get("displayName") if isinstance(source, dict) else None
    if isinstance(name, str) and name.strip():
        return name.strip()
    raw = metadata.get("source_app")
    return raw.strip() if isinstance(raw, str) and raw.strip() else "unknown"


def _started_text(metadata: dict[str, Any]) -> str | None:
    raw = metadata.get("started_at")
    if not isinstance(raw, str):
        return None
    try:
        started = datetime.fromisoformat(raw)
    except ValueError:
        return None
    zone_name = metadata.get("timezone")
    if started.tzinfo is not None and isinstance(zone_name, str) and zone_name.strip():
        try:
            started = started.astimezone(ZoneInfo(zone_name))
        except (ZoneInfoNotFoundError, KeyError, ValueError):
            zone_name = None
    else:
        zone_name = None
    hour = started.hour % 12 or 12
    meridiem = "am" if started.hour < 12 else "pm"
    text = f"{started:%A} {started.day} {started:%B} {started.year}, {hour}:{started.minute:02d} {meridiem}"
    return f"{text} ({zone_name})" if zone_name else text


def _duration_text(metadata: dict[str, Any]) -> str | None:
    seconds = metadata.get("duration_seconds")
    if isinstance(seconds, bool) or not isinstance(seconds, (int, float)) or not math.isfinite(seconds) or seconds < 0:
        return None
    minutes = round(seconds / 60)
    if minutes < 1:
        return "under a minute"
    hours, minutes = divmod(minutes, 60)
    parts = []
    if hours:
        parts.append(f"{hours} hour{'s' if hours != 1 else ''}")
    if minutes:
        parts.append(f"{minutes} minute{'s' if minutes != 1 else ''}")
    return " ".join(parts)


def _attendee_names(metadata: dict[str, Any]) -> list[str]:
    from .cli import _matched_event_attendees

    names: list[str] = []
    for raw in _matched_event_attendees(metadata):
        name = raw if isinstance(raw, str) else raw.get("name") if isinstance(raw, dict) else None
        if isinstance(name, str):
            name = " ".join(name.split())
            if name and name not in names:
                names.append(name)
    return names


def build_prompt(
    metadata: dict[str, Any],
    transcript: dict[str, Any],
    *,
    given_title: str | None = None,
) -> str | None:
    """The user message for one meeting, or None when nobody spoke."""
    lines = _transcript_lines(transcript)
    if not lines:
        return None
    details = ["Meeting details", f"- App: {_app_name(metadata)}"]
    started = _started_text(metadata)
    if started:
        details.append(f"- Started: {started}")
    duration = _duration_text(metadata)
    if duration:
        details.append(f"- Length: {duration}")
    if given_title:
        details.append(f"- Title: {given_title}")
    attendees = _attendee_names(metadata)
    if attendees:
        details.append(f"- Calendar attendees: {', '.join(attendees)}")
    return "\n".join(details) + "\n\nTranscript\n" + "\n".join(lines) + "\n"


def input_digest(prompt: str, model: str) -> str:
    """Identifies everything sent to the model, so an unchanged meeting isn't paid for twice."""
    material = json.dumps(
        {"model": model, "system": SYSTEM_PROMPT, "schema": OUTPUT_SCHEMA, "prompt": prompt},
        ensure_ascii=False,
        sort_keys=True,
    )
    return hashlib.sha256(material.encode("utf-8")).hexdigest()


# The answer


def _points(value: Any, label: str, minimum: int, maximum: int) -> list[str]:
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        raise UnusableAnswerError(f"The answer's {label} were not a list of text.")
    points = []
    for item in value:
        text = re.sub(r"^[-*•]\s*", "", " ".join(item.split())).strip()
        if text:
            points.append(text)
    if not minimum <= len(points) <= maximum:
        raise UnusableAnswerError(f"The answer had {len(points)} {label}.")
    if any(len(point) > MAX_POINT_CHARACTERS for point in points):
        raise UnusableAnswerError(f"The answer's {label} were unexpectedly long.")
    return points


def validate_answer(answer: Any) -> dict[str, Any]:
    """Check the answer against OUTPUT_SCHEMA, which not every provider enforces, then tidy it."""
    if not isinstance(answer, dict) or set(answer) != set(OUTPUT_SCHEMA["required"]):
        raise UnusableAnswerError("The answer was not an object with just a title, summary and action_items.")
    if not isinstance(answer["title"], str):
        raise UnusableAnswerError("The answer's title was not text.")
    title = " ".join(answer["title"].split()).strip(" \"'“”‘’").rstrip(".").strip()
    try:
        title = normalize_title(title)
    except ValueError as error:
        raise UnusableAnswerError(f"The answer's title was unusable: {error}") from None
    return {
        "title": title,
        "summary": _points(answer["summary"], "summary points", 1, 10),
        "action_items": _points(answer["action_items"], "action items", 0, 20),
    }


# OpenRouter


# Printable ASCII with no spaces, like every OpenRouter key. A line break would
# make http.client refuse the header in an error that repeats it, key included.
_API_KEY_PATTERN = re.compile(r"[\x21-\x7e]+")


def _retry_after_seconds(headers: Any) -> float:
    """How long a Retry-After header asks us to wait, or 0 without a usable one."""
    value = headers.get("Retry-After") if headers is not None else None
    if value is None:
        return 0.0
    value = str(value).strip()
    try:
        seconds = float(value)
    except ValueError:
        try:
            when = email.utils.parsedate_to_datetime(value)
        except (TypeError, ValueError, IndexError, OverflowError):
            return 0.0
        if when.tzinfo is None:
            when = when.replace(tzinfo=UTC)
        seconds = (when - datetime.now(UTC)).total_seconds()
    if not math.isfinite(seconds) or seconds <= 0:
        return 0.0
    return min(seconds, MAX_RETRY_AFTER_SECONDS)


def _status_error(status: Any, detail: Any, headers: Any = None) -> SummaryError:
    """Sort an OpenRouter error by whether sending the same request again can help.

    Only OpenRouter's short message is kept. Its metadata can quote the
    transcript (a moderation flag does), so it never reaches a log.
    """
    message = ""
    if isinstance(detail, dict):
        message = " ".join(str(detail.get("message") or "").split())[:300].rstrip(".")
    if isinstance(status, bool) or not isinstance(status, int):
        return TransientSummaryError(f"OpenRouter reported an error ({message or 'no details'}).")
    label = f"HTTP {status}: {message}" if message else f"HTTP {status}"
    wait = _retry_after_seconds(headers)
    if status == 401:
        return PermanentSummaryError(
            f"OpenRouter rejected the API key ({label}). Fix openRouterApiKey in Bruce's "
            "credentials file, restart the worker, then retry.",
        )
    if status == 402:
        return TransientSummaryError(
            f"The OpenRouter key is out of credits ({label}). It's tried again every hour, "
            "so topping up lets it carry on.",
            retry_after=max(OUT_OF_CREDITS_WAIT_SECONDS, wait),
        )
    if status == 429:
        return TransientSummaryError(f"OpenRouter is rate limiting summaries ({label}).", retry_after=wait)
    if 400 <= status < 500 and status not in (408, 409):
        # A bad request (400), a key without permission or a moderation block
        # (403), an unknown model (404): the same request gets the same answer.
        return PermanentSummaryError(f"OpenRouter refused the summary request ({label}).")
    return TransientSummaryError(f"OpenRouter is unavailable ({label}).", retry_after=wait)


def _http_error(error: urllib.error.HTTPError) -> SummaryError:
    try:
        raw = error.read(MAX_ERROR_BODY_BYTES)
    except (OSError, ValueError, http.client.HTTPException):
        raw = b""
    finally:
        error.close()
    try:
        body = json.loads(raw) if raw else None
    except (UnicodeDecodeError, json.JSONDecodeError):
        body = None
    return _status_error(error.code, body.get("error") if isinstance(body, dict) else None, error.headers)


def _network_error(error: BaseException) -> TransientSummaryError:
    reason = error.reason if isinstance(error, urllib.error.URLError) else error
    name = type(reason if isinstance(reason, BaseException) else error).__name__
    return TransientSummaryError(f"Couldn't reach OpenRouter ({name}).")


def _choice(completion: dict[str, Any]) -> dict[str, Any]:
    """The first choice, once refusals and errors in a 200 response are ruled out."""
    choices = completion.get("choices")
    if not isinstance(choices, list) or not choices or not isinstance(choices[0], dict):
        # A provider that fails after OpenRouter has sent its headers leaves
        # only an error object in a 200 response.
        error = completion.get("error")
        if isinstance(error, dict):
            raise _status_error(error.get("code"), error)
        raise TransientSummaryError("OpenRouter's response had no answer in it.")
    choice = choices[0]
    message = choice.get("message")
    refusal = message.get("refusal") if isinstance(message, dict) else None
    if choice.get("native_finish_reason") == "refusal" or (isinstance(refusal, str) and refusal.strip()):
        raise PermanentSummaryError("The model declined to summarize this meeting.")
    if choice.get("finish_reason") == "content_filter":
        raise PermanentSummaryError("A content filter stopped this meeting's summary.")
    if choice.get("finish_reason") == "error":
        error = choice.get("error")
        raise _status_error(error.get("code") if isinstance(error, dict) else None, error)
    return choice


def _answer(choice: dict[str, Any]) -> dict[str, Any]:
    message = choice.get("message")
    content = message.get("content") if isinstance(message, dict) else None
    if not isinstance(content, str):
        raise UnusableAnswerError("The answer had no text.")
    try:
        answer = json.loads(content)
    except json.JSONDecodeError:
        raise UnusableAnswerError("The answer was not valid JSON.") from None
    return validate_answer(answer)


def _add_usage(total: dict[str, Any], usage: Any) -> None:
    """Add one response's tokens and cost, in OpenRouter credits (US dollars), to the total."""
    total["requests"] = total.get("requests", 0) + 1
    if not isinstance(usage, dict):
        return
    details = usage.get("completion_tokens_details")
    counts = {
        "prompt_tokens": usage.get("prompt_tokens"),
        "completion_tokens": usage.get("completion_tokens"),
        "reasoning_tokens": details.get("reasoning_tokens") if isinstance(details, dict) else None,
    }
    for key, value in counts.items():
        if isinstance(value, int) and not isinstance(value, bool) and value >= 0:
            total[key] = total.get(key, 0) + value
    cost = usage.get("cost")
    if isinstance(cost, (int, float)) and not isinstance(cost, bool) and math.isfinite(cost) and cost >= 0:
        total["cost"] = round(total.get("cost", 0) + cost, 8)


class OpenRouterSummarizer:
    """Asks a model on OpenRouter for a title, summary and action items as structured JSON."""

    def __init__(self, api_key: str, *, model: str = DEFAULT_MODEL) -> None:
        if not _API_KEY_PATTERN.fullmatch(api_key):
            raise PermanentSummaryError(
                "The OpenRouter API key has spaces or unexpected characters. Fix openRouterApiKey "
                "in Bruce's credentials file, restart the worker, then retry.",
            )
        self.api_key = api_key
        self.model = model

    def summarize(self, prompt: str) -> dict[str, Any]:
        """At most three requests: one more with room to finish, one more for a usable answer."""
        usage: dict[str, Any] = {}
        max_tokens = MAX_TOKENS
        asked_again = False
        while True:
            completion = self._complete(prompt, max_tokens)
            _add_usage(usage, completion.get("usage"))
            choice = _choice(completion)
            if choice.get("finish_reason") == "length":
                if max_tokens >= LONG_MAX_TOKENS:
                    raise PermanentSummaryError(f"The answer ran past {LONG_MAX_TOKENS} tokens.")
                max_tokens = LONG_MAX_TOKENS
                continue
            try:
                answer = _answer(choice)
            except UnusableAnswerError as error:
                if asked_again:
                    raise PermanentSummaryError(f"Asked twice and neither answer was usable. {error}") from None
                asked_again = True
                continue
            # The model OpenRouter actually used, which can be a dated snapshot.
            served_by = completion.get("model")
            answer["served_by"] = served_by if isinstance(served_by, str) and served_by.strip() else self.model
            answer["usage"] = usage
            return answer

    def _complete(self, prompt: str, max_tokens: int) -> dict[str, Any]:
        body = {
            "model": self.model,
            "messages": [
                {"role": "system", "content": SYSTEM_PROMPT},
                {"role": "user", "content": prompt},
            ],
            "max_tokens": max_tokens,
            "reasoning": {"effort": "low"},
            "usage": {"include": True},
            "response_format": {
                "type": "json_schema",
                "json_schema": {"name": "meeting_summary", "strict": True, "schema": OUTPUT_SCHEMA},
            },
        }
        request = urllib.request.Request(
            ENDPOINT,
            data=json.dumps(body, ensure_ascii=False).encode("utf-8"),
            headers={"Content-Type": "application/json", "X-Title": APP_TITLE},
            method="POST",
        )
        # Left off any redirect, so the key only ever goes to OpenRouter.
        request.add_unredirected_header("Authorization", f"Bearer {self.api_key}")
        # Every failure becomes a message of our own. Nothing about the request,
        # which holds the key and the transcript, is passed on.
        try:
            with urllib.request.urlopen(request, timeout=REQUEST_TIMEOUT_SECONDS) as response:  # noqa: S310 - fixed HTTPS endpoint
                raw = response.read(MAX_RESPONSE_BYTES + 1)
        except urllib.error.HTTPError as error:
            raise _http_error(error) from None
        except (OSError, http.client.HTTPException) as error:
            raise _network_error(error) from None
        if len(raw) > MAX_RESPONSE_BYTES:
            raise TransientSummaryError("OpenRouter's response was unexpectedly large.")
        try:
            completion = json.loads(raw)
        except (UnicodeDecodeError, json.JSONDecodeError):
            raise TransientSummaryError("OpenRouter's response was not JSON.") from None
        if not isinstance(completion, dict):
            raise TransientSummaryError("OpenRouter's response was not a JSON object.")
        return completion


# Archive files


def _read_json_object(path: Path, maximum_bytes: int, label: str) -> dict[str, Any]:
    try:
        info = path.lstat()
    except FileNotFoundError as error:
        raise PermanentSummaryError(f"{label} is missing.") from error
    except OSError as error:
        raise TransientSummaryError(f"Couldn't read {label}: {error.strerror or error}") from error
    if not stat.S_ISREG(info.st_mode) or info.st_size > maximum_bytes:
        raise PermanentSummaryError(f"{label} is not a regular file within its size limit.")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except OSError as error:
        raise TransientSummaryError(f"Couldn't read {label}: {error.strerror or error}") from error
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise PermanentSummaryError(f"{label} is not valid JSON.") from error
    if not isinstance(value, dict):
        raise PermanentSummaryError(f"{label} must contain an object.")
    return value


def read_summary(archive_directory: Path | str, metadata: dict[str, Any]) -> dict[str, Any] | None:
    """This meeting revision's summary.json, or None when there isn't a valid one."""
    meeting_id = metadata.get("meeting_id") if isinstance(metadata, dict) else None
    revision = metadata.get("manifest_revision", 1) if isinstance(metadata, dict) else None
    if not isinstance(meeting_id, str) or isinstance(revision, bool) or not isinstance(revision, int):
        return None
    path = Path(archive_directory) / "transcripts" / f"v{revision}" / SUMMARY_NAME
    try:
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_size > MAX_SUMMARY_FILE_BYTES:
            return None
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        return None
    if (
        not isinstance(value, dict)
        or value.get("schema_version") != SCHEMA_VERSION
        or value.get("meeting_id") != meeting_id
        or value.get("manifest_revision") != revision
        or not isinstance(value.get("title"), str)
        or not isinstance(value.get("summary"), list)
        or not value["summary"]
        or not isinstance(value.get("action_items"), list)
        or not all(isinstance(item, str) for item in value["summary"] + value["action_items"])
    ):
        return None
    return value


def summarize_archive(archive_directory: Path | str, summarizer: Any) -> dict[str, Any]:
    """Write transcripts/vN/summary.json and give an automatic title the summary's.

    Idempotent: a summary made from the same transcript, prompt and model is
    reused without calling OpenRouter, and the title is only written when it
    changes.
    """
    archive = Path(archive_directory)
    metadata = _read_json_object(archive / "metadata.json", MAX_METADATA_BYTES, "metadata.json")
    meeting_id = metadata.get("meeting_id")
    revision = metadata.get("manifest_revision", 1)
    if not isinstance(meeting_id, str) or isinstance(revision, bool) or not isinstance(revision, int) or revision < 1:
        raise PermanentSummaryError("metadata.json has no usable meeting_id and manifest_revision.")
    directory = archive / "transcripts" / f"v{revision}"
    transcript = _read_json_object(directory / "transcript.json", MAX_TRANSCRIPT_BYTES, "transcript.json")
    if (
        transcript.get("meeting_id") != meeting_id
        or transcript.get("manifest_revision") != revision
        or not isinstance(transcript.get("turns"), list)
    ):
        raise PermanentSummaryError("transcript.json does not belong to this meeting revision.")

    given_title = None if title_is_automatic(archive, metadata) else effective_title(archive, metadata)
    prompt = build_prompt(metadata, transcript, given_title=given_title)
    if prompt is None:
        return {"summary_written": False, "title_changed": False, "reason": "no_speech"}
    if len(prompt) > MAX_PROMPT_CHARACTERS:
        raise PermanentSummaryError(
            f"The transcript is too long to summarize in one request ({len(prompt)} characters).",
        )
    digest = input_digest(prompt, summarizer.model)
    summary = read_summary(archive, metadata)
    written = False
    if summary is None or summary.get("input_sha256") != digest:
        answer = summarizer.summarize(prompt)
        summary = {
            "schema_version": SCHEMA_VERSION,
            "meeting_id": meeting_id,
            "manifest_revision": revision,
            "provider": PROVIDER,
            "model": summarizer.model,
            "served_by": answer["served_by"],
            "input_sha256": digest,
            "title": answer["title"],
            "summary": answer["summary"],
            "action_items": answer["action_items"],
            "usage": answer.get("usage", {}),
            "generated_at": datetime.now(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        }
        atomic_write_text(
            directory / SUMMARY_NAME,
            json.dumps(summary, ensure_ascii=False, sort_keys=True, indent=2) + "\n",
        )
        written = True
    title_changed = apply_generated_title(
        archive, summary["title"], metadata, model=str(summary.get("served_by") or summarizer.model),
    )
    return {"summary_written": written, "title_changed": title_changed}


def summarize_with_openrouter(archive_directory: Path) -> dict[str, Any]:
    """The service's summarizer, using the key loaded from Bruce's credentials file."""
    api_key = os.environ.get(API_KEY_VARIABLE, "").strip()
    if not api_key:
        raise TransientSummaryError(f"{API_KEY_VARIABLE} is not set.")
    return summarize_archive(archive_directory, OpenRouterSummarizer(api_key, model=summary_model()))


# Durable stage


class SummaryQueue:
    """One summary job per succeeded processing job, kept apart from
    transcription and Notion so an OpenRouter outage only delays the summary."""

    def __init__(self, database: Path | str, clock: Callable[[], float] = time.time) -> None:
        self.database = Path(database)
        self.clock = clock
        with closing_connection(self._connect) as connection:
            connection.execute(
                """CREATE TABLE IF NOT EXISTS summary_jobs (
                processing_job_id INTEGER PRIMARY KEY, archive_path TEXT NOT NULL,
                state TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0,
                available_at REAL NOT NULL, last_error TEXT,
                lease_owner TEXT, lease_expires_at REAL,
                refresh_requested INTEGER NOT NULL DEFAULT 0)""",
            )

    def _connect(self) -> sqlite3.Connection:
        return sqlite3.connect(self.database, timeout=30, isolation_level=None)

    def reconcile(self, jobs: list[dict[str, Any]]) -> None:
        """Queue a summary for every succeeded meeting, including ones processed earlier."""
        now = self.clock()
        rows = [(job["id"], job["archive_path"], now) for job in jobs if job["state"] == "succeeded"]
        if not rows:
            return
        with closing_connection(self._connect) as connection:
            connection.execute("BEGIN IMMEDIATE")
            connection.executemany(
                "INSERT OR IGNORE INTO summary_jobs "
                "(processing_job_id, archive_path, state, attempts, available_at) VALUES (?, ?, 'ready', 0, ?)",
                rows,
            )
            connection.commit()

    def request(
        self,
        processing_job_id: int,
        archive_path: str,
        *,
        delay_seconds: float = 0.0,
        create: bool = True,
    ) -> bool:
        """Ask for a summary of the current transcript. Returns whether a job exists.

        Without create, only a meeting that already has a summary job is asked
        again, so nothing is queued while summaries are off.
        """
        now = self.clock()
        available_at = now + max(0.0, delay_seconds)
        with closing_connection(self._connect) as connection:
            connection.execute("BEGIN IMMEDIATE")
            if create:
                connection.execute(
                    "INSERT OR IGNORE INTO summary_jobs "
                    "(processing_job_id, archive_path, state, attempts, available_at) VALUES (?, ?, 'ready', 0, ?)",
                    (processing_job_id, archive_path, available_at),
                )
            # SQLite evaluates every CASE against the row as it was.
            cursor = connection.execute(
                "UPDATE summary_jobs SET archive_path=?, available_at=?, "
                "state=CASE WHEN state='summarizing' THEN state ELSE 'ready' END, "
                "attempts=CASE WHEN state='summarizing' THEN attempts ELSE 0 END, "
                "last_error=CASE WHEN state='summarizing' THEN last_error ELSE NULL END, "
                "refresh_requested=CASE WHEN state='summarizing' THEN 1 ELSE 0 END "
                "WHERE processing_job_id=?",
                (archive_path, available_at, processing_job_id),
            )
            connection.commit()
        return cursor.rowcount == 1

    def retry_failed(self, processing_job_id: int) -> dict[str, Any] | None:
        """Operator retry of a failed summary, with a fresh attempt budget."""
        now = self.clock()
        with closing_connection(self._connect) as connection:
            connection.execute("BEGIN IMMEDIATE")
            row = connection.execute(
                "SELECT state FROM summary_jobs WHERE processing_job_id=?",
                (processing_job_id,),
            ).fetchone()
            if row is None:
                connection.commit()
                return None
            retried = row[0] in ("retry_wait", "permanent_failure")
            if retried:
                connection.execute(
                    "UPDATE summary_jobs SET state='ready', available_at=?, attempts=0, last_error=NULL, "
                    "lease_owner=NULL, lease_expires_at=NULL WHERE processing_job_id=?",
                    (now, processing_job_id),
                )
            connection.commit()
        return {
            "processing_job_id": processing_job_id,
            "state": "ready" if retried else str(row[0]),
            "retried": retried,
        }

    def status(self, processing_job_ids: set[int] | None = None) -> dict[str, Any]:
        query = (
            "SELECT processing_job_id, archive_path, state, attempts, available_at, "
            "last_error, lease_owner, lease_expires_at, refresh_requested FROM summary_jobs"
        )
        with closing_connection(self._connect) as connection:
            connection.row_factory = sqlite3.Row
            if processing_job_ids is None:
                rows = connection.execute(query + " ORDER BY processing_job_id").fetchall()
            elif not processing_job_ids:
                rows = []
            else:
                ordered = tuple(sorted(processing_job_ids))
                placeholders = ",".join("?" for _ in ordered)
                rows = connection.execute(
                    query + f" WHERE processing_job_id IN ({placeholders}) ORDER BY processing_job_id",
                    ordered,
                ).fetchall()
        jobs = [dict(row) for row in rows]
        counts: dict[str, int] = {}
        for job in jobs:
            counts[job["state"]] = counts.get(job["state"], 0) + 1
        phase = next(
            (state for state in ("summarizing", "retry_wait", "ready", "permanent_failure") if state in counts),
            "succeeded" if jobs else "not_queued",
        )
        return {
            "counts": counts,
            "phase": phase,
            "last_error": next((job["last_error"] for job in reversed(jobs) if job["last_error"]), None),
            "jobs": jobs,
        }

    def run_one(
        self,
        summarize: Callable[[Path], Any],
        *,
        on_success: Callable[[int, str], None] | None = None,
        lease_seconds: float = LEASE_SECONDS,
    ) -> bool:
        """Summarize at most one due meeting. Returns whether one succeeded."""
        if lease_seconds <= 0:
            raise ValueError("summary lease_seconds must be positive")
        now = self.clock()
        owner = f"{socket.gethostname()}:{uuid.uuid4()}"
        with closing_connection(self._connect) as connection:
            connection.execute("BEGIN IMMEDIATE")
            # A worker that died mid-summary counts as a failed attempt.
            for job_id, attempts in connection.execute(
                "SELECT processing_job_id, attempts FROM summary_jobs WHERE state='summarizing' "
                "AND (lease_expires_at IS NULL OR lease_expires_at<=?)",
                (now,),
            ).fetchall():
                connection.execute(
                    "UPDATE summary_jobs SET state=?, available_at=?, last_error=?, "
                    "lease_owner=NULL, lease_expires_at=NULL WHERE processing_job_id=?",
                    (
                        "permanent_failure" if attempts >= MAX_ATTEMPTS else "retry_wait",
                        now + _retry_delay(attempts, RETRY_BASE_SECONDS, RETRY_MAXIMUM_SECONDS),
                        "The worker stopped before the summary finished.",
                        job_id,
                    ),
                )
            row = connection.execute(
                "SELECT processing_job_id, archive_path, attempts FROM summary_jobs "
                "WHERE state IN ('ready','retry_wait') AND available_at<=? "
                "ORDER BY available_at, processing_job_id LIMIT 1",
                (now,),
            ).fetchone()
            if row is None:
                connection.commit()
                return False
            connection.execute(
                "UPDATE summary_jobs SET state='summarizing', attempts=attempts+1, "
                "lease_owner=?, lease_expires_at=?, refresh_requested=0 WHERE processing_job_id=?",
                (owner, now + lease_seconds, row[0]),
            )
            connection.commit()
        job_id, archive_path, attempts = int(row[0]), str(row[1]), int(row[2]) + 1
        try:
            summarize(Path(archive_path))
            # Before success is recorded, so a crash here repeats the request
            # rather than losing it. Republishing an unchanged page is a no-op.
            if on_success is not None:
                on_success(job_id, archive_path)
        except Exception as error:
            permanent = isinstance(error, PermanentSummaryError) or attempts >= MAX_ATTEMPTS
            message = str(error) if isinstance(error, SummaryError) else f"{type(error).__name__}: {error}"
            message = message[:1000]
            _log(f"summary for processing job {job_id} failed: {message}")
            delay = _retry_delay(attempts, RETRY_BASE_SECONDS, RETRY_MAXIMUM_SECONDS)
            if isinstance(error, TransientSummaryError):
                # Never sooner than OpenRouter asked, or an hour for an empty balance.
                delay = max(delay, error.retry_after)
            with closing_connection(self._connect) as connection:
                connection.execute(
                    "UPDATE summary_jobs SET state=?, available_at=?, last_error=?, refresh_requested=0, "
                    "lease_owner=NULL, lease_expires_at=NULL "
                    "WHERE processing_job_id=? AND state='summarizing' AND lease_owner=?",
                    (
                        "permanent_failure" if permanent else "retry_wait",
                        self.clock() + delay,
                        message,
                        job_id,
                        owner,
                    ),
                )
            return False
        with closing_connection(self._connect) as connection:
            cursor = connection.execute(
                "UPDATE summary_jobs SET "
                "state=CASE WHEN refresh_requested=1 THEN 'ready' ELSE 'succeeded' END, "
                "attempts=CASE WHEN refresh_requested=1 THEN 0 ELSE attempts END, "
                "last_error=NULL, refresh_requested=0, lease_owner=NULL, lease_expires_at=NULL "
                "WHERE processing_job_id=? AND state='summarizing' AND lease_owner=?",
                (job_id, owner),
            )
        return cursor.rowcount == 1


__all__ = [
    "OpenRouterSummarizer",
    "PermanentSummaryError",
    "SummaryQueue",
    "TransientSummaryError",
    "UnusableAnswerError",
    "build_prompt",
    "read_summary",
    "summaries_disabled_reason",
    "summaries_enabled",
    "summarize_archive",
    "summarize_with_openrouter",
    "summary_model",
]
