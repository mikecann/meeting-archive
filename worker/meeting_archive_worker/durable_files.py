"""Crash-safe replacement of derived worker artifacts."""

from __future__ import annotations

import math
import os
import stat
import tempfile
import time
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path

try:
    import fcntl
except ImportError:  # Windows has no flock. The worker runs on macOS.
    fcntl = None


def _fsync_directory(path: Path) -> None:
    try:
        descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    except OSError:
        # Windows does not provide the POSIX directory-fsync primitive. The
        # file itself was flushed before the atomic replace.
        if os.name == "nt":
            return
        raise
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def atomic_write_bytes(path: Path, data: bytes) -> None:
    """Write and fsync a same-directory temporary file before atomic replace."""

    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.",
        suffix=".part",
        dir=path.parent,
    )
    temporary = Path(temporary_name)
    try:
        view = memoryview(data)
        while view:
            written = os.write(descriptor, view)
            if written <= 0:
                raise OSError("Derived artifact write made no progress.")
            view = view[written:]
        os.fsync(descriptor)
        completed_descriptor = descriptor
        descriptor = -1
        os.close(completed_descriptor)
        os.replace(temporary, path)
        _fsync_directory(path.parent)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        temporary.unlink(missing_ok=True)


def atomic_write_text(path: Path, value: str) -> None:
    atomic_write_bytes(path, value.encode("utf-8"))


@contextmanager
def exclusive_lock(path: Path, *, timeout_seconds: float = 30.0) -> Iterator[None]:
    """Hold an owner-only advisory lock file, waiting at most timeout_seconds.

    Separate processes (the service and an SSH command from the Mac) use this
    to serialize a read-then-write of the same derived file.
    """

    if (
        not isinstance(timeout_seconds, (int, float))
        or isinstance(timeout_seconds, bool)
        or not math.isfinite(timeout_seconds)
        or timeout_seconds < 0
    ):
        raise ValueError("Lock timeout must be finite and nonnegative.")
    descriptor = os.open(
        path,
        os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0),
        0o600,
    )
    try:
        opened = os.fstat(descriptor)
        if not stat.S_ISREG(opened.st_mode):
            raise ValueError(f"{path.name} must be a regular file.")
        # O_CREAT's mode only applies to a new file, so an existing one is
        # checked and made owner-only, as the speaker refresh lock is.
        if hasattr(os, "geteuid") and opened.st_uid != os.geteuid():
            raise ValueError(f"{path.name} must be owned by the worker user.")
        if hasattr(os, "fchmod"):
            os.fchmod(descriptor, 0o600)
        if fcntl is None:
            yield
            return
        deadline = time.monotonic() + timeout_seconds
        while True:
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError(f"Timed out waiting for {path.name}.") from None
                time.sleep(min(0.05, remaining))
        try:
            yield
        finally:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
    finally:
        os.close(descriptor)
