from __future__ import annotations

import io
import json
import sys
import tempfile
import threading
import unittest
import uuid
from contextlib import redirect_stderr, redirect_stdout
from datetime import datetime, time
from pathlib import Path


WORKER_ROOT = Path(__file__).resolve().parents[1] / "worker"
sys.path.insert(0, str(WORKER_ROOT))

from meeting_archive_worker.cli import main as cli_main  # noqa: E402
from meeting_archive_worker.queue import JobQueue  # noqa: E402
from meeting_archive_worker.quiet_hours import (  # noqa: E402
    DEFAULT,
    QuietHours,
    held_until,
    parse_quiet_hours,
    quiet_hours_from_environment,
    record_hold,
)
from meeting_archive_worker.service import run_processing  # noqa: E402


NIGHT = QuietHours(time(22, 0), time(6, 0))


def at(hour: int, minute: int = 0, second: int = 0, day: int = 21) -> datetime:
    # A month with no daylight saving change, safely in the past.
    return datetime(2025, 1, day, hour, minute, second)


class QuietHoursWindowTests(unittest.TestCase):
    def test_overnight_window_crosses_midnight(self) -> None:
        self.assertEqual(NIGHT.ends_at(at(23, 30)), at(6, day=22))
        self.assertEqual(NIGHT.ends_at(at(0, 0)), at(6))
        self.assertEqual(NIGHT.ends_at(at(3, 15)), at(6))
        self.assertIsNone(NIGHT.ends_at(at(12, 0)))

    def test_start_is_quiet_and_end_is_not(self) -> None:
        self.assertIsNone(NIGHT.ends_at(at(21, 59, 59)))
        self.assertEqual(NIGHT.ends_at(at(22, 0)), at(6, day=22))
        self.assertEqual(NIGHT.ends_at(at(5, 59, 59)), at(6))
        self.assertIsNone(NIGHT.ends_at(at(6, 0)))

    def test_window_within_one_day(self) -> None:
        lunch = parse_quiet_hours("12:00-13:30")
        self.assertIsNone(lunch.ends_at(at(11, 59)))
        self.assertEqual(lunch.ends_at(at(12, 0)), at(13, 30))
        self.assertIsNone(lunch.ends_at(at(13, 30)))
        self.assertIsNone(lunch.ends_at(at(23, 0)))

    def test_default_is_ten_at_night_until_six(self) -> None:
        self.assertEqual(quiet_hours_from_environment({}), NIGHT)
        self.assertEqual(DEFAULT, "22:00-06:00")
        self.assertEqual(str(NIGHT), "22:00-06:00")

    def test_can_be_turned_off(self) -> None:
        self.assertIsNone(parse_quiet_hours("off"))
        self.assertIsNone(parse_quiet_hours(" OFF "))
        self.assertIsNone(quiet_hours_from_environment({"MEETING_ARCHIVE_QUIET_HOURS": ""}))

    def test_a_typo_keeps_the_default_rather_than_turning_it_off(self) -> None:
        for text in ("22-06", "25:00-06:00", "22:00-22:00", "tonight"):
            with self.subTest(text=text):
                with self.assertRaises(ValueError):
                    parse_quiet_hours(text)
                logged = []
                window = quiet_hours_from_environment(
                    {"MEETING_ARCHIVE_QUIET_HOURS": text}, log=logged.append,
                )
                self.assertEqual(window, NIGHT)
                self.assertEqual(len(logged), 1)


class QuietHoursServiceTests(unittest.TestCase):
    def test_ready_job_waits_until_quiet_hours_end(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            database = Path(temporary) / "worker.sqlite3"
            queue = JobQueue(database)
            queue.enqueue(str(uuid.uuid4()), 1, "a" * 64, temporary)
            calls = []
            night = at(23, 0).timestamp()
            morning = at(6, day=22).timestamp()

            with redirect_stderr(io.StringIO()):
                held = run_processing(
                    database, processor=lambda *_: calls.append("process"),
                    lease_seconds=60, quiet_hours=NIGHT, clock=lambda: night,
                )
            self.assertFalse(held)
            self.assertEqual(calls, [])
            self.assertEqual(queue.status()["jobs"][0]["state"], "ready")
            self.assertEqual(held_until(database, night), morning)

            with redirect_stderr(io.StringIO()):
                started = run_processing(
                    database, processor=lambda *_: calls.append("process"),
                    lease_seconds=60, quiet_hours=NIGHT, clock=lambda: morning,
                )
            self.assertTrue(started)
            self.assertEqual(calls, ["process"])
            self.assertIsNone(held_until(database, morning))

    def test_turned_off_starts_a_job_at_night(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            database = Path(temporary) / "worker.sqlite3"
            JobQueue(database).enqueue(str(uuid.uuid4()), 1, "a" * 64, temporary)

            self.assertTrue(run_processing(
                database, processor=lambda *_: None, lease_seconds=60,
                quiet_hours=None, clock=lambda: at(23, 0).timestamp(),
            ))

    def test_job_running_when_quiet_hours_start_is_left_to_finish(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            database = Path(temporary) / "worker.sqlite3"
            queue = JobQueue(database)
            queue.enqueue(str(uuid.uuid4()), 1, "a" * 64, temporary)
            queue.enqueue(str(uuid.uuid4()), 1, "b" * 64, temporary)
            now = [at(21, 59).timestamp()]
            processing = threading.Event()
            release = threading.Event()

            def slow_processor(_archive, _job):
                processing.set()
                release.wait(5)

            heavy = threading.Thread(
                target=run_processing,
                args=(database, slow_processor, 60, NIGHT, lambda: now[0]),
            )
            heavy.start()
            self.assertTrue(processing.wait(2))
            now[0] = at(22, 30).timestamp()
            with redirect_stderr(io.StringIO()):
                # The next poll inside the window holds the second job.
                self.assertFalse(run_processing(
                    database, processor=lambda *_: None, lease_seconds=60,
                    quiet_hours=NIGHT, clock=lambda: now[0],
                ))
            release.set()
            heavy.join(5)

            states = [job["state"] for job in queue.status()["jobs"]]
            self.assertEqual(states, ["succeeded", "ready"])

    def test_status_reports_when_held_jobs_can_start(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            database = Path(temporary) / "worker.sqlite3"
            JobQueue(database).enqueue(str(uuid.uuid4()), 1, "a" * 64, temporary)

            def status() -> dict:
                output = io.StringIO()
                with redirect_stdout(output):
                    self.assertEqual(cli_main(["status", "--db", str(database)]), 0)
                return json.loads(output.getvalue())

            self.assertIsNone(status()["quiet_hours_until"])
            with redirect_stderr(io.StringIO()):
                run_processing(
                    database, processor=lambda *_: None, lease_seconds=60,
                    quiet_hours=NIGHT, clock=lambda: at(23, 0).timestamp(),
                )
            # That night is long gone, and a service that stopped mid-window
            # must not leave jobs looking held forever.
            self.assertIsNone(status()["quiet_hours_until"])

            morning = datetime.now().timestamp() + 3600
            record_hold(database, morning)
            self.assertEqual(status()["quiet_hours_until"], morning)

if __name__ == "__main__":
    unittest.main()
