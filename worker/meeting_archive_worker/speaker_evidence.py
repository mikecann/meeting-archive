"""Keep review suggestions, automatic names, and explicit confirmations separate."""

from __future__ import annotations

import math

from .speakers import MATCH_MARGIN, STRONG_MATCH_THRESHOLD


def refresh_speaker_matches(transcript: dict, registry) -> None:
    """Refresh derived names without ever enrolling an automatic prediction."""
    meeting_id = transcript["meeting_id"]
    revision = transcript["manifest_revision"]
    assignments = registry.assignments(meeting_id, revision)
    matches = {}
    for speaker in sorted({turn["speaker"] for turn in transcript["turns"] if turn.get("speaker")}):
        observation = registry.observation_record(meeting_id, revision, speaker)
        if observation:
            embedding, model = observation
            # Exclude this recording, including other revisions of it. Otherwise
            # a prior confirmation creates a misleading perfect self-match.
            matches[speaker] = registry.review_match(
                embedding, model_id=model, exclude_meeting_id=meeting_id,
            )
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
            turn.update(name=automatic, name_source="voice_match")
        else:
            turn.pop("name", None)
            turn.pop("name_source", None)


def automatic_names(transcript: dict) -> dict[str, str]:
    """Only acknowledge strong matches already written to every affected turn."""
    result = {}
    for speaker, match in transcript.get("speaker_matches", {}).items():
        if not isinstance(match, dict):
            continue
        name = match.get("automatic_name")
        score = match.get("suggestion_score")
        margin = match.get("suggestion_margin")
        count = match.get("confirmation_count", 0)
        if (
            not isinstance(name, str) or not name.strip()
            or match.get("suggestion_kind") != "strong"
            or not isinstance(score, (int, float)) or not math.isfinite(score) or score < STRONG_MATCH_THRESHOLD
            or not isinstance(count, int) or count < 1
            or (margin is not None and (
                not isinstance(margin, (int, float)) or not math.isfinite(margin) or margin < MATCH_MARGIN
            ))
        ):
            continue
        turns = [turn for turn in transcript["turns"] if turn.get("speaker") == speaker]
        if turns and all(turn.get("name") == name and turn.get("name_source") == "voice_match" for turn in turns):
            result[speaker] = name
    return result
