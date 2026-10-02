"""Meeting renames live beside the immutable, manifest-hashed metadata."""

from __future__ import annotations

import hashlib
import io
import json
import sys
import tempfile
import unittest
import uuid
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path


WORKER_ROOT = Path(__file__).resolve().parents[1] / "worker"
sys.path.insert(0, str(WORKER_ROOT))

from meeting_archive_worker.archive import ArchiveStore  # noqa: E402
from meeting_archive_worker.cli import main as cli_main  # noqa: E402
from meeting_archive_worker.notion import publish  # noqa: E402
from meeting_archive_worker.queue import JobQueue  # noqa: E402
from meeting_archive_worker.service import PublicationQueue  # noqa: E402
from meeting_archive_worker.titles import effective_title, normalize_title  # noqa: E402
from test_notion import PLAYBACK_BASE, MockTransport  # noqa: E402
from test_worker import write_bundle  # noqa: E402


def tree_digest(root: Path) -> dict[str, str]:
    return {
        str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in sorted(root.rglob("*"))
        if path.is_file()
    }


class RenameTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.archive_root = self.root / "archive"
        self.archive_root.mkdir()
        self.database = self.root / "worker.sqlite3"
        incoming, _ = write_bundle(self.root)
        acknowledgement = ArchiveStore(self.archive_root, self.database).accept(incoming)
        self.meeting_id = acknowledgement["meeting_id"]
        self.archive = Path(acknowledgement["archive_path"])
        self.job_id = int(acknowledgement["queue_job_id"])

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def rename(self, title: str, meeting_id: str | None = None) -> tuple[int, dict | None, str]:
        stdout, stderr = io.StringIO(), io.StringIO()
        with redirect_stdout(stdout), redirect_stderr(stderr):
            code = cli_main([
                "rename",
                "--meeting-id", meeting_id or self.meeting_id,
                "--title", title,
                "--archive-root", str(self.archive_root),
                "--db", str(self.database),
            ])
        output = json.loads(stdout.getvalue()) if stdout.getvalue() else None
        return code, output, stderr.getvalue()

    def complete_processing(self) -> None:
        queue = JobQueue(self.database)
        queue.complete(queue.claim_ready("worker", 60))  # type: ignore[arg-type]

    def test_rename_writes_title_file_without_touching_manifest_files(self) -> None:
        before = tree_digest(self.archive)

        code, output, _ = self.rename("  Quarterly planning  ")

        self.assertEqual(code, 0)
        self.assertEqual(
            output,
            {"schema_version": 1, "meeting_id": self.meeting_id, "title": "Quarterly planning"},
        )
        record = json.loads((self.archive / "title.json").read_text(encoding="utf-8"))
        self.assertEqual(record["schema_version"], 1)
        self.assertEqual(record["title"], "Quarterly planning")
        self.assertEqual(record["source"], "user")
        self.assertIsInstance(record["updated_at"], str)
        after = tree_digest(self.archive)
        after.pop("title.json")
        after.pop(".title.lock")
        self.assertEqual(after, before)

    def test_rename_is_idempotent(self) -> None:
        self.rename("Quarterly planning")
        first = (self.archive / "title.json").read_bytes()

        code, output, _ = self.rename("Quarterly planning")

        self.assertEqual(code, 0)
        self.assertEqual(output["title"], "Quarterly planning")  # type: ignore[index]
        self.assertEqual((self.archive / "title.json").read_bytes(), first)

    def test_invalid_titles_are_rejected_without_writing(self) -> None:
        for title in ("", "   ", "x" * 201, "Line\nbreak", "Tab\there", "Bell\x07"):
            with self.subTest(title=title):
                code, output, stderr = self.rename(title)
                self.assertEqual(code, 2)
                self.assertIsNone(output)
                self.assertIn("title", json.loads(stderr)["message"].lower())
        self.assertFalse((self.archive / "title.json").exists())

    def test_unknown_meeting_fails_with_clear_error(self) -> None:
        unknown = str(uuid.uuid4())

        code, output, stderr = self.rename("Anything", unknown)

        self.assertEqual(code, 2)
        self.assertIsNone(output)
        error = json.loads(stderr)
        self.assertIn(unknown, error["message"])
        self.assertIn("not accepted", error["message"])

    def test_rename_queues_republication_for_succeeded_processing(self) -> None:
        self.complete_processing()
        publications = PublicationQueue(self.database)
        publications.reconcile(JobQueue(self.database).status()["jobs"])
        self.assertTrue(publications.run_one(lambda _archive: None))
        self.assertEqual(publications.status({self.job_id})["phase"], "succeeded")

        code, _, _ = self.rename("Quarterly planning")

        self.assertEqual(code, 0)
        job = publications.status({self.job_id})["jobs"][0]
        self.assertEqual(job["state"], "ready")
        self.assertEqual(job["archive_path"], str(self.archive))

    def test_rename_before_processing_leaves_publication_to_normal_flow(self) -> None:
        code, _, _ = self.rename("Quarterly planning")

        self.assertEqual(code, 0)
        self.assertEqual(PublicationQueue(self.database).status()["jobs"], [])


class EffectiveTitleTests(unittest.TestCase):
    def test_prefers_title_file_and_falls_back_to_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary)
            metadata = {"title": "Meeting 23 Sep 2026 at 6:47 am"}
            self.assertEqual(effective_title(archive, metadata), "Meeting 23 Sep 2026 at 6:47 am")
            self.assertIsNone(effective_title(archive, {}))

            (archive / "title.json").write_text("not json", encoding="utf-8")
            self.assertEqual(effective_title(archive, metadata), "Meeting 23 Sep 2026 at 6:47 am")

            (archive / "title.json").write_text(
                json.dumps({"schema_version": 1, "title": "Renamed", "updated_at": "2026-09-29T00:00:00Z"}),
                encoding="utf-8",
            )
            self.assertEqual(effective_title(archive, metadata), "Renamed")
            self.assertEqual(effective_title(archive, {}), "Renamed")

    def test_normalize_title_trims_and_bounds(self) -> None:
        self.assertEqual(normalize_title("  Planning  "), "Planning")
        self.assertEqual(len(normalize_title("x" * 200)), 200)
        with self.assertRaises(ValueError):
            normalize_title("x" * 201)


class TitleSourceTests(unittest.TestCase):
    """Which titles a summary may replace: only ones nobody chose."""

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.archive = Path(self.temporary.name)
        (self.archive / "manifest.json").write_text(
            json.dumps({"files": [{"path": "metadata.json"}]}), encoding="utf-8",
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def write_title_file(self, record: dict) -> None:
        (self.archive / "title.json").write_text(json.dumps(record), encoding="utf-8")

    def test_app_recorded_sources_decide_for_new_recordings(self) -> None:
        from meeting_archive_worker.titles import title_is_automatic

        self.assertTrue(title_is_automatic(self.archive, {"title": "Zoom call", "title_source": "default"}))
        self.assertFalse(title_is_automatic(self.archive, {"title": "Acme catch up", "title_source": "calendar"}))
        self.assertFalse(title_is_automatic(self.archive, {"title": "Mum's birthday", "title_source": "user"}))
        self.assertFalse(title_is_automatic(self.archive, {"title": "Zoom call", "title_source": "something new"}))

    def test_older_recordings_without_a_source_are_judged_by_the_default_pattern(self) -> None:
        from meeting_archive_worker.titles import title_is_automatic

        automatic = [
            "Meeting 23 Sep 2026 at 6:47 am",
            "Meeting 21 Sep 2026 at 10:13 pm",
            "Meeting 21 Sept 2026 at 22:13",
            "Meeting Sep 21, 2026 at 10:13 PM",
            # v2 before it recorded title_source.
            "Zoom call 1 Oct 2026 at 3:15 pm",
            "Google Chrome call 1 Oct 2026 at 3:15 pm (part 2)",
        ]
        chosen = [
            "Acme catch up",
            "Meeting with Sam about the budget",
            "Meeting 23 Sep 2026 at 6:47 am with Sam",
            "Weekly sync 1 Oct 2026",
        ]
        for title in automatic:
            with self.subTest(title=title):
                self.assertTrue(title_is_automatic(self.archive, {"title": title}))
        for title in chosen:
            with self.subTest(title=title):
                self.assertFalse(title_is_automatic(self.archive, {"title": title}))
        self.assertTrue(title_is_automatic(self.archive, {}))

    def test_a_title_file_decides_before_metadata(self) -> None:
        from meeting_archive_worker.titles import title_is_automatic

        default = {"title": "Zoom call", "title_source": "default"}
        self.write_title_file({"schema_version": 1, "title": "Renamed", "updated_at": "2026-09-29T00:00:00Z"})
        self.assertFalse(title_is_automatic(self.archive, default), "a rename from before sources is the user's")
        self.write_title_file({"schema_version": 1, "title": "Renamed", "source": "user"})
        self.assertFalse(title_is_automatic(self.archive, default))
        self.write_title_file({"schema_version": 1, "title": "Budget review", "source": "ai"})
        self.assertTrue(title_is_automatic(self.archive, default))
        (self.archive / "title.json").write_text("{broken", encoding="utf-8")
        self.assertFalse(title_is_automatic(self.archive, default), "never replace a title file it cannot read")

    def test_generated_title_replaces_only_automatic_titles(self) -> None:
        from meeting_archive_worker.titles import apply_generated_title

        self.assertFalse(apply_generated_title(
            self.archive, "Budget review", {"title": "Acme catch up", "title_source": "calendar"}, model="m",
        ))
        self.assertFalse((self.archive / "title.json").exists())
        self.assertFalse(apply_generated_title(
            self.archive, "Budget review", {"title": "Mum's birthday", "title_source": "user"}, model="m",
        ))
        self.assertFalse((self.archive / "title.json").exists())

        self.assertTrue(apply_generated_title(
            self.archive, "  Budget review  ", {"title": "Meeting 23 Sep 2026 at 6:47 am"}, model="claude-opus-5-5",
        ))
        record = json.loads((self.archive / "title.json").read_text(encoding="utf-8"))
        self.assertEqual(record["title"], "Budget review")
        self.assertEqual(record["source"], "ai")
        self.assertEqual(record["model"], "claude-opus-5-5")
        self.assertEqual(effective_title(self.archive, {"title": "Meeting 23 Sep 2026 at 6:47 am"}), "Budget review")

    def test_generated_title_is_idempotent_and_may_update_its_own_title(self) -> None:
        from meeting_archive_worker.titles import apply_generated_title

        metadata = {"title": "Zoom call", "title_source": "default"}
        self.assertTrue(apply_generated_title(self.archive, "Budget review", metadata, model="m"))
        first = (self.archive / "title.json").read_bytes()
        self.assertFalse(apply_generated_title(self.archive, "Budget review", metadata, model="m"))
        self.assertEqual((self.archive / "title.json").read_bytes(), first)
        self.assertTrue(apply_generated_title(self.archive, "Budget review with Sam", metadata, model="m"))
        self.assertEqual(effective_title(self.archive, metadata), "Budget review with Sam")

    def test_a_user_rename_always_wins_later_too(self) -> None:
        from meeting_archive_worker.titles import apply_generated_title, write_title

        metadata = {"title": "Zoom call", "title_source": "default"}
        apply_generated_title(self.archive, "Budget review", metadata, model="m")
        write_title(self.archive, "Mike's budget chat")
        record = json.loads((self.archive / "title.json").read_text(encoding="utf-8"))
        self.assertEqual(record["source"], "user")

        self.assertFalse(apply_generated_title(self.archive, "Budget review v2", metadata, model="m"))
        self.assertEqual(effective_title(self.archive, metadata), "Mike's budget chat")

    def test_keeping_the_generated_title_by_renaming_to_it_makes_it_the_users(self) -> None:
        from meeting_archive_worker.titles import apply_generated_title, write_title

        metadata = {"title": "Zoom call", "title_source": "default"}
        apply_generated_title(self.archive, "Budget review", metadata, model="m")
        write_title(self.archive, "Budget review")

        record = json.loads((self.archive / "title.json").read_text(encoding="utf-8"))
        self.assertEqual(record["source"], "user")
        self.assertFalse(apply_generated_title(self.archive, "Something else", metadata, model="m"))

    def test_rename_waits_for_a_generated_title_being_written(self) -> None:
        import threading

        from meeting_archive_worker.titles import title_lock, write_title

        started, renamed = threading.Event(), threading.Event()

        def rename() -> None:
            started.set()
            write_title(self.archive, "Mine")
            renamed.set()

        with title_lock(self.archive):
            thread = threading.Thread(target=rename)
            thread.start()
            # Only time the wait once the rename is actually under way.
            self.assertTrue(started.wait(5))
            self.assertFalse(renamed.wait(0.3), "a rename must not interleave with a generated title")
        thread.join(5)
        self.assertTrue(renamed.is_set())
        lock = self.archive / ".title.lock"
        self.assertEqual(lock.stat().st_mode & 0o777, 0o600)

    def test_display_title_reads_bounded_metadata_and_rename(self) -> None:
        from meeting_archive_worker.titles import display_title

        self.assertIsNone(display_title(self.archive))
        (self.archive / "metadata.json").write_text(json.dumps({"title": "Zoom call"}), encoding="utf-8")
        self.assertEqual(display_title(self.archive), "Zoom call")
        self.write_title_file({"schema_version": 1, "title": "Budget review", "source": "ai"})
        self.assertEqual(display_title(self.archive), "Budget review")


class RenamedPublicationTests(unittest.TestCase):
    def test_notion_page_and_header_use_renamed_title(self) -> None:
        from test_notion import write_archive

        with tempfile.TemporaryDirectory() as temporary:
            archive = write_archive(Path(temporary))
            transport = MockTransport()
            first = publish(archive, token="token", data_source="source", transport=transport,
                            playback_base_url=PLAYBACK_BASE)
            (archive / "title.json").write_text(
                json.dumps({"schema_version": 1, "title": "Launch review", "updated_at": "2026-09-29T00:00:00Z"}),
                encoding="utf-8",
            )

            second = publish(archive, token="token", data_source="source", transport=transport,
                             playback_base_url=PLAYBACK_BASE)

            self.assertNotEqual(first["content_fingerprint"], second["content_fingerprint"])
            name = transport.pages[0]["properties"]["Name"]["title"]
            self.assertEqual("".join(item["text"]["content"] for item in name), "Launch review")
            header = next(block for block in transport.children["page-1"] if block["type"] == "heading_1")
            self.assertTrue(header["heading_1"]["rich_text"][0]["text"]["content"].startswith("Launch review"))


if __name__ == "__main__":
    unittest.main()
