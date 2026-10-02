from __future__ import annotations

import os
import stat
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

from meeting_archive_worker.durable_files import exclusive_lock


class ExclusiveLockTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.lock = Path(self.temporary.name) / ".title.lock"

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_an_existing_lock_file_is_made_owner_only(self) -> None:
        self.lock.touch()
        self.lock.chmod(0o644)

        with exclusive_lock(self.lock):
            self.assertEqual(stat.S_IMODE(self.lock.stat().st_mode), 0o600)

    @unittest.skipUnless(hasattr(os, "geteuid"), "file owners need POSIX")
    def test_a_lock_file_owned_by_someone_else_is_refused(self) -> None:
        self.lock.touch()

        with patch("os.geteuid", return_value=os.geteuid() + 1):
            with self.assertRaisesRegex(ValueError, "owned by the worker user"):
                with exclusive_lock(self.lock):
                    self.fail("the lock was taken")

    def test_the_wait_must_be_finite_and_nonnegative(self) -> None:
        for timeout in (float("nan"), float("inf"), -1.0, True, "30"):
            with self.subTest(timeout=timeout), self.assertRaises(ValueError):
                with exclusive_lock(self.lock, timeout_seconds=timeout):  # type: ignore[arg-type]
                    self.fail("the lock was taken")
        self.assertFalse(self.lock.exists())

    @unittest.skipIf(os.name == "nt", "the worker locks with flock")
    def test_a_short_wait_never_sleeps_past_its_deadline(self) -> None:
        sleeps: list[float] = []
        sleep = time.sleep

        with exclusive_lock(self.lock):
            with patch("time.sleep", side_effect=lambda seconds: (sleeps.append(seconds), sleep(seconds))):
                with self.assertRaises(TimeoutError):
                    with exclusive_lock(self.lock, timeout_seconds=0.03):
                        self.fail("the second lock unexpectedly succeeded")

        self.assertLessEqual(max(sleeps, default=0.0), 0.03)


if __name__ == "__main__":
    unittest.main()
