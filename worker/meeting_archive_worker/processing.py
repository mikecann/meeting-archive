"""Dependency-injected transcript processing primitives."""

from __future__ import annotations

from pathlib import Path
import math
import re
from typing import Any, Protocol

from .manifest import VerifiedManifest


class AudioTranscriber(Protocol):
    def transcribe(
        self,
        path: Path,
        channel_origin: str,
        *,
        single_speaker: bool = False,
    ) -> list[dict[str, Any]]:
        """Return timestamped transcript turns for one preserved source channel.

        With single_speaker, every turn belongs to one speaker instead of the
        channel being diarized.
        """


#: Seconds of transcribed incoming speech before a recording counts as a call.
#: A phrase from a video playing nearby, or Whisper filling silence, is not one.
MINIMUM_INCOMING_SPEECH_SECONDS = 30.0


def microphone_is_one_speaker(incoming_turns: list[dict[str, Any]], *, source_app: str | None = None) -> bool:
    """Whether the whole microphone track is one speaker.

    Mike wears headphones on calls, so when people on the incoming track
    talked, the microphone heard only him. Diarizing it would just split his
    voice into several speakers to review. A manual recording is for a meeting
    in the room, and a recording with little incoming speech isn't a call, so
    in those the microphone hears everyone and is diarized.
    """
    if source_app == "manual":
        return False
    speech = sum(
        max(0.0, float(turn.get("end", 0.0)) - float(turn.get("start", 0.0)))
        for turn in incoming_turns
        if str(turn.get("text", "")).strip()
    )
    return speech >= MINIMUM_INCOMING_SPEECH_SECONDS


#: How far apart, in seconds, a mic line and the call audio it echoes can sit.
#: Whisper cuts the two tracks into segments at different places.
ECHO_WINDOW_SECONDS = 2.0
#: The share of a mic line's words that must appear, in order, in what the
#: call audio said around the same time for the line to count as echo.
ECHO_MATCH_RATIO = 0.7


def _words(text: str) -> list[str]:
    return re.findall(r"[a-z0-9']+", text.lower())


def _common_in_order(first: list[str], second: list[str]) -> int:
    """Length of the longest run of words the two share in the same order."""
    previous = [0] * (len(second) + 1)
    for word in first:
        current = [0]
        for index, other in enumerate(second, start=1):
            current.append(previous[index - 1] + 1 if word == other else max(previous[index], current[index - 1]))
        previous = current
    return previous[-1]


def remove_echoed_microphone_turns(turns: list[dict[str, Any]]) -> tuple[list[dict[str, Any]], int]:
    """Drop mic lines that are the call audio heard through the speakers.

    Without headphones the microphone hears the other side too, and the
    transcript says everything twice, the second time as if Mike said it. A
    mic line counts as echo when most of its words appear, in order, in what
    the call audio said within a couple of seconds. A one or two word line
    must match completely, so Mike's own short replies survive.
    """
    incoming = [turn for turn in turns if turn.get("channel_origin") == "incoming"]
    kept: list[dict[str, Any]] = []
    removed = 0
    for turn in turns:
        words = _words(str(turn.get("text", ""))) if turn.get("channel_origin") == "microphone" else []
        if not words:
            kept.append(turn)
            continue
        heard = [
            word
            for other in incoming
            if other["start"] <= turn["end"] + ECHO_WINDOW_SECONDS and other["end"] >= turn["start"] - ECHO_WINDOW_SECONDS
            for word in _words(str(other.get("text", "")))
        ]
        matched = _common_in_order(words, heard) if heard else 0
        echo = matched == len(words) if len(words) <= 2 else matched / len(words) >= ECHO_MATCH_RATIO
        if echo:
            removed += 1
        else:
            kept.append(turn)
    return kept, removed


class TranscriptProcessor:
    """Transcribe preserved channels separately and merge their timelines.

    Channel provenance describes where captured bytes came from. It is not a
    speaker identity: a room microphone may contain several people, while an
    incoming channel may contain every remote participant.
    """

    CHANNEL_KINDS = {
        "microphone_audio": "microphone",
        "incoming_audio": "incoming",
    }

    def __init__(self, transcriber: AudioTranscriber, source_offsets: dict[str, float] | None = None):
        self.transcriber = transcriber
        self.source_offsets = source_offsets or {}
        self.echo_turns_removed = 0

    def process(
        self,
        archive_directory: Path | str,
        manifest: VerifiedManifest,
    ) -> dict[str, Any]:
        root = Path(archive_directory)
        channels = [
            (item, self.CHANNEL_KINDS[item.kind])
            for item in manifest.files
            if item.kind in self.CHANNEL_KINDS
        ]
        turns: list[dict[str, Any]] = []
        incoming_turns: list[dict[str, Any]] = []
        source_app = manifest.metadata.get("source_app") if isinstance(manifest.metadata, dict) else None
        # Incoming goes first, since whether anyone remote spoke decides how
        # the microphone is labelled.
        for item, channel_origin in sorted(channels, key=lambda channel: channel[1] != "incoming"):
            path = root.joinpath(*item.path.split("/"))
            single_speaker = channel_origin == "microphone" and microphone_is_one_speaker(incoming_turns, source_app=source_app)
            for raw_turn in self.transcriber.transcribe(path, channel_origin, single_speaker=single_speaker):
                turn = self._validated_turn(raw_turn)
                if channel_origin == "incoming":
                    incoming_turns.append(turn)
                offset = self.source_offsets.get(channel_origin, self.metadata_offset(manifest, channel_origin))
                turn["start"] += offset
                turn["end"] += offset
                turn["channel_origin"] = channel_origin
                turns.append(turn)
        sources = [{"path": item.path, "channel_origin": channel_origin} for item, channel_origin in channels]
        turns, self.echo_turns_removed = remove_echoed_microphone_turns(turns)
        turns.sort(key=lambda turn: (turn["start"], turn["end"], turn["channel_origin"]))
        return {
            "schema_version": 1,
            "meeting_id": manifest.meeting_id,
            "manifest_revision": manifest.revision,
            "sources": sources,
            "turns": turns,
        }

    @staticmethod
    def metadata_offset(manifest: VerifiedManifest, channel_origin: str) -> float:
        raw = manifest.metadata.get("tracks", {}).get(channel_origin, {})
        value = raw.get("firstOffset", raw.get("first_offset", 0.0)) if isinstance(raw, dict) else 0.0
        if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0:
            raise ValueError(f"Invalid {channel_origin} firstOffset in metadata.json.")
        return float(value)

    @staticmethod
    def _validated_turn(raw_turn: dict[str, Any]) -> dict[str, Any]:
        if not isinstance(raw_turn, dict):
            raise ValueError("A transcriber turn must be an object.")
        start = raw_turn.get("start")
        end = raw_turn.get("end")
        text = raw_turn.get("text")
        if (
            isinstance(start, bool)
            or not isinstance(start, (int, float))
            or isinstance(end, bool)
            or not isinstance(end, (int, float))
            or not math.isfinite(start)
            or not math.isfinite(end)
            or start < 0
            or end < start
            or not isinstance(text, str)
        ):
            raise ValueError("A transcriber turn needs valid start, end, and text fields.")
        result: dict[str, Any] = {"start": float(start), "end": float(end), "text": text}
        speaker = raw_turn.get("speaker")
        if speaker is not None:
            if not isinstance(speaker, str) or not speaker.strip():
                raise ValueError("A transcriber speaker label must be a nonempty string.")
            result["speaker"] = speaker
        return result


def timeline_offset(first_offset: float, container_start_time: float | None) -> float:
    """Return the first captured sample's offset on the shared session clock.

    AAC priming and container edit lists can move ``format.start_time`` before
    the first captured sample, including to a negative timestamp. Decoders
    already remove that representation. The capture metadata is therefore the
    only clock offset that should be added to decoded transcript timestamps.
    """
    del container_start_time
    if isinstance(first_offset, bool) or not math.isfinite(first_offset) or first_offset < 0:
        raise ValueError("Capture firstOffset must be finite and nonnegative.")
    return first_offset
