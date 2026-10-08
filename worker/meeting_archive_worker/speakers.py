"""Speaker assignments. Mike's saved names enroll voices. A prediction never enrolls
itself; the one exception is learn_from_context, where the conversation and the
voice must agree."""

from __future__ import annotations

import sqlite3
import json
import math
from datetime import UTC, datetime
from pathlib import Path

from .db import closing_connection


# Cosine similarity between pyannote voice embeddings. These are not
# probabilities. They were set from Mike's own voices on Bruce on 2 Oct 2026:
# 22 confirmed voices from 9 meetings. Two different people never scored above
# 0.654 against each other (0.640 within one meeting), so every gate that names
# someone automatically sits a safety margin above that.
#
# A voice this close to a profile is named automatically after one confirmed
# meeting.
STRONG_MATCH_THRESHOLD = 0.82
# A voice this close is the same person. It is named automatically once that
# person was confirmed in KNOWN_VOICE_MEETINGS meetings, so one mistaken name
# can't spread. Within one meeting, a voice this close to one Mike saved gets
# that name.
SAME_VOICE_THRESHOLD = 0.72
KNOWN_VOICE_MEETINGS = 2
# A voice this close is suggested, never named, after two confirmed meetings.
# A suggestion is filled in for review, so it is saved with one click.
TENTATIVE_MATCH_THRESHOLD = 0.65
# The only speaker on the microphone is named as the person whose voice the
# microphone usually carries, once it scores this against them. Other people
# heard through Mike's microphone scored at most 0.612 against him; his own
# microphone tracks scored 0.72 to 0.96.
OWN_MICROPHONE_THRESHOLD = 0.65
# The best name must beat the next one by this much. No wrong name on the data
# above was stopped by it; it guards two enrolled people who sound alike.
MATCH_MARGIN = 0.08
# A new confirmation can change matches in other meetings whose voices are at
# least this close to it, so those meetings are refreshed.
REFRESH_SIMILARITY = TENTATIVE_MATCH_THRESHOLD - MATCH_MARGIN

# A voice the conversation named with high confidence is enrolled when it also
# scores this against an enrolled profile of that same name, or against a voice
# another meeting's conversation gave that name. The highest score between two
# different people was 0.654, so the matching name, not the score, is what
# makes this safe.
CONTEXT_ENROLL_THRESHOLD = 0.55
# A voice heard for less than this, or in fewer words, is a junk cluster of
# interjections and never makes a profile.
CONTEXT_MINIMUM_SPEECH_SECONDS = 15.0
CONTEXT_MINIMUM_WORDS = 40
#: How sure the naming model was. Only these two are kept.
CONTEXT_CONFIDENCES = ("high", "medium")

#: Kinds of automatic name, as written to transcript speaker_matches.
#: "context" is a name the conversation gave a voice, not a voice match.
AUTOMATIC_KINDS = frozenset({"strong", "own_microphone", "same_meeting", "context"})
#: Bump when the rules above change. The service then refreshes every meeting
#: with an unnamed voice once, so older meetings get the new rules without
#: anyone opening them.
MATCHING_RULES_VERSION = 2


def classify_match(score: float | None, margin: float | None, confirmation_count: int) -> str | None:
    """Whether the best cross-meeting match is "automatic", "tentative" or neither."""
    if (
        not isinstance(score, (int, float))
        or isinstance(score, bool)
        or not math.isfinite(score)
        or not isinstance(confirmation_count, int)
        or isinstance(confirmation_count, bool)
        or confirmation_count < 1
    ):
        return None
    if margin is not None and (
        not isinstance(margin, (int, float))
        or isinstance(margin, bool)
        or not math.isfinite(margin)
        or margin < MATCH_MARGIN
    ):
        return None
    if score >= STRONG_MATCH_THRESHOLD:
        return "automatic"
    if confirmation_count < KNOWN_VOICE_MEETINGS:
        return None
    if score >= SAME_VOICE_THRESHOLD:
        return "automatic"
    if score >= TENTATIVE_MATCH_THRESHOLD:
        return "tentative"
    return None


class SpeakerRegistry:
    def __init__(self, database: Path | str):
        self.database = Path(database)
        with closing_connection(
            lambda: sqlite3.connect(self.database, timeout=30, isolation_level=None),
        ) as connection:
            # Schema inspection and ALTER must share the same writer lock. The
            # app can invoke review while the service starts after an upgrade.
            connection.execute("BEGIN IMMEDIATE")
            connection.execute(
                """CREATE TABLE IF NOT EXISTS speaker_assignments (
                meeting_id TEXT NOT NULL, manifest_revision INTEGER NOT NULL,
                speaker_id TEXT NOT NULL, display_name TEXT NOT NULL,
                confirmed_at TEXT NOT NULL, PRIMARY KEY(meeting_id, manifest_revision, speaker_id))""",
            )
            connection.execute(
                """CREATE TABLE IF NOT EXISTS voice_profiles (
                display_name TEXT NOT NULL, embedding_json TEXT NOT NULL,
                confirmed_at TEXT NOT NULL, model_id TEXT NOT NULL,
                dimension INTEGER NOT NULL, source_meeting_id TEXT,
                source_revision INTEGER, source_speaker_id TEXT)""",
            )
            connection.execute(
                """CREATE TABLE IF NOT EXISTS observed_voices (
                meeting_id TEXT NOT NULL, manifest_revision INTEGER NOT NULL,
                speaker_id TEXT NOT NULL, embedding_json TEXT NOT NULL,
                model_id TEXT NOT NULL, dimension INTEGER NOT NULL,
                PRIMARY KEY(meeting_id, manifest_revision, speaker_id))""",
            )
            connection.execute(
                """CREATE TABLE IF NOT EXISTS speaker_refreshes (
                meeting_id TEXT NOT NULL, manifest_revision INTEGER NOT NULL,
                generation INTEGER NOT NULL, attempts INTEGER NOT NULL DEFAULT 0,
                last_error TEXT, requested_at TEXT NOT NULL,
                PRIMARY KEY(meeting_id, manifest_revision))""",
            )
            connection.execute(
                "CREATE TABLE IF NOT EXISTS speaker_matching_rules (version INTEGER NOT NULL)",
            )
            connection.execute(
                """CREATE TABLE IF NOT EXISTS context_names (
                meeting_id TEXT NOT NULL, manifest_revision INTEGER NOT NULL,
                speaker_id TEXT NOT NULL, name TEXT NOT NULL,
                confidence TEXT NOT NULL, evidence TEXT NOT NULL,
                speech_seconds REAL NOT NULL, word_count INTEGER NOT NULL,
                named_at TEXT NOT NULL,
                PRIMARY KEY(meeting_id, manifest_revision, speaker_id))""",
            )
            self._ensure_columns(connection, "voice_profiles", {
                "model_id": "TEXT NOT NULL DEFAULT 'legacy'",
                "dimension": "INTEGER NOT NULL DEFAULT 0",
                "source_meeting_id": "TEXT",
                "source_revision": "INTEGER",
                "source_speaker_id": "TEXT",
                # "confirmed" for a name Mike saved, "context" for a voice
                # enrolled because the conversation and the voice agreed.
                "source": "TEXT NOT NULL DEFAULT 'confirmed'",
            })
            self._ensure_columns(connection, "speaker_refreshes", {"retry_after": "REAL"})
            self._ensure_columns(connection, "observed_voices", {"model_id": "TEXT NOT NULL DEFAULT 'legacy'", "dimension": "INTEGER NOT NULL DEFAULT 0"})
            self._backfill_profile_provenance(connection)
            self._deduplicate_profile_sources(connection)
            connection.execute(
                "CREATE UNIQUE INDEX IF NOT EXISTS voice_profiles_source "
                "ON voice_profiles(source_meeting_id, source_revision, source_speaker_id) "
                "WHERE source_meeting_id IS NOT NULL",
            )
            connection.commit()

    @staticmethod
    def _ensure_columns(connection, table: str, columns: dict[str, str]) -> None:
        existing = {row[1] for row in connection.execute(f"PRAGMA table_info({table})")}
        for name, declaration in columns.items():
            if name not in existing:
                connection.execute(f"ALTER TABLE {table} ADD COLUMN {name} {declaration}")

    @staticmethod
    def _backfill_profile_provenance(connection: sqlite3.Connection) -> None:
        legacy_rows = connection.execute(
            "SELECT rowid, display_name, embedding_json, model_id, dimension "
            "FROM voice_profiles WHERE source_meeting_id IS NULL",
        ).fetchall()
        for rowid, name, embedding_json, model_id, dimension in legacy_rows:
            matches = connection.execute(
                "SELECT DISTINCT observed.meeting_id, observed.manifest_revision, "
                "observed.speaker_id FROM observed_voices AS observed "
                "JOIN speaker_assignments AS assignment ON "
                "assignment.meeting_id=observed.meeting_id AND "
                "assignment.manifest_revision=observed.manifest_revision AND "
                "assignment.speaker_id=observed.speaker_id "
                "WHERE assignment.display_name=? AND observed.embedding_json=? AND "
                "observed.model_id=? AND observed.dimension=?",
                (name, embedding_json, model_id, dimension),
            ).fetchall()
            # An exact row can only prove provenance when it identifies one
            # confirmed observation. Ambiguous legacy rows remain unproven.
            if len(matches) != 1:
                continue
            meeting_id, revision, speaker_id = matches[0]
            existing = connection.execute(
                "SELECT rowid FROM voice_profiles WHERE source_meeting_id=? AND "
                "source_revision=? AND source_speaker_id=? AND rowid<>?",
                (meeting_id, revision, speaker_id, rowid),
            ).fetchone()
            if existing is not None:
                connection.execute("DELETE FROM voice_profiles WHERE rowid=?", (rowid,))
                continue
            connection.execute(
                "UPDATE voice_profiles SET source_meeting_id=?, source_revision=?, "
                "source_speaker_id=? WHERE rowid=?",
                (meeting_id, revision, speaker_id, rowid),
            )

    @staticmethod
    def _deduplicate_profile_sources(connection: sqlite3.Connection) -> None:
        duplicates = connection.execute(
            "SELECT source_meeting_id, source_revision, source_speaker_id "
            "FROM voice_profiles WHERE source_meeting_id IS NOT NULL "
            "GROUP BY source_meeting_id, source_revision, source_speaker_id "
            "HAVING COUNT(*) > 1",
        ).fetchall()
        for source in duplicates:
            rows = connection.execute(
                "SELECT rowid FROM voice_profiles WHERE source_meeting_id=? AND "
                "source_revision=? AND source_speaker_id=? "
                "ORDER BY confirmed_at DESC, rowid DESC",
                source,
            ).fetchall()
            connection.executemany(
                "DELETE FROM voice_profiles WHERE rowid=?",
                rows[1:],
            )

    def identify(self, meeting_id: str, revision: int, speaker_id: str, name: str) -> None:
        if not speaker_id.strip() or not name.strip():
            raise ValueError("speaker_id and name must be nonempty.")
        confirmed = datetime.now(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")
        with closing_connection(lambda: sqlite3.connect(self.database)) as connection:
            connection.execute(
                "INSERT INTO speaker_assignments VALUES (?, ?, ?, ?, ?) "
                "ON CONFLICT(meeting_id,manifest_revision,speaker_id) DO UPDATE SET "
                "display_name=excluded.display_name, confirmed_at=excluded.confirmed_at",
                (meeting_id, revision, speaker_id, name.strip(), confirmed),
            )

    def assignments(self, meeting_id: str, revision: int) -> dict[str, str]:
        with closing_connection(lambda: sqlite3.connect(self.database)) as connection:
            rows = connection.execute(
                "SELECT speaker_id, display_name FROM speaker_assignments "
                "WHERE meeting_id=? AND manifest_revision=? ORDER BY speaker_id",
                (meeting_id, revision),
            ).fetchall()
        return dict(rows)

    def enroll_confirmed(
        self,
        name: str,
        embedding: list[float],
        model_id: str = "test",
        *,
        source_meeting_id: str | None = None,
        source_revision: int | None = None,
        source_speaker_id: str | None = None,
        source: str = "confirmed",
    ) -> None:
        confirmed = datetime.now(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")
        with closing_connection(lambda: sqlite3.connect(self.database)) as connection:
            self._enroll_confirmed_with_connection(
                connection,
                name,
                embedding,
                model_id,
                confirmed,
                source_meeting_id=source_meeting_id,
                source_revision=source_revision,
                source_speaker_id=source_speaker_id,
                source=source,
            )

    @staticmethod
    def _enroll_confirmed_with_connection(
        connection: sqlite3.Connection,
        name: str,
        embedding: list[float],
        model_id: str,
        confirmed: str,
        *,
        source_meeting_id: str | None,
        source_revision: int | None,
        source_speaker_id: str | None,
        source: str = "confirmed",
    ) -> None:
        if not name.strip() or not embedding or not all(math.isfinite(value) for value in embedding):
            raise ValueError("A confirmed profile needs a name and finite embedding.")
        provenance = (source_meeting_id, source_revision, source_speaker_id)
        if any(value is not None for value in provenance) and not (
            isinstance(source_meeting_id, str)
            and source_meeting_id.strip()
            and isinstance(source_revision, int)
            and not isinstance(source_revision, bool)
            and source_revision >= 1
            and isinstance(source_speaker_id, str)
            and source_speaker_id.strip()
        ):
            raise ValueError("Confirmed profile provenance must be complete.")
        values = (
            name.strip(),
            json.dumps(embedding),
            confirmed,
            model_id,
            len(embedding),
            source,
        )
        if source_meeting_id is None:
            connection.execute(
                "INSERT INTO voice_profiles "
                "(display_name,embedding_json,confirmed_at,model_id,dimension,source) "
                "VALUES (?, ?, ?, ?, ?, ?)",
                values,
            )
            return
        updated = connection.execute(
            "UPDATE voice_profiles SET display_name=?, embedding_json=?, "
            "confirmed_at=?, model_id=?, dimension=?, source=? WHERE "
            "source_meeting_id=? AND source_revision=? AND source_speaker_id=?",
            values + (source_meeting_id, source_revision, source_speaker_id),
        )
        if updated.rowcount == 0:
            connection.execute(
                "INSERT INTO voice_profiles "
                "(display_name,embedding_json,confirmed_at,model_id,dimension,source,"
                "source_meeting_id,source_revision,source_speaker_id) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                values + (source_meeting_id, source_revision, source_speaker_id),
            )

    def save_observation(self, meeting_id: str, revision: int, speaker_id: str, embedding: list[float], model_id: str = "test") -> None:
        if not embedding or not all(math.isfinite(value) for value in embedding):
            raise ValueError("An observed voice needs a finite embedding.")
        with closing_connection(lambda: sqlite3.connect(self.database)) as connection:
            connection.execute(
                "INSERT INTO observed_voices VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT "
                "(meeting_id,manifest_revision,speaker_id) DO UPDATE SET embedding_json=excluded.embedding_json, model_id=excluded.model_id, dimension=excluded.dimension",
                (meeting_id, revision, speaker_id, json.dumps(embedding), model_id, len(embedding)),
            )

    def observation(self, meeting_id: str, revision: int, speaker_id: str) -> list[float] | None:
        with closing_connection(lambda: sqlite3.connect(self.database)) as connection:
            row = connection.execute(
                "SELECT embedding_json FROM observed_voices WHERE meeting_id=? AND manifest_revision=? AND speaker_id=?",
                (meeting_id, revision, speaker_id),
            ).fetchone()
        return json.loads(row[0]) if row else None

    def observation_record(self, meeting_id: str, revision: int, speaker_id: str):
        with closing_connection(lambda: sqlite3.connect(self.database)) as connection:
            row = connection.execute(
                "SELECT embedding_json, model_id FROM observed_voices WHERE meeting_id=? AND manifest_revision=? AND speaker_id=?",
                (meeting_id, revision, speaker_id),
            ).fetchone()
        return (json.loads(row[0]), row[1]) if row else None

    def set_context_names(
        self,
        meeting_id: str,
        revision: int,
        names: list[dict],
        speech: dict[str, tuple[float, int]] | None = None,
    ) -> int:
        """Replace the names the conversation gave this meeting's voices.

        `names` are the naming model's entries (speaker, name, confidence,
        evidence). Only high and medium confidence entries with a name are
        kept. `speech` maps a speaker to its seconds of speech and words, which
        decide later whether the voice is worth learning. Returns how many
        were kept.
        """
        self._validate_refresh_identity(meeting_id, revision)
        named_at = datetime.now(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")
        rows = []
        for entry in names:
            speaker = entry.get("speaker")
            name = entry.get("name")
            if (
                not isinstance(speaker, str)
                or not speaker.strip()
                or not isinstance(name, str)
                or not " ".join(name.split())
                or entry.get("confidence") not in CONTEXT_CONFIDENCES
            ):
                continue
            seconds, words = (speech or {}).get(speaker, (0.0, 0))
            evidence = entry.get("evidence")
            rows.append((
                meeting_id, revision, speaker, " ".join(name.split()), entry["confidence"],
                " ".join(evidence.split()) if isinstance(evidence, str) else "",
                float(seconds), int(words), named_at,
            ))
        with closing_connection(
            lambda: sqlite3.connect(self.database, timeout=30, isolation_level=None),
        ) as connection:
            connection.execute("BEGIN IMMEDIATE")
            connection.execute(
                "DELETE FROM context_names WHERE meeting_id=? AND manifest_revision=?",
                (meeting_id, revision),
            )
            connection.executemany(
                "INSERT OR REPLACE INTO context_names (meeting_id,manifest_revision,speaker_id,name,"
                "confidence,evidence,speech_seconds,word_count,named_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                rows,
            )
            connection.commit()
        return len(rows)

    def context_names(self, meeting_id: str, revision: int) -> dict[str, dict]:
        with closing_connection(lambda: sqlite3.connect(self.database)) as connection:
            return self._context_names_from_connection(connection, meeting_id, revision)

    @staticmethod
    def _context_names_from_connection(
        connection: sqlite3.Connection,
        meeting_id: str,
        revision: int,
    ) -> dict[str, dict]:
        """Speaker to {name, confidence, evidence, speech_seconds, word_count}.

        Read on read-only connections too, where the table may not exist yet.
        """
        if connection.execute(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name='context_names'",
        ).fetchone() is None:
            return {}
        rows = connection.execute(
            "SELECT speaker_id, name, confidence, evidence, speech_seconds, word_count "
            "FROM context_names WHERE meeting_id=? AND manifest_revision=? ORDER BY speaker_id",
            (meeting_id, revision),
        ).fetchall()
        return {
            speaker: {
                "name": name, "confidence": confidence, "evidence": evidence,
                "speech_seconds": seconds, "word_count": words,
            }
            for speaker, name, confidence, evidence, seconds, words in rows
        }

    # Learning voices from the conversation

    def learn_from_context(self, meeting_id: str, revision: int) -> list[dict[str, str]]:
        """Enroll voices the conversation named when the voice agrees. Returns what was enrolled.

        The only place a prediction becomes a profile, and only when two
        independent signals agree on a voice the conversation named at high
        confidence:

        - its embedding scores CONTEXT_ENROLL_THRESHOLD or more against an
          enrolled profile of that same name ("matching_profile"); or
        - nobody of that name is enrolled yet, and another meeting's
          conversation gave the same name at high confidence to a voice that
          scores that against this one ("two_meetings"), which enrolls both.

        Never a zero or non-finite embedding, a junk voice (under
        CONTEXT_MINIMUM_SPEECH_SECONDS or CONTEXT_MINIMUM_WORDS), the
        microphone, a voice Mike named, or an automated voice. The profiles
        are marked source "context", so they are easy to list and remove
        (forget_context_profiles). Profiles this meeting taught earlier are
        dropped first, so a changed name doesn't leave the old one behind.
        """
        self._validate_refresh_identity(meeting_id, revision)
        now = datetime.now(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")
        enrolled: list[dict[str, str]] = []
        voices: list[tuple[list[float], str]] = []
        with closing_connection(
            lambda: sqlite3.connect(self.database, timeout=30, isolation_level=None),
        ) as connection:
            connection.execute("BEGIN IMMEDIATE")
            connection.execute(
                "DELETE FROM voice_profiles WHERE source='context' "
                "AND source_meeting_id=? AND source_revision=?",
                (meeting_id, revision),
            )
            for speaker, context in self._context_names_from_connection(connection, meeting_id, revision).items():
                voice = self._context_voice(connection, meeting_id, revision, speaker, context)
                if voice is None:
                    continue
                embedding, model_id = voice
                name = context["name"]
                ranked = self._ranked_names(connection, embedding, model_id, meeting_id)
                same = next((item for item in ranked if item[1].casefold() == name.casefold()), None)
                partner: tuple[str, int, str, list[float]] | None = None
                if same is not None:
                    if same[0] < CONTEXT_ENROLL_THRESHOLD:
                        continue
                    name, rule = same[1], "matching_profile"
                elif self._has_profile(connection, name, model_id, len(embedding), meeting_id):
                    continue
                else:
                    partner = self._context_partner(connection, meeting_id, name, embedding, model_id)
                    if partner is None:
                        continue
                    rule = "two_meetings"
                self._enroll_confirmed_with_connection(
                    connection, name, embedding, model_id, now,
                    source_meeting_id=meeting_id, source_revision=revision,
                    source_speaker_id=speaker, source="context",
                )
                voices.append((embedding, model_id))
                enrolled.append({"speaker": speaker, "name": name, "rule": rule})
                if partner is not None:
                    other_meeting, other_revision, other_speaker, other_embedding = partner
                    self._enroll_confirmed_with_connection(
                        connection, name, other_embedding, model_id, now,
                        source_meeting_id=other_meeting, source_revision=other_revision,
                        source_speaker_id=other_speaker, source="context",
                    )
                    voices.append((other_embedding, model_id))
            # Other meetings with a voice like these can now be named.
            self._request_refresh_for_similar_voices(connection, voices, meeting_id, now)
            connection.commit()
        return enrolled

    @classmethod
    def _context_voice(
        cls,
        connection: sqlite3.Connection,
        meeting_id: str,
        revision: int,
        speaker: str,
        context: dict,
    ) -> tuple[list[float], str] | None:
        """The embedding and model of a voice that may teach a profile, or None."""
        if (
            context["confidence"] != "high"
            or speaker.startswith("microphone:")
            or context["name"].casefold() == "ai"
            or context["speech_seconds"] < CONTEXT_MINIMUM_SPEECH_SECONDS
            or context["word_count"] < CONTEXT_MINIMUM_WORDS
        ):
            return None
        if connection.execute(
            "SELECT 1 FROM speaker_assignments WHERE meeting_id=? AND manifest_revision=? AND speaker_id=?",
            (meeting_id, revision, speaker),
        ).fetchone() is not None:
            return None
        # Whoever enrolled this voice first keeps it: Mike's name is never replaced.
        profile = connection.execute(
            "SELECT source FROM voice_profiles WHERE source_meeting_id=? AND source_revision=? AND source_speaker_id=?",
            (meeting_id, revision, speaker),
        ).fetchone()
        if profile is not None and profile[0] != "context":
            return None
        row = connection.execute(
            "SELECT embedding_json, model_id FROM observed_voices "
            "WHERE meeting_id=? AND manifest_revision=? AND speaker_id=?",
            (meeting_id, revision, speaker),
        ).fetchone()
        embedding = cls._finite_embedding(row[0]) if row else None
        return (embedding, row[1]) if embedding is not None else None

    @staticmethod
    def _has_profile(
        connection: sqlite3.Connection,
        name: str,
        model_id: str,
        dimension: int,
        exclude_meeting_id: str,
    ) -> bool:
        """Whether anyone of this name is enrolled from another meeting, matching or not."""
        rows = connection.execute(
            "SELECT display_name FROM voice_profiles WHERE model_id=? AND dimension=? "
            "AND (source_meeting_id IS NULL OR source_meeting_id<>?)",
            (model_id, dimension, exclude_meeting_id),
        ).fetchall()
        return any(display.casefold() == name.casefold() for (display,) in rows)

    @classmethod
    def _context_partner(
        cls,
        connection: sqlite3.Connection,
        meeting_id: str,
        name: str,
        embedding: list[float],
        model_id: str,
    ) -> tuple[str, int, str, list[float]] | None:
        """The voice in another meeting that the conversation gave this name at
        high confidence and that sounds most like this one, or None."""
        best: tuple[float, tuple[str, int, str, list[float]]] | None = None
        rows = connection.execute(
            "SELECT meeting_id, manifest_revision, speaker_id, name, confidence, evidence, "
            "speech_seconds, word_count FROM context_names WHERE meeting_id<>? ORDER BY meeting_id, "
            "manifest_revision, speaker_id",
            (meeting_id,),
        ).fetchall()
        for other_meeting, other_revision, other_speaker, other_name, confidence, evidence, seconds, words in rows:
            if other_name.casefold() != name.casefold():
                continue
            voice = cls._context_voice(connection, other_meeting, other_revision, other_speaker, {
                "name": other_name, "confidence": confidence, "evidence": evidence,
                "speech_seconds": seconds, "word_count": words,
            })
            if voice is None or voice[1] != model_id or len(voice[0]) != len(embedding):
                continue
            score = cls._cosine(embedding, voice[0])
            if score >= CONTEXT_ENROLL_THRESHOLD and (best is None or score > best[0]):
                best = (score, (other_meeting, other_revision, other_speaker, voice[0]))
        return best[1] if best else None

    def learn_all_from_context(self) -> list[dict[str, str]]:
        """learn_from_context for every meeting with context names, oldest first."""
        with closing_connection(lambda: sqlite3.connect(self.database)) as connection:
            meetings = connection.execute(
                "SELECT meeting_id, manifest_revision FROM context_names "
                "GROUP BY meeting_id, manifest_revision ORDER BY MIN(named_at), meeting_id, manifest_revision",
            ).fetchall()
        results = []
        for meeting_id, revision in meetings:
            for item in self.learn_from_context(meeting_id, revision):
                results.append({"meeting_id": meeting_id, "manifest_revision": revision, **item})
        return results

    def context_profiles(self) -> list[dict]:
        """Every voice profile learned from the conversation."""
        with closing_connection(lambda: sqlite3.connect(self.database)) as connection:
            rows = connection.execute(
                "SELECT display_name, source_meeting_id, source_revision, source_speaker_id, confirmed_at "
                "FROM voice_profiles WHERE source='context' ORDER BY display_name, source_meeting_id, source_speaker_id",
            ).fetchall()
        return [
            {"name": name, "meeting_id": meeting, "manifest_revision": revision, "speaker_id": speaker, "learned_at": at}
            for name, meeting, revision, speaker, at in rows
        ]

    def forget_context_profiles(
        self,
        *,
        name: str | None = None,
        meeting_id: str | None = None,
    ) -> dict[str, int]:
        """Remove voice profiles learned from the conversation (all, or by name or meeting).

        Mike's own profiles are never touched. Every accepted meeting with an
        unnamed voice is then queued for a refresh, so names that rested on
        these profiles go away.
        """
        query = "DELETE FROM voice_profiles WHERE source='context'"
        parameters: list[object] = []
        if meeting_id is not None:
            query += " AND source_meeting_id=?"
            parameters.append(meeting_id)
        requested_at = datetime.now(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")
        with closing_connection(
            lambda: sqlite3.connect(self.database, timeout=30, isolation_level=None),
        ) as connection:
            connection.execute("BEGIN IMMEDIATE")
            if name is not None:
                query += " AND display_name=? COLLATE NOCASE"
                parameters.append(name.strip())
            removed = connection.execute(query, parameters).rowcount
            meetings = sorted({
                (meeting, revision)
                for meeting, revision, _, _ in self._unnamed_accepted_voices(connection)
            }) if removed else []
            for meeting, revision in meetings:
                self._request_refresh_with_connection(connection, meeting, revision, requested_at)
            connection.commit()
        return {"removed": removed, "refreshes_queued": len(meetings)}

    def request_refresh(self, meeting_id: str, revision: int) -> None:
        self._validate_refresh_identity(meeting_id, revision)
        requested_at = datetime.now(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")
        with closing_connection(
            lambda: sqlite3.connect(self.database, timeout=30, isolation_level=None),
        ) as connection:
            connection.execute("BEGIN IMMEDIATE")
            self._request_refresh_with_connection(
                connection,
                meeting_id,
                revision,
                requested_at,
            )
            connection.commit()

    @staticmethod
    def _validate_refresh_identity(meeting_id: str, revision: int) -> None:
        if (
            not isinstance(meeting_id, str)
            or not meeting_id.strip()
            or not isinstance(revision, int)
            or isinstance(revision, bool)
            or revision < 1
        ):
            raise ValueError("A speaker refresh needs a meeting_id and positive revision.")

    @staticmethod
    def _request_refresh_with_connection(
        connection: sqlite3.Connection,
        meeting_id: str,
        revision: int,
        requested_at: str,
    ) -> None:
        connection.execute(
            "INSERT INTO speaker_refreshes "
            "(meeting_id,manifest_revision,generation,attempts,last_error,requested_at) "
            "VALUES (?, ?, 1, 0, NULL, ?) ON CONFLICT(meeting_id,manifest_revision) "
            "DO UPDATE SET generation=speaker_refreshes.generation+1, "
            "last_error=NULL, retry_after=NULL, requested_at=excluded.requested_at",
            (meeting_id, revision, requested_at),
        )

    def confirm_observation(self, meeting_id: str, revision: int, speaker_id: str, name: str) -> bool:
        if not isinstance(speaker_id, str) or not isinstance(name, str):
            raise ValueError("speaker_id and name must be nonempty.")
        return self.confirm_observations(meeting_id, revision, {speaker_id: name})[speaker_id]

    def confirm_observations(self, meeting_id: str, revision: int, names: dict[str, str]) -> dict[str, bool]:
        """Save Mike's names for several speakers of one meeting together.

        Every name is an explicit confirmation, so each saved voice with a
        usable embedding is enrolled as a profile. Nothing is written unless
        all of them are. Returns, per speaker, whether a voice was enrolled.
        """
        self._validate_refresh_identity(meeting_id, revision)
        if not isinstance(names, dict) or not names:
            raise ValueError("Name at least one speaker.")
        cleaned: dict[str, str] = {}
        for speaker_id, name in names.items():
            if (
                not isinstance(speaker_id, str)
                or not speaker_id.strip()
                or not isinstance(name, str)
                or not name.strip()
            ):
                raise ValueError("speaker_id and name must be nonempty.")
            cleaned[speaker_id] = name.strip()
        confirmed = datetime.now(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")
        enrolled: dict[str, bool] = {}
        voices: list[tuple[list[float], str]] = []
        with closing_connection(
            lambda: sqlite3.connect(self.database, timeout=30, isolation_level=None),
        ) as connection:
            connection.execute("BEGIN IMMEDIATE")
            previous = dict(connection.execute(
                "SELECT speaker_id, display_name FROM speaker_assignments "
                "WHERE meeting_id=? AND manifest_revision=?",
                (meeting_id, revision),
            ).fetchall())
            touched = set(cleaned.values()) | {
                previous[speaker_id] for speaker_id in cleaned if speaker_id in previous
            }
            counts_before = self._confirmed_meeting_counts(connection, touched)
            owners_before = self._microphone_owners(connection)
            for speaker_id, name in sorted(cleaned.items()):
                record = connection.execute(
                    "SELECT embedding_json, model_id FROM observed_voices WHERE "
                    "meeting_id=? AND manifest_revision=? AND speaker_id=?",
                    (meeting_id, revision, speaker_id),
                ).fetchone()
                connection.execute(
                    "INSERT INTO speaker_assignments "
                    "(meeting_id,manifest_revision,speaker_id,display_name,confirmed_at) "
                    "VALUES (?, ?, ?, ?, ?) ON CONFLICT(meeting_id,manifest_revision,speaker_id) "
                    "DO UPDATE SET display_name=excluded.display_name, "
                    "confirmed_at=excluded.confirmed_at",
                    (meeting_id, revision, speaker_id, name, confirmed),
                )
                # An older worker could save pyannote's zero padding as a
                # voice. It matches nobody, so only the name is saved.
                embedding = self._finite_embedding(record[0]) if record is not None else None
                if embedding is not None:
                    self._enroll_confirmed_with_connection(
                        connection,
                        name,
                        embedding,
                        record[1],
                        confirmed,
                        source_meeting_id=meeting_id,
                        source_revision=revision,
                        source_speaker_id=speaker_id,
                    )
                    voices.append((embedding, record[1]))
                enrolled[speaker_id] = embedding is not None
            self._request_refresh_with_connection(
                connection,
                meeting_id,
                revision,
                confirmed,
            )
            # Besides voices near the new samples, a save changes names that
            # rest on how many meetings confirmed someone, or on who owns the
            # mic. Those voices sit near that person's other samples.
            counts_after = self._confirmed_meeting_counts(connection, touched)
            people = {
                person for person in counts_before.keys() | counts_after.keys()
                if (counts_before.get(person, 0) >= KNOWN_VOICE_MEETINGS)
                != (counts_after.get(person, 0) >= KNOWN_VOICE_MEETINGS)
            }
            owners_after = self._microphone_owners(connection)
            for model in owners_before.keys() | owners_after.keys():
                if owners_before.get(model) != owners_after.get(model):
                    people.update(
                        (owner, *model)
                        for owner in (owners_before.get(model), owners_after.get(model))
                        if owner is not None
                    )
            self._request_refresh_for_similar_voices(
                connection,
                voices + self._samples_of(connection, people),
                meeting_id,
                confirmed,
            )
            connection.commit()
        return enrolled

    @staticmethod
    def _confirmed_meeting_counts(
        connection: sqlite3.Connection,
        names: set[str],
    ) -> dict[tuple[str, str, int], int]:
        """How many meetings confirmed each name, per embedding model."""
        if not names:
            return {}
        placeholders = ",".join("?" for _ in names)
        rows = connection.execute(
            "SELECT display_name, model_id, dimension, COUNT(DISTINCT source_meeting_id) "
            "FROM voice_profiles WHERE source_meeting_id IS NOT NULL "
            "AND source_revision IS NOT NULL AND source_speaker_id IS NOT NULL "
            f"AND display_name IN ({placeholders}) GROUP BY display_name, model_id, dimension",
            sorted(names),
        ).fetchall()
        return {(name, model_id, dimension): count for name, model_id, dimension, count in rows}

    @classmethod
    def _samples_of(
        cls,
        connection: sqlite3.Connection,
        people: set[tuple[str, str, int]],
    ) -> list[tuple[list[float], str]]:
        samples: list[tuple[list[float], str]] = []
        for name, model_id, dimension in sorted(people):
            for (raw,) in connection.execute(
                "SELECT embedding_json FROM voice_profiles WHERE display_name=? "
                "AND model_id=? AND dimension=? AND source_meeting_id IS NOT NULL",
                (name, model_id, dimension),
            ):
                embedding = cls._finite_embedding(raw)
                if embedding is not None:
                    samples.append((embedding, model_id))
        return samples

    @staticmethod
    def _microphone_owners(
        connection: sqlite3.Connection,
        exclude_meeting_id: str | None = None,
    ) -> dict[tuple[str, int], str | None]:
        """Per embedding model, whoever was confirmed on the microphone in the
        most meetings, or None when two people are tied."""
        query = (
            "SELECT model_id, dimension, display_name, COUNT(DISTINCT source_meeting_id) "
            "FROM voice_profiles WHERE source_meeting_id IS NOT NULL "
            "AND source_revision IS NOT NULL AND source_speaker_id LIKE 'microphone:%'"
        )
        parameters: list[object] = []
        if exclude_meeting_id is not None:
            query += " AND source_meeting_id<>?"
            parameters.append(exclude_meeting_id)
        ranked: dict[tuple[str, int], list[tuple[int, str]]] = {}
        for model_id, dimension, name, meetings in connection.execute(
            query + " GROUP BY model_id, dimension, display_name",
            parameters,
        ):
            ranked.setdefault((model_id, dimension), []).append((meetings, name))
        owners: dict[tuple[str, int], str | None] = {}
        for model, counts in ranked.items():
            counts.sort(key=lambda item: (-item[0], item[1]))
            tied = len(counts) > 1 and counts[1][0] == counts[0][0]
            owners[model] = None if tied else counts[0][1]
        return owners

    @classmethod
    def _request_refresh_for_similar_voices(
        cls,
        connection: sqlite3.Connection,
        voices: list[tuple[list[float], str]],
        exclude_meeting_id: str,
        requested_at: str,
    ) -> None:
        """Refresh other meetings whose unnamed voices these confirmations may now name.

        The service applies the refreshes in the background, so a voice saved
        in one meeting stops being asked about in the others.
        """
        if not voices:
            return
        affected: set[tuple[str, int]] = set()
        for meeting_id, revision, raw, model_id in cls._unnamed_accepted_voices(connection, exclude_meeting_id):
            if (meeting_id, revision) in affected:
                continue
            embedding = cls._finite_embedding(raw)
            if embedding is None:
                continue
            if any(
                voice_model == model_id
                and len(voice) == len(embedding)
                and cls._cosine(voice, embedding) >= REFRESH_SIMILARITY
                for voice, voice_model in voices
            ):
                affected.add((meeting_id, revision))
        for meeting_id, revision in sorted(affected):
            cls._request_refresh_with_connection(connection, meeting_id, revision, requested_at)

    @staticmethod
    def _unnamed_accepted_voices(
        connection: sqlite3.Connection,
        exclude_meeting_id: str | None = None,
    ) -> list[tuple[str, int, str, str]]:
        """Observed voices of accepted meetings that Mike hasn't named."""
        if connection.execute(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name='acceptances'",
        ).fetchone() is None:
            return []
        query = (
            "SELECT observed.meeting_id, observed.manifest_revision, "
            "observed.embedding_json, observed.model_id "
            "FROM observed_voices AS observed "
            "JOIN acceptances AS accepted ON accepted.meeting_id=observed.meeting_id "
            "AND accepted.manifest_revision=observed.manifest_revision "
            "LEFT JOIN speaker_assignments AS assignment ON "
            "assignment.meeting_id=observed.meeting_id AND "
            "assignment.manifest_revision=observed.manifest_revision AND "
            "assignment.speaker_id=observed.speaker_id "
            "WHERE assignment.speaker_id IS NULL"
        )
        parameters: list[object] = []
        if exclude_meeting_id is not None:
            query += " AND observed.meeting_id<>?"
            parameters.append(exclude_meeting_id)
        return connection.execute(query + " ORDER BY 1, 2", parameters).fetchall()

    def request_refresh_after_rule_change(self) -> int:
        """Once per MATCHING_RULES_VERSION, refresh every meeting with an unnamed voice.

        Returns how many meetings were queued. Nothing is enrolled; the
        refresh only rewrites automatic names under the current rules.
        """
        requested_at = datetime.now(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")
        with closing_connection(
            lambda: sqlite3.connect(self.database, timeout=30, isolation_level=None),
        ) as connection:
            connection.execute("BEGIN IMMEDIATE")
            applied = connection.execute("SELECT MAX(version) FROM speaker_matching_rules").fetchone()[0]
            if applied == MATCHING_RULES_VERSION:
                connection.commit()
                return 0
            meetings = sorted({
                (meeting_id, revision)
                for meeting_id, revision, _, _ in self._unnamed_accepted_voices(connection)
            })
            for meeting_id, revision in meetings:
                self._request_refresh_with_connection(connection, meeting_id, revision, requested_at)
            connection.execute("DELETE FROM speaker_matching_rules")
            connection.execute(
                "INSERT INTO speaker_matching_rules (version) VALUES (?)",
                (MATCHING_RULES_VERSION,),
            )
            connection.commit()
        return len(meetings)

    def review_match(
        self,
        embedding: list[float],
        model_id: str = "test",
        exclude_meeting_id: str | None = None,
    ) -> dict[str, str | float | int | None]:
        with closing_connection(lambda: sqlite3.connect(self.database)) as connection:
            return self.review_match_from_connection(
                connection,
                embedding,
                model_id=model_id,
                exclude_meeting_id=exclude_meeting_id,
            )

    @classmethod
    def review_match_from_connection(
        cls,
        connection: sqlite3.Connection,
        embedding: list[float],
        model_id: str = "test",
        exclude_meeting_id: str | None = None,
    ) -> dict[str, str | float | int | None]:
        if (
            not isinstance(embedding, (list, tuple))
            or not embedding
            or any(
                not isinstance(value, (int, float))
                or isinstance(value, bool)
                or not math.isfinite(value)
                for value in embedding
            )
        ):
            raise ValueError("A review match needs a nonempty finite embedding.")
        if not isinstance(model_id, str) or not model_id.strip():
            raise ValueError("A review match needs a nonempty model_id.")
        return cls._match_from_ranking(
            cls._ranked_names(connection, embedding, model_id, exclude_meeting_id),
        )

    @classmethod
    def _ranked_names(
        cls,
        connection: sqlite3.Connection,
        embedding: list[float],
        model_id: str,
        exclude_meeting_id: str | None,
    ) -> list[tuple[float, str, int]]:
        """Each enrolled name's best score, with how many meetings confirmed it."""
        query = (
            "SELECT display_name, embedding_json, source_meeting_id "
            "FROM voice_profiles WHERE model_id=? AND dimension=? "
            "AND source_meeting_id IS NOT NULL AND source_revision IS NOT NULL "
            "AND source_speaker_id IS NOT NULL"
        )
        parameters: list[object] = [model_id, len(embedding)]
        if exclude_meeting_id is not None:
            query += " AND source_meeting_id<>?"
            parameters.append(exclude_meeting_id)
        rows = connection.execute(query, parameters).fetchall()

        by_name: dict[str, dict[str, object]] = {}
        for name, raw, source_meeting_id in rows:
            stored = cls._finite_embedding(raw)
            if stored is None or len(stored) != len(embedding):
                continue
            score = cls._cosine(embedding, stored)
            if not math.isfinite(score):
                continue
            candidate = by_name.setdefault(
                name,
                {"score": -1.0, "meetings": set()},
            )
            candidate["score"] = max(float(candidate["score"]), score)
            candidate["meetings"].add(source_meeting_id)
        return sorted(
            (
                (float(candidate["score"]), name, len(candidate["meetings"]))
                for name, candidate in by_name.items()
            ),
            reverse=True,
        )

    @staticmethod
    def _match_from_ranking(ranked: list[tuple[float, str, int]]) -> dict[str, str | float | int | None]:
        empty = {
            "suggested_name": None,
            "automatic_name": None,
            "suggestion_kind": None,
            "suggestion_score": None,
            "suggestion_margin": None,
            "confirmation_count": 0,
        }
        if not ranked:
            return empty
        score, name, confirmation_count = ranked[0]
        margin = score - ranked[1][0] if len(ranked) > 1 else None
        result = {
            **empty,
            "suggestion_score": score,
            "suggestion_margin": margin,
            "confirmation_count": confirmation_count,
        }
        kind = classify_match(score, margin, confirmation_count)
        if kind == "automatic":
            result.update({
                "suggested_name": name,
                "automatic_name": name,
                "suggestion_kind": "strong",
            })
        elif kind == "tentative":
            result.update({
                "suggested_name": name,
                "suggestion_kind": "tentative",
            })
        return result

    def meeting_matches(
        self,
        meeting_id: str,
        revision: int,
        speaker_ids: list[str],
    ) -> dict[str, dict[str, str | float | int | None]]:
        with closing_connection(lambda: sqlite3.connect(self.database)) as connection:
            return self.meeting_matches_from_connection(connection, meeting_id, revision, speaker_ids)

    @classmethod
    def meeting_matches_from_connection(
        cls,
        connection: sqlite3.Connection,
        meeting_id: str,
        revision: int,
        speaker_ids: list[str],
        *,
        targets: list[str] | None = None,
    ) -> dict[str, dict[str, str | float | int | None]]:
        """Suggestions and automatic names for one meeting's speakers.

        Only reads, so it is safe on a read-only connection. A speaker Mike
        has not named can be named automatically four ways: its voice matches
        someone confirmed in other meetings; it is the only voice on the
        microphone and sounds like the microphone's usual owner; or it sounds
        like a voice Mike saved in this meeting, which pyannote split off. When
        those disagree it is only a suggestion. The fourth is the name the
        conversation gave it (context_names), used only when none of those
        three named it. A speaker he has named gets no other name. Nothing
        here is ever enrolled.
        """
        speakers = sorted(set(speaker_ids))
        assignments = dict(connection.execute(
            "SELECT speaker_id, display_name FROM speaker_assignments "
            "WHERE meeting_id=? AND manifest_revision=?",
            (meeting_id, revision),
        ).fetchall())
        contexts = cls._context_names_from_connection(connection, meeting_id, revision)
        records: dict[str, tuple[list[float], str]] = {}
        for speaker in sorted(set(speakers) | set(assignments)):
            row = connection.execute(
                "SELECT embedding_json, model_id FROM observed_voices "
                "WHERE meeting_id=? AND manifest_revision=? AND speaker_id=?",
                (meeting_id, revision, speaker),
            ).fetchone()
            embedding = cls._finite_embedding(row[0]) if row else None
            if embedding is not None:
                records[speaker] = (embedding, row[1])
        microphones = [speaker for speaker in speakers if speaker.startswith("microphone:")]
        result: dict[str, dict[str, str | float | int | None]] = {}
        for speaker in sorted(set(targets)) if targets is not None else speakers:
            if speaker not in records:
                # A voice with no usable embedding (a few seconds of speech)
                # can still be named from the conversation.
                if speaker in contexts and speaker not in assignments:
                    result[speaker] = cls._with_context(cls._match_from_ranking([]), contexts[speaker])
                continue
            embedding, model_id = records[speaker]
            ranked = cls._ranked_names(connection, embedding, model_id, meeting_id)
            match = cls._match_from_ranking(ranked)
            if speaker in assignments:
                # Mike's saved name wins. Any other name would only contradict it.
                match.update(suggested_name=None, automatic_name=None, suggestion_kind=None)
            else:
                # Each candidate is (score, kind, name).
                candidates: list[tuple[float, str, str]] = []
                sibling = cls._same_meeting_name(speaker, records, assignments)
                if sibling is not None:
                    candidates.append((sibling[0], "same_meeting", sibling[1]))
                if match["automatic_name"]:
                    candidates.append((ranked[0][0], "strong", str(match["automatic_name"])))
                if microphones == [speaker] and cls._sounds_like_microphone_owner(
                    connection, ranked, model_id, len(embedding), meeting_id,
                ):
                    candidates.append((ranked[0][0], "own_microphone", ranked[0][1]))
                if candidates:
                    _, kind, name = candidates[0]
                    if len({candidate for _, _, candidate in candidates}) == 1:
                        match.update(suggested_name=name, automatic_name=name, suggestion_kind=kind)
                    else:
                        # Suggest whichever name has the closest voice.
                        _, _, name = max(candidates, key=lambda candidate: candidate[0])
                        match.update(suggested_name=name, automatic_name=None, suggestion_kind="tentative")
                if speaker in contexts:
                    match = cls._with_context(match, contexts[speaker])
            result[speaker] = match
        return result

    @staticmethod
    def _with_context(match: dict, context: dict) -> dict:
        """Add the name the conversation gave this voice.

        It becomes the automatic name only when no voice match named the
        voice: a name from the voice wins a disagreement, and a name Mike
        saved wins over both (those voices never get here).
        """
        match = dict(match)
        match.update(
            context_name=context["name"],
            context_confidence=context["confidence"],
            context_evidence=context["evidence"],
        )
        if not match.get("automatic_name"):
            match.update(
                suggested_name=context["name"],
                automatic_name=context["name"],
                suggestion_kind="context",
            )
        return match

    @classmethod
    def _same_meeting_name(
        cls,
        speaker: str,
        records: dict[str, tuple[list[float], str]],
        assignments: dict[str, str],
    ) -> tuple[float, str] | None:
        """The name Mike saved for a voice in this meeting that this one
        matches, with its score."""
        embedding, model_id = records[speaker]
        by_name: dict[str, float] = {}
        for other, name in assignments.items():
            if other == speaker or other not in records:
                continue
            other_embedding, other_model = records[other]
            if other_model != model_id or len(other_embedding) != len(embedding):
                continue
            by_name[name] = max(by_name.get(name, -1.0), cls._cosine(embedding, other_embedding))
        ranked = sorted(((score, name) for name, score in by_name.items()), reverse=True)
        if not ranked or ranked[0][0] < SAME_VOICE_THRESHOLD:
            return None
        if len(ranked) > 1 and ranked[0][0] - ranked[1][0] < MATCH_MARGIN:
            return None
        return ranked[0]

    @classmethod
    def _sounds_like_microphone_owner(
        cls,
        connection: sqlite3.Connection,
        ranked: list[tuple[float, str, int]],
        model_id: str,
        dimension: int,
        exclude_meeting_id: str,
    ) -> bool:
        """Whether the best match is the person the microphone usually carries.

        The owner is whoever Mike confirmed on the microphone in the most
        meetings: him, once he has named his own voice once.
        """
        if not ranked:
            return False
        score, name, _ = ranked[0]
        margin = score - ranked[1][0] if len(ranked) > 1 else None
        if score < OWN_MICROPHONE_THRESHOLD or (margin is not None and margin < MATCH_MARGIN):
            return False
        owner = cls._microphone_owners(connection, exclude_meeting_id).get((model_id, dimension))
        return owner is not None and owner == name

    def ranked_suggestions(self, embedding: list[float], model_id: str = "test") -> list[tuple[float, str]]:
        with closing_connection(lambda: sqlite3.connect(self.database)) as connection:
            rows = connection.execute(
                "SELECT display_name, embedding_json FROM voice_profiles WHERE model_id=? AND dimension=?",
                (model_id, len(embedding)),
            ).fetchall()
        by_name: dict[str, float] = {}
        for name, raw in rows:
            by_name[name] = max(by_name.get(name, -1.0), self._cosine(embedding, json.loads(raw)))
        return sorted(
            ((score, name) for name, score in by_name.items()),
            reverse=True,
        )

    def suggest(
        self,
        embedding: list[float],
        threshold: float = STRONG_MATCH_THRESHOLD,
        margin: float = MATCH_MARGIN,
        model_id: str = "test",
    ) -> str | None:
        scores = self.ranked_suggestions(embedding, model_id)
        if not scores or scores[0][0] < threshold:
            return None
        runner_up = scores[1][0] if len(scores) > 1 else -1.0
        return scores[0][1] if scores[0][0] - runner_up >= margin else None

    @staticmethod
    def _finite_embedding(raw: object) -> list[float] | None:
        """A stored embedding as floats, or None when it is unreadable or all
        zeros, which is how pyannote pads a voice it could not cluster."""
        try:
            values = json.loads(raw)
        except (TypeError, json.JSONDecodeError):
            return None
        if (
            not isinstance(values, list)
            or not values
            or any(
                not isinstance(value, (int, float))
                or isinstance(value, bool)
                or not math.isfinite(value)
                for value in values
            )
            or not any(values)
        ):
            return None
        return [float(value) for value in values]

    @staticmethod
    def _cosine(left: list[float], right: list[float]) -> float:
        if len(left) != len(right) or not left:
            return -1.0
        left_norm = math.sqrt(sum(value * value for value in left))
        right_norm = math.sqrt(sum(value * value for value in right))
        if left_norm == 0 or right_norm == 0:
            return -1.0
        return sum(a * b for a, b in zip(left, right)) / (left_norm * right_norm)
