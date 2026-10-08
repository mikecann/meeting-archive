"""Keep review suggestions, automatic names, and explicit confirmations separate."""

from __future__ import annotations

from .speakers import AUTOMATIC_KINDS, classify_match


def refresh_speaker_matches(transcript: dict, registry) -> None:
    """Refresh derived names without ever enrolling an automatic prediction.

    Names come in three strengths: a saved one ("confirmed"), one from the
    voice ("voice_match") and one from the conversation ("context").
    """
    meeting_id = transcript["meeting_id"]
    revision = transcript["manifest_revision"]
    assignments = registry.assignments(meeting_id, revision)
    speakers = sorted({turn["speaker"] for turn in transcript["turns"] if turn.get("speaker")})
    # Matching excludes this recording, including other revisions of it.
    # Otherwise a prior confirmation creates a misleading perfect self-match.
    matches = registry.meeting_matches(meeting_id, revision, speakers)
    transcript["speaker_matches"] = matches
    for turn in transcript["turns"]:
        speaker = turn.get("speaker")
        if not speaker:
            continue
        confirmed = assignments.get(speaker)
        automatic = matches.get(speaker, {}).get("automatic_name")
        if confirmed:
            turn.update(name=confirmed, name_source="confirmed")
        elif automatic:
            kind = matches[speaker].get("suggestion_kind")
            turn.update(name=automatic, name_source="context" if kind == "context" else "voice_match")
        else:
            turn.pop("name", None)
            turn.pop("name_source", None)


def automatic_names(transcript: dict) -> dict[str, str]:
    """Only acknowledge automatic names already written to every affected turn."""
    result = {}
    for speaker, match in transcript.get("speaker_matches", {}).items():
        if not isinstance(match, dict):
            continue
        name = match.get("automatic_name")
        kind = match.get("suggestion_kind")
        if not isinstance(name, str) or not name.strip() or kind not in AUTOMATIC_KINDS:
            continue
        if kind == "strong" and classify_match(
            match.get("suggestion_score"),
            match.get("suggestion_margin"),
            match.get("confirmation_count", 0),
        ) != "automatic":
            continue
        source = "context" if kind == "context" else "voice_match"
        turns = [turn for turn in transcript["turns"] if turn.get("speaker") == speaker]
        if turns and all(turn.get("name") == name and turn.get("name_source") == source for turn in turns):
            result[speaker] = name
    return result
