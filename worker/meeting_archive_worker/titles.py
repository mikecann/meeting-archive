"""Display titles stored beside the immutable, manifest-hashed metadata.json.

title.json holds a rename. It records who wrote it: "user" for a rename, the
default for older files, or "ai" for a title written from the transcript
summary. A summary may only replace a title nobody chose, so a user's rename
or a calendar match always wins, now and later.
"""

from __future__ import annotations

import json
import os
import re
import stat
import unicodedata
from collections.abc import Iterator
from contextlib import contextmanager
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from .durable_files import atomic_write_text, exclusive_lock


TITLE_NAME = "title.json"
LOCK_NAME = ".title.lock"
MAX_TITLE_LENGTH = 200
MAX_TITLE_FILE_BYTES = 64 * 1024
MAX_METADATA_BYTES = 1024 * 1024
USER = "user"
AI = "ai"

# The app's own titles for a recording nothing else named. v1 wrote "Meeting
# 23 Sep 2026 at 6:47 am"; v2, before it recorded title_source, wrote "Zoom
# call 1 Oct 2026 at 3:15 pm (part 2)". The date and time follow the Mac's
# locale, with a narrow no-break space before am/pm on recent macOS.
_DATE = r"(?:\d{1,2}\s+[A-Za-z]{3,4}\.?,?\s+\d{4}|[A-Za-z]{3,4}\.?\s+\d{1,2},?\s+\d{4})"
_TIME = r"\d{1,2}[:.]\d{2}(?:\s*[AaPp]\.?\s*[Mm]\.?)?"
_STAMP = rf"{_DATE}(?:,\s*|\s+at\s+){_TIME}"
V1_DEFAULT_TITLE = re.compile(rf"Meeting\s+{_STAMP}")
V2_DEFAULT_TITLE = re.compile(rf".+?\s+call\s+{_STAMP}(?:\s+\(part\s+\d+\))?")


def normalize_title(value: Any) -> str:
    """Trim a user title and reject empty, oversized or control-character text."""
    if not isinstance(value, str):
        raise ValueError("The meeting title must be text.")
    title = value.strip()
    if not title:
        raise ValueError("The meeting title must not be empty.")
    if len(title) > MAX_TITLE_LENGTH:
        raise ValueError(f"The meeting title must be at most {MAX_TITLE_LENGTH} characters.")
    # Cc covers tabs and newlines; Zl/Zp are Unicode line and paragraph breaks.
    if any(unicodedata.category(character) in ("Cc", "Zl", "Zp") for character in title):
        raise ValueError("The meeting title must not contain control characters or line breaks.")
    return title


def _title_record(record: Any) -> dict[str, str] | None:
    """The usable title and its source from a parsed title.json."""
    if not isinstance(record, dict) or record.get("schema_version") != 1:
        return None
    try:
        title = normalize_title(record.get("title"))
    except ValueError:
        return None
    # Renames from before sources were recorded, or with a source this
    # version doesn't know, are treated as the user's and never replaced.
    return {"title": title, "source": AI if record.get("source") == AI else USER}


def title_override(record: Any) -> str | None:
    """The title from a parsed title.json, or None when it is not usable."""
    parsed = _title_record(record)
    return parsed["title"] if parsed else None


def _read_title_file(archive: Path) -> tuple[bool, dict[str, str] | None]:
    """(exists, usable record). A file that exists but can't be used is (True, None)."""
    path = archive / TITLE_NAME
    try:
        info = path.lstat()
    except FileNotFoundError:
        return False, None
    except OSError:
        return True, None
    try:
        if not stat.S_ISREG(info.st_mode) or info.st_size > MAX_TITLE_FILE_BYTES:
            return True, None
        return True, _title_record(json.loads(path.read_text(encoding="utf-8")))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        return True, None


def read_title_override(archive_dir: Path | str) -> str | None:
    # A damaged rename must never hide the meeting; callers fall back to metadata.
    _, record = _read_title_file(Path(archive_dir))
    return record["title"] if record else None


def effective_title(archive_dir: Path | str, metadata: dict[str, Any]) -> str | None:
    """Prefer the user's rename, then the captured title. Callers pick the fallback."""
    override = read_title_override(archive_dir)
    if override is not None:
        return override
    captured = metadata.get("title") if isinstance(metadata, dict) else None
    return captured if isinstance(captured, str) and captured.strip() else None


def display_title(archive_dir: Path | str) -> str | None:
    """The title Notion, search and the app show, read from bounded files."""
    archive = Path(archive_dir)
    metadata: Any = {}
    path = archive / "metadata.json"
    try:
        info = path.lstat()
        if stat.S_ISREG(info.st_mode) and info.st_size <= MAX_METADATA_BYTES:
            metadata = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        metadata = {}
    return effective_title(archive, metadata if isinstance(metadata, dict) else {})


def title_is_automatic(archive_dir: Path | str, metadata: dict[str, Any]) -> bool:
    """Whether the current title was made up rather than chosen by someone."""
    exists, record = _read_title_file(Path(archive_dir))
    if exists:
        # An unreadable title.json may be the user's, so it is never replaced.
        return record is not None and record["source"] == AI
    if not isinstance(metadata, dict):
        return False
    source = metadata.get("title_source")
    if source is not None:
        return source == "default"
    title = metadata.get("title")
    if not isinstance(title, str) or not title.strip():
        return True
    title = title.strip()
    return bool(V1_DEFAULT_TITLE.fullmatch(title) or V2_DEFAULT_TITLE.fullmatch(title))


@contextmanager
def title_lock(archive_dir: Path | str) -> Iterator[None]:
    """Serialize title changes, so a rename can't be lost to a generated title."""
    with exclusive_lock(Path(archive_dir) / LOCK_NAME):
        yield


def _refuse_declared_title_file(archive: Path) -> None:
    manifest = json.loads((archive / "manifest.json").read_text(encoding="utf-8"))
    declared = {
        str(entry.get("path", "")).casefold()
        for entry in manifest.get("files", [])
        if isinstance(entry, dict)
    }
    if TITLE_NAME in declared:
        # Never overwrite a preserved, manifest-hashed source file.
        raise ValueError(f"This archive declares {TITLE_NAME} as a source file; it cannot be renamed.")


def _write_title_file(archive: Path, record: dict[str, Any]) -> None:
    path = archive / TITLE_NAME
    if os.path.lexists(path) and not stat.S_ISREG(path.lstat().st_mode):
        raise ValueError(f"{TITLE_NAME} must be a regular file.")
    record = {
        "schema_version": 1,
        **record,
        "updated_at": datetime.now(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
    }
    atomic_write_text(path, json.dumps(record, ensure_ascii=False, sort_keys=True, indent=2) + "\n")


def write_title(archive_dir: Path | str, title: str) -> str:
    """Atomically record a user's rename. Rewriting the same title leaves the file untouched."""
    archive = Path(archive_dir)
    title = normalize_title(title)
    _refuse_declared_title_file(archive)
    with title_lock(archive):
        _, record = _read_title_file(archive)
        if record == {"title": title, "source": USER}:
            return title
        # Renaming to a generated title still makes it the user's, so a later
        # summary can't change it.
        _write_title_file(archive, {"title": title, "source": USER})
    return title


def apply_generated_title(
    archive_dir: Path | str,
    title: str,
    metadata: dict[str, Any],
    *,
    model: str,
) -> bool:
    """Replace an automatic title with one written from the transcript.

    Returns whether title.json changed. A user's rename, a calendar match or
    any title the app can't tell apart from one stays as it is.
    """
    archive = Path(archive_dir)
    title = normalize_title(title)
    _refuse_declared_title_file(archive)
    with title_lock(archive):
        if not title_is_automatic(archive, metadata):
            return False
        _, record = _read_title_file(archive)
        if record is not None and record["title"] == title:
            return False
        _write_title_file(archive, {"title": title, "source": AI, "model": model})
    return True
