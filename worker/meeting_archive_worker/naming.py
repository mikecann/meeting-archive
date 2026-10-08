"""Name a recording's voices from the conversation itself, through OpenRouter.

Diarization only says "incoming:SPEAKER_01". People say each other's names,
introduce themselves and answer to them, so one request per transcript can
usually say who is who. It is its own durable stage, queued like the summary
and run only when OPENROUTER_API_KEY is set, and the summary waits for it so
the summary can use the names. A failure here never holds up transcription,
Notion or the summary.

The request reads the transcript with its raw speaker labels, never the names
this stage wrote, so its input does not depend on its own output and a
transcript that has not changed is never paid for twice.

The model's names are kept as context names (high and medium confidence) and
used only for a voice Mike hasn't named and no voice match has named. See
SpeakerRegistry.meeting_matches_from_connection.
"""

from __future__ import annotations

import hashlib
import json
import math
import os
import re
import sys
from collections.abc import Callable, Mapping
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from .durable_files import atomic_write_text
from .speakers import CONTEXT_CONFIDENCES, SpeakerRegistry
from .summaries import (
    API_KEY_VARIABLE,
    DEFAULT_MODEL,
    MAX_METADATA_BYTES,
    MAX_PROMPT_CHARACTERS,
    MAX_TRANSCRIPT_BYTES,
    PROVIDER,
    OpenRouterSummarizer,
    PermanentSummaryError,
    SummaryQueue,
    TransientSummaryError,
    UnusableAnswerError,
    _app_name,
    _attendee_names,
    _duration_text,
    _read_json_object,
    _transcript_lines,
    summaries_disabled_reason,
)
from .titles import effective_title, title_is_automatic


NAMING_NAME = "naming.json"
SCHEMA_VERSION = 1
MODEL_VARIABLE = "MEETING_ARCHIVE_NAMING_MODEL"
MAX_NAMING_FILE_BYTES = 1024 * 1024
MAX_NAME_CHARACTERS = 100
CONFIDENCES = ("high", "medium", "low")

# Chosen by an evaluation on real meetings: with this prompt, Claude Opus 5.5
# named 36 of 42 voices correctly and none wrongly. Change the prompt or the
# schema only with another evaluation, since a wrong name is trusted.
SYSTEM_PROMPT = """You work out who the speakers are in one recording from a private meeting archive. You get the meeting's details and a transcript made by speech recognition and automatic speaker separation, so expect misheard words, misspelt names and imperfect separation.

Each transcript line is "[time] label: text". The label tells you where the voice was heard:
- microphone:SPEAKER_nn was heard by the recording computer's own microphone. The main microphone voice is Mike Cann, the person who made the recording. The separation sometimes splits Mike across several microphone labels, and sometimes picks up someone else (a person in the room, or the call leaking from the speakers) as a separate microphone label.
- incoming:SPEAKER_nn came through the call: everyone Mike was talking to. One person can be split across several incoming labels, and occasionally two people are merged under one.

For every speaker label in the roster, say who it is, using only what the conversation and the meeting details show. People will see these names and trust them, so a wrong name is much worse than null. Accept a lot of nulls.

What counts as evidence:
- Someone being addressed or introduced by name ("Thanks, Priya", "this is Tom") is a clue about the person being spoken to, not the person speaking. Confirm it: the voice that answers next, or that keeps the turn, is usually the person addressed. A name said about a third person ("Priya sent me that") says nothing about who is speaking.
- A person introducing themselves ("I'm Tom"). The label that says it is that person.
- The calendar attendee list, only when other clues say which attendee is which voice. A list is not enough on its own.
- Speech recognition turns ordinary words and mumbles into names. Before you trust a name, ask whether the sentence really addresses a person or whether it is a misheard word. A name that shows up once, awkwardly, with nobody answering to it, is not evidence.
- Never guess from how common a name is, from the topic, from job titles or from anything you know about the world. Don't pick the one attendee nobody else has been matched to just because they're left over.

Special labels:
- A small microphone label beside a much bigger one is a fragment, either of Mike or of someone else leaking in. Name it Mike only when its own lines show that (it is called Mike, or it clearly continues his sentence); otherwise null.
- Junk clusters: a label holding only a handful of short interjections ("Okay", "Yeah", "Uh-huh") is the leftovers of several different people. It is not one person, so null, even when a name seems likely.
- An automated voice (a recording announcement, a bot or an AI assistant) is named "AI".
- Two labels get the same name only when the conversation supports that they are the same person. Don't name two incoming labels with different names from one person's two halves, and don't invent a second person for a label you can't place.

Spelling: speech recognition spells names by sound. Give the clearest spelling, or the attendee list's spelling when it matches. Use a full name only when the transcript or attendee list gives one.

Return one entry per roster label: speaker (the label exactly as written), name (or null), confidence, and evidence.
- confidence "high": the name is stated outright and clearly belongs to this voice (self-introduction, or addressed by name and this voice answers, or Mike's own main microphone voice).
- confidence "medium": a single clear cue with nothing against it.
- confidence "low": only for null. If you would be at low confidence, return null.
- evidence: a short verbatim quote from the transcript that supports the name, or for a null a few words on why it's unknown."""

OUTPUT_SCHEMA: dict[str, Any] = {
    "type": "object",
    "properties": {
        "speakers": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "speaker": {"type": "string"},
                    "name": {"type": ["string", "null"]},
                    "confidence": {"type": "string", "enum": list(CONFIDENCES)},
                    "evidence": {"type": "string"},
                },
                "required": ["speaker", "name", "confidence", "evidence"],
                "additionalProperties": False,
            },
        },
    },
    "required": ["speakers"],
    "additionalProperties": False,
}


def _log(message: str) -> None:
    print(f"meeting-archive-service: {message}", file=sys.stderr, flush=True)


def naming_disabled_reason(environment: Mapping[str, str] | None = None) -> str | None:
    """Why naming is off, or None when it can run. It shares the summary's key."""
    return summaries_disabled_reason(environment)


def naming_enabled(environment: Mapping[str, str] | None = None) -> bool:
    return naming_disabled_reason(environment) is None


def naming_model(environment: Mapping[str, str] | None = None) -> str:
    """The OpenRouter model to ask: MEETING_ARCHIVE_NAMING_MODEL, or Claude Opus 5.5."""
    environment = os.environ if environment is None else environment
    return environment.get(MODEL_VARIABLE, "").strip() or DEFAULT_MODEL


# Prompt


def _raw_label(turn: dict[str, Any]) -> str:
    """The diarization label as written, whatever name has since been put on the turn."""
    speaker = turn.get("speaker")
    if isinstance(speaker, str) and speaker.strip():
        return " ".join(speaker.split())
    origin = turn.get("channel_origin")
    return origin if isinstance(origin, str) and origin.strip() else "unknown"


def _roster(transcript: dict[str, Any]) -> dict[str, tuple[int, int, float]]:
    """Each speaker label's turns, words and seconds of speech."""
    roster: dict[str, tuple[int, int, float]] = {}
    for turn in transcript.get("turns", []):
        if not isinstance(turn, dict):
            continue
        speaker = turn.get("speaker")
        if not isinstance(speaker, str) or not speaker.strip():
            continue
        words = len(str(turn.get("text", "")).split())
        if not words:
            continue
        try:
            seconds = max(0.0, float(turn["end"]) - float(turn["start"]))
        except (KeyError, TypeError, ValueError):
            seconds = 0.0
        if not math.isfinite(seconds):
            seconds = 0.0
        turns, total_words, total_seconds = roster.get(speaker, (0, 0, 0.0))
        roster[speaker] = (turns + 1, total_words + words, total_seconds + seconds)
    return roster


def build_naming_prompt(
    metadata: dict[str, Any],
    transcript: dict[str, Any],
    *,
    given_title: str | None = None,
) -> str | None:
    """The user message for one meeting, or None when nobody was identified to name.

    Lines carry raw labels, so the prompt never contains a name this stage or
    a speaker refresh wrote, and an AI title (which the summary writes after
    this) is left out for the same reason.
    """
    lines = _transcript_lines(transcript, _raw_label)
    roster = _roster(transcript)
    if not lines or not roster:
        return None
    details = ["Meeting details", f"- App: {_app_name(metadata)}"]
    duration = _duration_text(metadata)
    if duration:
        details.append(f"- Length: {duration}")
    if given_title:
        details.append(f"- Title: {given_title}")
    details.append("- Recorded by: Mike Cann")
    attendees = _attendee_names(metadata)
    if attendees:
        details.append(f"- Calendar attendees: {', '.join(attendees)}")
    speakers = [
        f"- {speaker}: {turns} turn{'s' if turns != 1 else ''}, {words} word{'s' if words != 1 else ''}"
        for speaker, (turns, words, _) in sorted(roster.items())
    ]
    return (
        "\n".join(details)
        + "\n\nSpeakers\n" + "\n".join(speakers)
        + "\n\nTranscript\n" + "\n".join(lines) + "\n"
    )


def input_digest(prompt: str, model: str) -> str:
    """Identifies everything sent to the model, so an unchanged transcript isn't paid for twice."""
    material = json.dumps(
        {"model": model, "system": SYSTEM_PROMPT, "schema": OUTPUT_SCHEMA, "prompt": prompt},
        ensure_ascii=False,
        sort_keys=True,
    )
    return hashlib.sha256(material.encode("utf-8")).hexdigest()


# The answer


def validate_answer(answer: Any) -> dict[str, Any]:
    """Check the answer against OUTPUT_SCHEMA, which not every provider enforces, then tidy it."""
    if not isinstance(answer, dict) or set(answer) != {"speakers"} or not isinstance(answer["speakers"], list):
        raise UnusableAnswerError("The answer was not an object with just a list of speakers.")
    speakers = []
    for entry in answer["speakers"]:
        if (
            not isinstance(entry, dict)
            or set(entry) != {"speaker", "name", "confidence", "evidence"}
            or not isinstance(entry["speaker"], str)
            or not isinstance(entry["evidence"], str)
            or not (entry["name"] is None or isinstance(entry["name"], str))
            or entry["confidence"] not in CONFIDENCES
        ):
            raise UnusableAnswerError("A speaker in the answer did not have a speaker, name, confidence and evidence.")
        name = " ".join(entry["name"].split()) if entry["name"] is not None else ""
        speakers.append({
            "speaker": entry["speaker"].strip(),
            # Too long to be a name: the model wrote a sentence.
            "name": name if name and len(name) <= MAX_NAME_CHARACTERS else None,
            "confidence": entry["confidence"],
            "evidence": " ".join(entry["evidence"].split())[:500],
        })
    return {"speakers": speakers}


class OpenRouterNamer(OpenRouterSummarizer):
    """The summary's OpenRouter request with the naming prompt, schema and check."""

    system_prompt = SYSTEM_PROMPT
    schema = OUTPUT_SCHEMA
    schema_name = "speaker_names"

    @staticmethod
    def validate(answer: Any) -> dict[str, Any]:
        return validate_answer(answer)

    def name_speakers(self, prompt: str) -> dict[str, Any]:
        return self.summarize(prompt)


# Archive files


def read_naming(archive_directory: Path | str, metadata: dict[str, Any]) -> dict[str, Any] | None:
    """This meeting revision's naming.json, or None when there isn't a valid one."""
    meeting_id = metadata.get("meeting_id") if isinstance(metadata, dict) else None
    revision = metadata.get("manifest_revision", 1) if isinstance(metadata, dict) else None
    if not isinstance(meeting_id, str) or isinstance(revision, bool) or not isinstance(revision, int):
        return None
    try:
        value = _read_json_object(
            Path(archive_directory) / "transcripts" / f"v{revision}" / NAMING_NAME,
            MAX_NAMING_FILE_BYTES,
            NAMING_NAME,
        )
    except (PermanentSummaryError, TransientSummaryError):
        return None
    if (
        value.get("schema_version") != SCHEMA_VERSION
        or value.get("meeting_id") != meeting_id
        or value.get("manifest_revision") != revision
        or not isinstance(value.get("input_sha256"), str)
        or not isinstance(value.get("speakers"), list)
    ):
        return None
    return value


def _load(archive_directory: Path | str) -> tuple[Path, dict[str, Any], str, int, dict[str, Any]]:
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
    return archive, metadata, meeting_id, revision, transcript


def _prompt(archive: Path, metadata: dict[str, Any], transcript: dict[str, Any]) -> str | None:
    # Only a title someone chose is context. An automatic one may be the AI's
    # own, written from the names this stage produced.
    given_title = None if title_is_automatic(archive, metadata) else effective_title(archive, metadata)
    prompt = build_naming_prompt(metadata, transcript, given_title=given_title)
    if prompt is not None and len(prompt) > MAX_PROMPT_CHARACTERS:
        raise PermanentSummaryError(
            f"The transcript is too long to name speakers in one request ({len(prompt)} characters).",
        )
    return prompt


def naming_is_stale(archive_directory: Path | str, model: str) -> bool:
    """Whether naming would send a different request than the last one.

    A speaker refresh asks this after rewriting a transcript: it only changes
    names, which the request ignores, so this is normally False and costs a
    file read.
    """
    try:
        archive, metadata, _, _, transcript = _load(archive_directory)
        prompt = _prompt(archive, metadata, transcript)
    except (PermanentSummaryError, TransientSummaryError):
        return False
    if prompt is None:
        return False
    naming = read_naming(archive, metadata)
    return naming is None or naming.get("input_sha256") != input_digest(prompt, model)


def name_archive(
    archive_directory: Path | str,
    namer: Any,
    registry: SpeakerRegistry,
) -> dict[str, Any]:
    """Write transcripts/vN/naming.json and record the names for matching.

    Idempotent: a request made from the same transcript, prompt and model is
    reused without calling OpenRouter. Either way the names are saved to the
    registry again, which is cheap and repairs a database that lost them. Where
    the voice agrees with a name at high confidence it is also learned.
    """
    archive, metadata, meeting_id, revision, transcript = _load(archive_directory)
    prompt = _prompt(archive, metadata, transcript)
    if prompt is None:
        return {"naming_written": False, "names": 0, "reason": "no_speech"}
    digest = input_digest(prompt, namer.model)
    naming = read_naming(archive, metadata)
    written = False
    if naming is None or naming.get("input_sha256") != digest:
        answer = namer.name_speakers(prompt)
        naming = {
            "schema_version": SCHEMA_VERSION,
            "meeting_id": meeting_id,
            "manifest_revision": revision,
            "provider": PROVIDER,
            "model": namer.model,
            "served_by": answer["served_by"],
            "input_sha256": digest,
            "speakers": answer["speakers"],
            "usage": answer.get("usage", {}),
            "generated_at": datetime.now(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        }
        atomic_write_text(
            archive / "transcripts" / f"v{revision}" / NAMING_NAME,
            json.dumps(naming, ensure_ascii=False, sort_keys=True, indent=2) + "\n",
        )
        written = True
    roster = _roster(transcript)
    # One entry per label that is in this transcript; the first one wins.
    entries: dict[str, dict[str, Any]] = {}
    for entry in naming["speakers"]:
        speaker = entry.get("speaker") if isinstance(entry, dict) else None
        if speaker in roster and speaker not in entries:
            entries[speaker] = entry
    kept = registry.set_context_names(
        meeting_id,
        revision,
        [entry for entry in entries.values() if entry.get("confidence") in CONTEXT_CONFIDENCES],
        {speaker: (seconds, words) for speaker, (_, words, seconds) in roster.items()},
    )
    # The conversation and the voice may now agree on someone. Never raises: a
    # profile that isn't learned today is learned when the next meeting names it.
    learned = registry.learn_from_context(meeting_id, revision)
    return {"naming_written": written, "names": kept, "voices_learned": len(learned)}


def make_openrouter_namer(database: Path | str) -> Callable[[Path], dict[str, Any]]:
    """The service's namer, using the key loaded from Bruce's credentials file."""
    registry = SpeakerRegistry(database)

    def name(archive_directory: Path) -> dict[str, Any]:
        api_key = os.environ.get(API_KEY_VARIABLE, "").strip()
        if not api_key:
            raise TransientSummaryError(f"{API_KEY_VARIABLE} is not set.")
        return name_archive(archive_directory, OpenRouterNamer(api_key, model=naming_model()), registry)

    return name


# Durable stage


class NamingQueue(SummaryQueue):
    """One naming job per succeeded processing job, with the summary's life
    cycle and retries. The summary waits while a meeting's job is ready or
    running, but not while it is waiting to retry or has failed."""

    TABLE = "naming_jobs"
    RUNNING = "naming"
    WHAT = "naming"
    GO_FIRST = None


__all__ = [
    "NamingQueue",
    "OpenRouterNamer",
    "build_naming_prompt",
    "make_openrouter_namer",
    "name_archive",
    "naming_disabled_reason",
    "naming_enabled",
    "naming_is_stale",
    "naming_model",
    "read_naming",
]
