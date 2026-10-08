"""Noninteractive JSON CLI for transfer clients and the Bruce worker service."""

from __future__ import annotations

import argparse
import importlib
import json
import sqlite3
import socket
import stat
import sys
import threading
import uuid
import os
from collections.abc import Callable
from pathlib import Path
from typing import Any

from .archive import ArchiveConflict, ArchiveStore
from .db import closing_connection
from .manifest import ManifestError, verify_incoming
from .media_validation import MediaValidationError
from .model_processor import _write_transcript_artifacts
from .queue import Job, JobQueue, QueueConflict
from .speakers import SpeakerRegistry
from .speaker_evidence import automatic_names, refresh_speaker_matches


class PermanentProcessingError(RuntimeError):
    """An adapter can raise this to make a failed job visible without retrying."""


def _print_json(value: Any, *, stream=None) -> None:
    print(
        json.dumps(value, sort_keys=True, separators=(",", ":")),
        file=stream or sys.stdout,
    )


def _verified_json(incoming: Path) -> dict[str, Any]:
    verified = verify_incoming(incoming)
    return {
        "schema_version": 1,
        "meeting_id": verified.meeting_id,
        "manifest_revision": verified.revision,
        "manifest_sha256": verified.manifest_sha256,
        "verified_files": [
            {
                "path": item.path,
                "size_bytes": item.size_bytes,
                "sha256": item.sha256,
                "kind": item.kind,
            }
            for item in verified.files
        ],
    }


def _load_processor(specification: str) -> Callable[[Path, Job], None]:
    if ":" not in specification:
        raise ValueError("--processor must use module:function syntax.")
    module_name, function_name = specification.rsplit(":", 1)
    processor = getattr(importlib.import_module(module_name), function_name)
    if not callable(processor):
        raise ValueError(f"{specification} is not callable.")
    return processor


def _calendar_candidates(metadata: dict[str, Any]) -> list[dict[str, str | None]]:
    from .summaries import matched_event_attendees

    result = []
    for raw in matched_event_attendees(metadata):
        if isinstance(raw, str) and raw.strip():
            result.append({"name": raw.strip(), "email": None, "response_status": None, "source": None})
        elif isinstance(raw, dict) and isinstance(raw.get("name"), str) and raw["name"].strip():
            # The app calls it "response": EKParticipantStatus's raw value.
            response = raw.get("response", raw.get("response_status"))
            result.append({
                "name": raw["name"].strip(),
                "email": raw.get("email") if isinstance(raw.get("email"), str) else None,
                "response_status": response if isinstance(response, str) else None,
                "source": raw.get("source") if isinstance(raw.get("source"), str) else None,
            })
    return result


def _excerpt_turns(turns: list[dict[str, Any]], speaker: str, limit: int = 3) -> list[dict[str, Any]]:
    """The speaker's wordiest lines, in the order they were said.

    The first lines are often "Yeah" or "Hi" said over someone else, and the
    playback mixes both tracks, so they mostly play the other person.
    """
    spoken = [turn for turn in turns if turn.get("speaker") == speaker]
    wordiest = sorted(
        enumerate(spoken),
        key=lambda item: (-len(str(item[1].get("text", "")).split()), item[0]),
    )[:limit]
    return [turn for _, turn in sorted(wordiest, key=lambda item: item[0])]


#: Seconds a voice must speak before the menu asks Mike to name it.
MINIMUM_SPEECH_TO_ASK_SECONDS = 15.0


def _speaker_counts_for_status(
    job: dict[str, Any],
    database: Path,
) -> tuple[int, int] | None:
    """Read canonical speaker-review state without creating files or DB rows."""
    if job.get("state") != "succeeded":
        return None
    transcript_path = (
        Path(job["archive_path"])
        / "transcripts"
        / f"v{job['manifest_revision']}"
        / "transcript.json"
    )
    try:
        transcript_stat = transcript_path.lstat()
        if (
            not stat.S_ISREG(transcript_stat.st_mode)
            or transcript_stat.st_size > 16 * 1024 * 1024
        ):
            return None
        transcript = json.loads(transcript_path.read_text(encoding="utf-8"))
    except (FileNotFoundError, OSError, UnicodeDecodeError, json.JSONDecodeError):
        return None
    if (
        not isinstance(transcript, dict)
        or transcript.get("schema_version") != 1
        or transcript.get("meeting_id") != job["meeting_id"]
        or transcript.get("manifest_revision") != job["manifest_revision"]
        or not isinstance(transcript.get("processing"), dict)
        or transcript["processing"].get("manifest_sha256") != job["manifest_sha256"]
        or not isinstance(transcript.get("turns"), list)
    ):
        return None
    speaker_ids: set[str] = set()
    for turn in transcript["turns"]:
        if not isinstance(turn, dict):
            return None
        speaker_id = turn.get("speaker")
        if speaker_id is None:
            continue
        if not isinstance(speaker_id, str) or not speaker_id.strip():
            return None
        speaker_ids.add(speaker_id)
    try:
        database_uri = database.resolve().as_uri() + "?mode=ro"
        with closing_connection(
            lambda: sqlite3.connect(database_uri, uri=True),
        ) as connection:
            assignments = dict(connection.execute(
                    "SELECT speaker_id, display_name FROM speaker_assignments "
                    "WHERE meeting_id=? AND manifest_revision=?",
                    (job["meeting_id"], job["manifest_revision"]),
                ))
            confirmed_ids = {
                speaker for speaker, name in assignments.items()
                if all(turn.get("name") == name and turn.get("name_source") == "confirmed"
                       for turn in transcript["turns"] if turn.get("speaker") == speaker)
            }
            # A name appearing in text alone is not evidence of a completed
            # review. Require a persisted automatic name and recheck it against
            # the confirmed voices without enrolling or migrating anything here.
            automatic = automatic_names(transcript)
            if automatic:
                matches = SpeakerRegistry.meeting_matches_from_connection(
                    connection,
                    job["meeting_id"],
                    job["manifest_revision"],
                    sorted(speaker_ids),
                    targets=sorted(automatic),
                )
                confirmed_ids.update(
                    speaker for speaker, name in automatic.items()
                    if matches.get(speaker, {}).get("automatic_name") == name
                )
    except (OSError, sqlite3.Error, ValueError, TypeError):
        return None
    # A voice heard for a few seconds is rarely worth asking about, so it
    # doesn't count towards the menu's "needs a name". Review still lists it.
    # A voice whose length can't be told is still asked about.
    speech: dict[str, float] = {}
    for turn in transcript["turns"]:
        speaker_id = turn.get("speaker")
        if speaker_id is None:
            continue
        try:
            speech[speaker_id] = speech.get(speaker_id, 0.0) + max(0.0, float(turn["end"]) - float(turn["start"]))
        except (KeyError, TypeError, ValueError):
            speech[speaker_id] = float("inf")
    waiting = {speaker for speaker in speaker_ids - confirmed_ids if speech.get(speaker, 0.0) >= MINIMUM_SPEECH_TO_ASK_SECONDS}
    return len(speaker_ids), len(waiting)


def _add_speaker_counts_to_status(status: dict[str, Any], database: Path) -> None:
    for job in status["jobs"]:
        counts = _speaker_counts_for_status(job, database)
        if counts is not None:
            job["total_speaker_count"], job["unconfirmed_speaker_count"] = counts


def _add_titles_to_status(status: dict[str, Any]) -> None:
    """The title Notion and search show, so the app can follow AI titles and renames."""
    from .titles import display_title

    for job in status["jobs"]:
        archive = Path(job["archive_path"])
        title = display_title(archive) if archive.is_absolute() else None
        if title is not None:
            job["title"] = title


class _Heartbeat:
    def __init__(self, queue: JobQueue, job: Job, lease_seconds: float):
        self.queue = queue
        self.job = job
        self.lease_seconds = lease_seconds
        self.stop = threading.Event()
        self.error: BaseException | None = None
        self.thread = threading.Thread(target=self._run, name="meeting-archive-lease", daemon=True)

    def __enter__(self) -> "_Heartbeat":
        self.thread.start()
        return self

    def __exit__(self, *_: object) -> None:
        self.stop.set()
        self.thread.join()

    def _run(self) -> None:
        interval = max(0.05, self.lease_seconds / 3)
        while not self.stop.wait(interval):
            try:
                self.queue.renew(self.job, self.lease_seconds)
            except BaseException as error:
                self.error = error
                self.stop.set()
                return


def _process_ready(args: argparse.Namespace) -> int:
    queue = JobQueue(args.db)
    owner = args.worker_id or f"{socket.gethostname()}:{uuid.uuid4()}"
    job = queue.claim_ready(owner, args.lease_seconds)
    if job is None:
        _print_json({"schema_version": 1, "processed": False, "reason": "no_ready_job"})
        return 0
    try:
        processor = _load_processor(args.processor)
        archive_directory = Path(job.archive_path)
        if not archive_directory.is_absolute():
            archive_directory = Path(args.archive_root) / archive_directory
        with _Heartbeat(queue, job, args.lease_seconds) as heartbeat:
            os.environ["MEETING_ARCHIVE_WORKER_DB"] = str(args.db)
            processor(archive_directory, job)
        if heartbeat.error is not None:
            raise QueueConflict(f"Lost the job lease during processing: {heartbeat.error}")
        queue.complete(job)
    except PermanentProcessingError as error:
        queue.fail(job, str(error), transient=False)
        _print_json(
            {"schema_version": 1, "processed": False, "job_id": job.id, "error": str(error)},
            stream=sys.stderr,
        )
        return 1
    except Exception as error:
        try:
            retry_at = queue.fail(
                job,
                str(error),
                transient=True,
                base_delay_seconds=args.retry_base_seconds,
            )
        except QueueConflict:
            retry_at = None
        _print_json(
            {
                "schema_version": 1,
                "processed": False,
                "job_id": job.id,
                "error": str(error),
                "retry_at": retry_at,
            },
            stream=sys.stderr,
        )
        return 1
    _print_json(
        {
            "schema_version": 1,
            "processed": True,
            "job_id": job.id,
            "meeting_id": job.meeting_id,
        },
    )
    return 0


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(prog="meeting-archive-worker")
    commands = result.add_subparsers(dest="command", required=True)

    verify = commands.add_parser("verify", help="verify an incoming finalized bundle")
    verify.add_argument("incoming", type=Path)

    accept = commands.add_parser("accept", help="accept and durably queue a verified bundle")
    accept.add_argument("incoming", type=Path, nargs="?")
    accept.add_argument("--incoming", dest="incoming_option", type=Path)
    accept.add_argument("--manifest-sha256")
    accept.add_argument("--archive-root", type=Path, required=True)
    accept.add_argument("--db", type=Path, required=True)
    accept.add_argument(
        "--incoming-root",
        type=Path,
        help="staging root whose <meeting>/r<revision> copy is removed after acceptance "
        "(default: incoming beside the archive root)",
    )
    accept.add_argument(
        "--validate-media",
        action="store_true",
        help="ffprobe and fully decode finalized media before allowing cleanup",
    )

    status = commands.add_parser("status", help="print durable queue state")
    status.add_argument("--db", type=Path, required=True)
    status.add_argument(
        "--meeting-id",
        action="append",
        default=[],
        help="limit output to a meeting UUID; repeat up to 100 times",
    )

    name_speakers = commands.add_parser(
        "name-speakers",
        help="queue naming of voices from the conversation for some or all meetings",
    )
    name_speakers.add_argument(
        "--meeting-id",
        action="append",
        default=[],
        help="a meeting UUID; repeat up to 100 times. Without any, every processed meeting",
    )
    name_speakers.add_argument("--db", type=Path, required=True)

    context_voices = commands.add_parser(
        "context-voices",
        help="list the voice profiles learned from the conversation",
    )
    context_voices.add_argument("--db", type=Path, required=True)
    learn_context = commands.add_parser(
        "learn-context-voices",
        help="learn voices from every meeting's conversation names again",
    )
    learn_context.add_argument("--db", type=Path, required=True)
    forget_context = commands.add_parser(
        "forget-context-voices",
        help="remove voice profiles learned from the conversation, never the ones Mike saved",
    )
    forget_context.add_argument("--name", help="only profiles of this name")
    forget_context.add_argument("--meeting-id", help="only profiles learned from this meeting")
    forget_context.add_argument("--db", type=Path, required=True)

    retry = commands.add_parser("retry", help="release failed processing or publication work")
    retry.add_argument("--meeting-id", required=True)
    retry.add_argument("--db", type=Path, required=True)

    process = commands.add_parser("process-ready", help="process at most one ready heavy job")
    process.add_argument("--archive-root", type=Path, required=True)
    process.add_argument("--db", type=Path, required=True)
    process.add_argument("--processor", required=True, help="Python module:function adapter")
    process.add_argument("--worker-id")
    process.add_argument("--lease-seconds", type=float, default=900)
    process.add_argument("--retry-base-seconds", type=float, default=60)
    review = commands.add_parser("review-speakers")
    review.add_argument("--archive-dir", type=Path, required=True)
    review.add_argument("--revision", type=int, required=True)
    review.add_argument("--db", type=Path, required=True)
    identify = commands.add_parser("identify")
    identify.add_argument("--meeting-id", required=True)
    identify.add_argument("--revision", type=int, required=True)
    identify.add_argument("--speaker-id", required=True)
    identify.add_argument("--name", required=True)
    identify.add_argument("--db", type=Path, required=True)
    identify_speakers = commands.add_parser(
        "identify-speakers",
        help="save names for several speakers of one meeting together",
    )
    identify_speakers.add_argument("--meeting-id", required=True)
    identify_speakers.add_argument("--revision", type=int, required=True)
    identify_speakers.add_argument(
        "--names",
        required=True,
        help='JSON object of speaker ID to name, like {"incoming:SPEAKER_00": "Micah"}',
    )
    identify_speakers.add_argument("--db", type=Path, required=True)
    locate = commands.add_parser("locate")
    locate.add_argument("--meeting-id", required=True)
    locate.add_argument("--archive-root", type=Path, required=True)
    locate.add_argument("--db", type=Path, required=True)
    rename = commands.add_parser("rename", help="set a meeting's display title")
    rename.add_argument("--meeting-id", required=True)
    rename.add_argument("--title", required=True)
    rename.add_argument("--archive-root", type=Path, required=True)
    rename.add_argument("--db", type=Path, required=True)
    search = commands.add_parser("search", help="search transcripts of accepted meetings")
    search.add_argument("--query", required=True)
    search.add_argument("--archive-root", type=Path, required=True)
    search.add_argument("--db", type=Path, required=True)
    search.add_argument("--limit", type=int, default=20, help="maximum meetings returned (1-100)")
    return result


def _accepted_archive_path(database: Path, archive_root: Path, meeting_id: str) -> Path:
    acknowledgement = JobQueue(database).acceptance(meeting_id)
    if acknowledgement is None:
        raise ValueError(f"Meeting {meeting_id} is not accepted in this archive.")
    path = Path(acknowledgement["archive_path"])
    if not path.is_absolute():
        path = archive_root / path
    return path


#: More speakers than any meeting has, so a bad request can't grow unbounded.
MAXIMUM_NAMES_PER_SAVE = 100


def _names_argument(raw: str) -> dict[str, str]:
    try:
        names = json.loads(raw)
    except json.JSONDecodeError as error:
        raise ValueError(f"--names must be a JSON object: {error}") from error
    if not isinstance(names, dict) or not names or len(names) > MAXIMUM_NAMES_PER_SAVE:
        raise ValueError(f"--names must name between 1 and {MAXIMUM_NAMES_PER_SAVE} speakers.")
    if not all(isinstance(value, str) for value in names.values()):
        raise ValueError("Every name in --names must be a string.")
    return names


def _save_names(database: Path, meeting_id: str, revision: int, names: dict[str, str]) -> dict[str, bool]:
    """Confirm names together, then bring this meeting's transcript up to date."""
    from .speaker_refresh import reconcile_speaker_refresh

    enrolled = SpeakerRegistry(database).confirm_observations(meeting_id, revision, names)
    acknowledgement = JobQueue(database).acceptance(meeting_id)
    refreshed = reconcile_speaker_refresh(database, meeting_id, revision)
    if acknowledgement and not refreshed:
        raise ValueError(
            ("The names are" if len(names) > 1 else "The name is")
            + " saved. Updating the transcript is queued for retry on Bruce.",
        )
    return enrolled


def _name_speakers(args: argparse.Namespace) -> dict[str, Any]:
    """Ask for voices to be named from the conversation, for the service to do.

    A meeting whose transcript hasn't changed since it was named costs
    nothing: the request is recognised and only re-applies the saved names.
    """
    from .naming import NamingQueue

    if len(args.meeting_id) > 100:
        raise ValueError("name-speakers accepts at most 100 --meeting-id values.")
    meeting_ids = {str(uuid.UUID(value)).lower() for value in args.meeting_id} or None
    jobs = [job for job in JobQueue(args.db).status(meeting_ids)["jobs"] if job["state"] == "succeeded"]
    queue = NamingQueue(args.db)
    queue.reconcile(jobs)
    # Only the newest revision of each meeting.
    latest: dict[str, dict[str, Any]] = {}
    for job in jobs:
        current = latest.get(job["meeting_id"])
        if current is None or (job["manifest_revision"], job["id"]) > (current["manifest_revision"], current["id"]):
            latest[job["meeting_id"]] = job
    for job in latest.values():
        queue.request(int(job["id"]), job["archive_path"])
    return {
        "schema_version": 1,
        "queued": [
            {"meeting_id": job["meeting_id"], "manifest_revision": job["manifest_revision"]}
            for job in sorted(latest.values(), key=lambda job: int(job["id"]))
        ],
    }


def _rename(args: argparse.Namespace) -> int:
    from .service import PublicationQueue
    from .titles import normalize_title, write_title

    meeting_id = str(uuid.UUID(args.meeting_id)).lower()
    title = normalize_title(args.title)
    archive = _accepted_archive_path(args.db, args.archive_root, meeting_id)
    write_title(archive, title)
    # Republish like a speaker correction does. Queue even when the title was
    # already saved, so a retry after a crash here still reaches Notion; an
    # unchanged page short-circuits on its content fingerprint. Meetings not
    # yet processed publish later and read the new title then.
    succeeded = [
        job for job in JobQueue(args.db).status({meeting_id})["jobs"]
        if job["state"] == "succeeded"
    ]
    if succeeded:
        latest = max(succeeded, key=lambda job: (job["manifest_revision"], job["id"]))
        job_archive = Path(latest["archive_path"])
        if not job_archive.is_absolute():
            job_archive = args.archive_root / job_archive
        PublicationQueue(args.db).refresh(int(latest["id"]), str(job_archive))
    _print_json({"schema_version": 1, "meeting_id": meeting_id, "title": title})
    return 0


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        if args.command == "verify":
            _print_json(_verified_json(args.incoming))
            return 0
        if args.command == "accept":
            incoming = args.incoming_option or args.incoming
            if incoming is None:
                raise ValueError("accept requires INCOMING or --incoming INCOMING.")
            if args.incoming_option is not None and args.incoming is not None:
                raise ValueError("Pass the incoming directory once.")
            acknowledgement = ArchiveStore(
                args.archive_root,
                args.db,
                validate_media=args.validate_media,
                # Bruce keeps MeetingArchive/incoming beside MeetingArchive/meetings.
                incoming_root=args.incoming_root or Path(os.path.abspath(args.archive_root)).parent / "incoming",
            ).accept(
                incoming,
                expected_manifest_sha256=args.manifest_sha256,
            )
            _print_json(acknowledgement)
            return 0
        if args.command == "status":
            if len(args.meeting_id) > 100:
                raise ValueError("status accepts at most 100 --meeting-id values.")
            meeting_ids = {
                str(uuid.UUID(value)).lower()
                for value in args.meeting_id
            } if args.meeting_id else None
            status = JobQueue(args.db).status(meeting_ids)
            _add_speaker_counts_to_status(status, Path(args.db))
            _add_titles_to_status(status)
            from .naming import NamingQueue
            from .service import PublicationQueue
            from .summaries import SummaryQueue

            processing_job_ids = {int(job["id"]) for job in status["jobs"]}
            scope = processing_job_ids if meeting_ids is not None else None
            status["publication"] = PublicationQueue(args.db).status(scope)
            status["naming"] = NamingQueue(args.db).status(scope)
            status["summary"] = SummaryQueue(args.db).status(scope)
            _print_json(status)
            return 0
        if args.command == "retry":
            meeting_id = str(uuid.UUID(args.meeting_id)).lower()
            processing = JobQueue(args.db).retry_failed(meeting_id)
            publication = None
            naming = None
            summary = None
            if processing["state"] == "succeeded":
                from .naming import NamingQueue
                from .service import PublicationQueue
                from .summaries import SummaryQueue

                publication = PublicationQueue(args.db).retry_failed(processing["job_id"])
                naming = NamingQueue(args.db).retry_failed(processing["job_id"])
                summary = SummaryQueue(args.db).retry_failed(processing["job_id"])
            _print_json({
                "schema_version": 1,
                "meeting_id": meeting_id,
                "retried": processing["retried"]
                or bool(publication and publication["retried"])
                or bool(naming and naming["retried"])
                or bool(summary and summary["retried"]),
                "processing": processing,
                "publication": publication,
                "naming": naming,
                "summary": summary,
            })
            return 0
        if args.command == "process-ready":
            return _process_ready(args)
        if args.command == "review-speakers":
            from .speaker_refresh import speaker_archive_lock, reconcile_speaker_refresh

            registry = SpeakerRegistry(args.db)
            with speaker_archive_lock(args.archive_dir, args.revision):
                transcript = json.loads((args.archive_dir / "transcripts" / f"v{args.revision}" / "transcript.json").read_text(encoding="utf-8"))
                if transcript.get("manifest_revision") != args.revision:
                    raise ValueError("Transcript revision does not match the review request.")
                assignments = registry.assignments(transcript["meeting_id"], args.revision)
                before = json.dumps(transcript, sort_keys=True)
                refresh_speaker_matches(transcript, registry)
                if json.dumps(transcript, sort_keys=True) != before:
                    # Record the retry first, so a crash during derived writes
                    # or publication scheduling cannot lose this correction.
                    registry.request_refresh(transcript["meeting_id"], args.revision)
                    _write_transcript_artifacts(args.archive_dir / "transcripts" / f"v{args.revision}", transcript)
            reconcile_speaker_refresh(args.db, transcript["meeting_id"], args.revision)
            speaker_ids = sorted({turn["speaker"] for turn in transcript["turns"] if "speaker" in turn})
            metadata = json.loads((args.archive_dir / "metadata.json").read_text(encoding="utf-8"))
            speakers = []
            playback = args.archive_dir / "playback" / "meeting.mp4"
            playback_path = str(playback) if playback.is_file() else None
            for value in speaker_ids:
                observation = registry.observation_record(transcript["meeting_id"], args.revision, value)
                match = transcript["speaker_matches"].get(value, {})
                excerpts = [
                    {
                        **{key: turn[key] for key in ("start", "end", "text", "channel_origin")},
                        "playback_path": playback_path,
                    }
                    for turn in _excerpt_turns(transcript["turns"], value)
                ]
                speakers.append({
                    "speaker_id": value, "name": assignments.get(value),
                    "suggested_name": match.get("suggested_name"),
                    "automatic_name": match.get("automatic_name"),
                    "suggestion_kind": match.get("suggestion_kind"),
                    "suggestion_score": match.get("suggestion_score"),
                    "suggestion_margin": match.get("suggestion_margin"),
                    "confirmation_count": match.get("confirmation_count", 0),
                    # What the conversation called this voice, if it did.
                    "context_name": match.get("context_name"),
                    "context_confidence": match.get("context_confidence"),
                    "context_evidence": match.get("context_evidence"),
                    "embedding_available": observation is not None, "excerpts": excerpts,
                    # Names are no longer read from video frames. The app still
                    # decodes this field, so it stays as an empty list.
                    "evidence_labels": [],
                })
            _print_json({"schema_version": 1, "meeting_id": transcript["meeting_id"], "manifest_revision": args.revision, "speakers": speakers, "calendar_candidates": _calendar_candidates(metadata)})
            return 0
        if args.command == "identify":
            enrolled = _save_names(args.db, args.meeting_id, args.revision, {args.speaker_id: args.name})
            _print_json({"schema_version": 1, "confirmed": True, "meeting_id": args.meeting_id, "manifest_revision": args.revision, "speaker_id": args.speaker_id, "name": args.name, "voice_profile_enrolled": enrolled[args.speaker_id]})
            return 0
        if args.command == "identify-speakers":
            names = _names_argument(args.names)
            enrolled = _save_names(args.db, args.meeting_id, args.revision, names)
            _print_json({
                "schema_version": 1,
                "meeting_id": args.meeting_id,
                "manifest_revision": args.revision,
                "speakers": [
                    {"speaker_id": speaker, "name": name.strip(), "voice_profile_enrolled": enrolled[speaker]}
                    for speaker, name in sorted(names.items())
                ],
            })
            return 0
        if args.command == "name-speakers":
            _print_json(_name_speakers(args))
            return 0
        if args.command == "context-voices":
            _print_json({"schema_version": 1, "profiles": SpeakerRegistry(args.db).context_profiles()})
            return 0
        if args.command == "learn-context-voices":
            _print_json({"schema_version": 1, "enrolled": SpeakerRegistry(args.db).learn_all_from_context()})
            return 0
        if args.command == "forget-context-voices":
            meeting_id = str(uuid.UUID(args.meeting_id)).lower() if args.meeting_id else None
            _print_json({
                "schema_version": 1,
                **SpeakerRegistry(args.db).forget_context_profiles(name=args.name, meeting_id=meeting_id),
            })
            return 0
        if args.command == "locate":
            path = _accepted_archive_path(args.db, args.archive_root, args.meeting_id)
            _print_json({"schema_version": 1, "meeting_id": args.meeting_id, "archive_path": str(path)})
            return 0
        if args.command == "rename":
            return _rename(args)
        if args.command == "search":
            from .search import search_transcripts

            JobQueue(args.db)  # validates the database directory and schema
            _print_json(search_transcripts(args.db, args.archive_root, args.query, args.limit))
            return 0
        raise AssertionError(f"Unknown command {args.command}")
    except (
        ManifestError,
        MediaValidationError,
        ArchiveConflict,
        QueueConflict,
        ValueError,
        OSError,
        json.JSONDecodeError,
    ) as error:
        _print_json(
            {"schema_version": 1, "error": type(error).__name__, "message": str(error)},
            stream=sys.stderr,
        )
        return 2
