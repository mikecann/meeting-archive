"""Quiet hours: a nightly window when Bruce starts no heavy processing job.

Bruce shares its 8 GB with Sammy Cam, which records, runs a detector and its
own database every night and has to answer within a second. CPU priority can
be shared, memory can't, so transcription and diarization wait for morning.
"""

from __future__ import annotations

import os
import re
import sqlite3
from dataclasses import dataclass
from datetime import datetime, time, timedelta
from pathlib import Path

from .db import closing_connection

VARIABLE = "MEETING_ARCHIVE_QUIET_HOURS"
DEFAULT = "22:00-06:00"
_PATTERN = re.compile(r"(\d{1,2}):(\d{2})-(\d{1,2}):(\d{2})")


@dataclass(frozen=True)
class QuietHours:
    start: time
    end: time

    def ends_at(self, now: datetime) -> datetime | None:
        """When the window that contains `now` ends, or None outside it.

        The start minute is quiet and the end minute is not, so 22:00-06:00
        holds a job at 22:00 and lets it start at 06:00.
        """
        clock = now.time().replace(tzinfo=None)
        if self.start < self.end:
            inside = self.start <= clock < self.end
        else:
            # Crosses midnight: 22:00-06:00 is from 22:00 tonight, or before 06:00 today.
            inside = clock >= self.start or clock < self.end
        if not inside:
            return None
        end = now.replace(hour=self.end.hour, minute=self.end.minute, second=0, microsecond=0)
        return end if end > now else end + timedelta(days=1)

    def resumes_at(self, timestamp: float) -> float | None:
        """`ends_at` for a Unix time, read in the machine's local time zone."""
        end = self.ends_at(datetime.fromtimestamp(timestamp))
        return None if end is None else end.timestamp()

    def __str__(self) -> str:
        return f"{self.start:%H:%M}-{self.end:%H:%M}"


def parse_quiet_hours(text: str) -> QuietHours | None:
    """Read "HH:MM-HH:MM" in local time. "off" or an empty value turns it off."""
    value = text.strip()
    if value.lower() in ("", "off"):
        return None
    match = _PATTERN.fullmatch(value)
    if match is None:
        raise ValueError(f"{VARIABLE} must look like 22:00-06:00, or be off.")
    start_hour, start_minute, end_hour, end_minute = (int(part) for part in match.groups())
    try:
        window = QuietHours(time(start_hour, start_minute), time(end_hour, end_minute))
    except ValueError:
        raise ValueError(f"{VARIABLE} has a time that isn't on the clock: {value}") from None
    if window.start == window.end:
        raise ValueError(f"{VARIABLE} starts and ends at the same time; use off instead.")
    return window


def quiet_hours_from_environment(environment=None, log=None) -> QuietHours | None:
    """The configured window. A typo falls back to the default rather than to
    no quiet hours, since Sammy Cam is the one that suffers if it's wrong."""
    environment = os.environ if environment is None else environment
    try:
        return parse_quiet_hours(environment.get(VARIABLE, DEFAULT))
    except ValueError as error:
        if log is not None:
            log(f"{error} Using {DEFAULT}.")
        return parse_quiet_hours(DEFAULT)


def _connect(database: Path | str) -> sqlite3.Connection:
    connection = sqlite3.connect(database, timeout=30)
    connection.execute(
        "CREATE TABLE IF NOT EXISTS quiet_hours ("
        "id INTEGER PRIMARY KEY CHECK (id = 1), held_until REAL)",
    )
    return connection


def record_hold(database: Path | str, held_until: float | None) -> bool:
    """Save when held jobs can start, so `status` can show why they wait.

    Only writes on a change, so polling every 15 seconds overnight doesn't
    keep touching the database. Returns whether it changed.
    """
    with closing_connection(lambda: _connect(database)) as connection:
        if held_until is None:
            cursor = connection.execute(
                "UPDATE quiet_hours SET held_until=NULL WHERE id = 1 AND held_until IS NOT NULL",
            )
        else:
            cursor = connection.execute(
                "INSERT INTO quiet_hours (id, held_until) VALUES (1, ?) "
                "ON CONFLICT(id) DO UPDATE SET held_until=excluded.held_until "
                "WHERE held_until IS NOT excluded.held_until",
                (held_until,),
            )
        return cursor.rowcount == 1


def held_until(database: Path | str, now: float) -> float | None:
    """When the service said held jobs start, if that is still to come.

    A service that stopped mid-window leaves its last answer behind, which
    simply expires once that morning arrives.
    """
    with closing_connection(lambda: _connect(database)) as connection:
        row = connection.execute("SELECT held_until FROM quiet_hours WHERE id = 1").fetchone()
    if row is None or row[0] is None or row[0] <= now:
        return None
    return float(row[0])
