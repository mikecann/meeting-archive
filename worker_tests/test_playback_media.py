from __future__ import annotations

import hashlib
import json
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch


WORKER_ROOT = Path(__file__).resolve().parents[1] / "worker"
sys.path.insert(0, str(WORKER_ROOT))

from meeting_archive_worker.manifest import VerifiedFile  # noqa: E402
from meeting_archive_worker.model_processor import create_playback, process as process_archive  # noqa: E402
from meeting_archive_worker.processing import TranscriptProcessor, timeline_offset  # noqa: E402


FFMPEG = shutil.which("ffmpeg")
FFPROBE = shutil.which("ffprobe")


def _encoder_available(name: str) -> bool:
    if FFMPEG is None:
        return False
    result = subprocess.run(
        [FFMPEG, "-hide_banner", "-encoders"],
        check=True,
        capture_output=True,
        text=True,
    )
    return bool(re.search(rf"\b{re.escape(name)}\b", result.stdout))


class PlaybackMediaTests(unittest.TestCase):
    def test_capture_metadata_wins_over_aac_container_start(self) -> None:
        self.assertEqual(timeline_offset(0.248219417, 0.044), 0.248219417)
        self.assertEqual(timeline_offset(0.2, -0.021333), 0.2)

    def test_manifest_source_cannot_collide_with_playback_output(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "Playback" / "MEETING.mp4"
            source.parent.mkdir()
            original = b"accepted HEVC source bytes"
            source.write_bytes(original)
            files = (
                VerifiedFile("Playback/MEETING.mp4", len(original), "a" * 64, "video"),
                VerifiedFile("microphone.m4a", 1, "b" * 64, "microphone_audio"),
            )
            with patch("meeting_archive_worker.model_processor.find_executable", return_value="ffmpeg"), \
                 patch("meeting_archive_worker.model_processor._playback_is_h264") as probe, \
                 patch("meeting_archive_worker.model_processor.subprocess.run") as run:
                with self.assertRaisesRegex(RuntimeError, "accepted source.*Playback/MEETING.mp4.*reserved"):
                    create_playback(root, SimpleNamespace(files=files, metadata={}))

            self.assertEqual(source.read_bytes(), original)
            probe.assert_not_called()
            run.assert_not_called()

    def test_manifest_source_cannot_collide_with_playback_receipt(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            receipt = root / "playback" / "meeting-playback.json"
            receipt.parent.mkdir()
            original = b"accepted receipt-named source"
            receipt.write_bytes(original)
            files = (
                VerifiedFile("meeting-view.mov", 1, "a" * 64, "video"),
                VerifiedFile("microphone.m4a", 1, "b" * 64, "microphone_audio"),
                VerifiedFile("playback/meeting-playback.json", len(original), "c" * 64, "metadata"),
            )
            with patch("meeting_archive_worker.model_processor.find_executable") as find, \
                 patch("meeting_archive_worker.model_processor.subprocess.run") as run:
                with self.assertRaisesRegex(RuntimeError, "accepted source.*meeting-playback.json"):
                    create_playback(root, SimpleNamespace(files=files, metadata={}))

            self.assertEqual(receipt.read_bytes(), original)
            find.assert_not_called()
            run.assert_not_called()

    def test_reserved_parent_file_and_transcript_source_are_rejected_before_processing(self) -> None:
        for relative_path in ("PLAYBACK", "Transcripts/v1/transcript.json"):
            with self.subTest(path=relative_path), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                source = root.joinpath(*relative_path.split("/"))
                source.parent.mkdir(parents=True, exist_ok=True)
                original = b"accepted source must survive"
                source.write_bytes(original)
                manifest = SimpleNamespace(
                    meeting_id="11111111-1111-4111-8111-111111111111",
                    revision=1,
                    manifest_sha256="b" * 64,
                    files=(
                        VerifiedFile(relative_path, len(original), "a" * 64, "metadata"),
                    ),
                )
                job = SimpleNamespace(
                    meeting_id=manifest.meeting_id,
                    manifest_revision=manifest.revision,
                    manifest_sha256=manifest.manifest_sha256,
                )
                with patch("meeting_archive_worker.model_processor.find_executable") as find:
                    with self.assertRaisesRegex(RuntimeError, "reserved generated namespace"):
                        create_playback(root, manifest)
                find.assert_not_called()
                with patch("meeting_archive_worker.model_processor.verify_incoming", return_value=manifest), \
                    patch("meeting_archive_worker.model_processor.WhisperPyannoteTranscriber") as transcriber:
                    with self.assertRaisesRegex(RuntimeError, "reserved generated namespace"):
                        process_archive(root, job)

                self.assertEqual(source.read_bytes(), original)
                transcriber.assert_not_called()

    def test_current_recipe_receipt_is_idempotent_and_old_h264_is_rebuilt_once(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            output = root / "playback" / "meeting.mp4"
            output.parent.mkdir()
            output.write_bytes(b"old H264 with wrong timing")
            files = (
                VerifiedFile("meeting-view.mov", 10, "a" * 64, "video"),
                VerifiedFile("microphone.m4a", 10, "b" * 64, "microphone_audio"),
            )
            manifest = SimpleNamespace(
                files=files,
                metadata={"tracks": {"video": {"firstOffset": 0.3}, "microphone": {"firstOffset": 0.2}}},
            )
            commands = []

            def fake_run(command, **_kwargs):
                commands.append(command)
                Path(command[-1]).write_bytes(b"current H264")

            with patch("meeting_archive_worker.model_processor.find_executable", return_value="ffmpeg"), \
                 patch("meeting_archive_worker.model_processor._playback_is_h264", return_value=True), \
                 patch("meeting_archive_worker.model_processor.subprocess.run", side_effect=fake_run):
                create_playback(root, manifest)
            self.assertEqual(output.read_bytes(), b"current H264")
            self.assertEqual(len(commands), 1)
            self.assertTrue((root / "playback" / "meeting-playback.json").is_file())

            with patch("meeting_archive_worker.model_processor._playback_is_h264", return_value=True), \
                 patch("meeting_archive_worker.model_processor.subprocess.run") as run:
                create_playback(root, manifest)
            run.assert_not_called()

    def test_hardware_encoder_failure_falls_back_to_bounded_libx264(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            files = (
                VerifiedFile("meeting-view.mov", 10, "a" * 64, "video"),
                VerifiedFile("microphone.m4a", 10, "b" * 64, "microphone_audio"),
            )
            commands = []

            def fake_run(command, **_kwargs):
                commands.append(command)
                if "h264_videotoolbox" in command:
                    raise subprocess.CalledProcessError(1, command, stderr="hardware encoder busy")
                Path(command[-1]).write_bytes(b"fallback H264")

            with patch("meeting_archive_worker.model_processor.find_executable", return_value="ffmpeg"), \
                 patch("meeting_archive_worker.model_processor.subprocess.run", side_effect=fake_run):
                output = create_playback(root, SimpleNamespace(files=files, metadata={}))

            self.assertEqual(output.read_bytes(), b"fallback H264")
            self.assertEqual(len(commands), 2)
            self.assertIn("h264_videotoolbox", commands[0])
            self.assertIn("libx264", commands[1])
            self.assertEqual(commands[1][commands[1].index("-threads:v") + 1], "2")

    def test_audio_only_bundle_mixes_both_tracks_into_aac_on_the_capture_clock(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            files = (
                VerifiedFile("microphone.m4a", 10, "a" * 64, "microphone_audio"),
                VerifiedFile("incoming.m4a", 12, "b" * 64, "incoming_audio"),
            )
            metadata = {"tracks": {"microphone": {"firstOffset": 0.2}, "incoming": {"firstOffset": 0.1}}}
            commands = []

            def fake_run(command, **_kwargs):
                commands.append(command)
                Path(command[-1]).write_bytes(b"AAC playback")

            with patch("meeting_archive_worker.model_processor.find_executable", return_value="ffmpeg"), \
                 patch("meeting_archive_worker.model_processor.subprocess.run", side_effect=fake_run):
                output = create_playback(root, SimpleNamespace(files=files, metadata=metadata))

            self.assertEqual(output, root / "playback" / "meeting.mp4")
            self.assertEqual(output.read_bytes(), b"AAC playback")
            [command] = commands
            self.assertEqual(
                [command[index + 1] for index, value in enumerate(command) if value == "-i"],
                [str(root / "microphone.m4a"), str(root / "incoming.m4a")],
            )
            self.assertEqual(
                command[command.index("-filter_complex") + 1],
                "[0:a:0]asetpts=PTS-STARTPTS,adelay=200:all=1[a0];"
                "[1:a:0]asetpts=PTS-STARTPTS,adelay=100:all=1[a1];"
                "[a0][a1]amix=inputs=2:duration=longest[a]",
            )
            self.assertEqual(command[command.index("-map") + 1], "[a]")
            self.assertEqual(command[command.index("-c:a") + 1], "aac")
            self.assertIn("+faststart", command)
            self.assertNotIn("-c:v", command)
            self.assertNotIn("[v]", command)
            self.assertEqual(
                json.loads((root / "playback" / "meeting-playback.json").read_text(encoding="utf-8")),
                {
                    "schema_version": 1,
                    "recipe_version": 2,
                    "sources": [
                        {"path": "microphone.m4a", "size_bytes": 10, "sha256": "a" * 64, "kind": "microphone_audio"},
                        {"path": "incoming.m4a", "size_bytes": 12, "sha256": "b" * 64, "kind": "incoming_audio"},
                    ],
                    "first_offsets": {"microphone": 0.2, "incoming": 0.1},
                },
            )

    def test_audio_only_bundle_with_one_track_needs_no_mix(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            files = (VerifiedFile("incoming.m4a", 10, "a" * 64, "incoming_audio"),)
            commands = []

            def fake_run(command, **_kwargs):
                commands.append(command)
                Path(command[-1]).write_bytes(b"AAC playback")

            with patch("meeting_archive_worker.model_processor.find_executable", return_value="ffmpeg"), \
                 patch("meeting_archive_worker.model_processor.subprocess.run", side_effect=fake_run):
                create_playback(root, SimpleNamespace(
                    files=files,
                    metadata={"tracks": {"incoming": {"firstOffset": 0.4}}},
                ))

            [command] = commands
            self.assertEqual(
                command[command.index("-filter_complex") + 1],
                "[0:a:0]asetpts=PTS-STARTPTS,adelay=400:all=1[a0]",
            )
            self.assertEqual(command[command.index("-map") + 1], "[a0]")

    def test_audio_only_receipt_is_reused_only_while_the_output_is_aac(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            files = (
                VerifiedFile("microphone.m4a", 10, "a" * 64, "microphone_audio"),
                VerifiedFile("incoming.m4a", 10, "b" * 64, "incoming_audio"),
            )
            manifest = SimpleNamespace(files=files, metadata={})
            commands = []

            def fake_run(command, **_kwargs):
                commands.append(command)
                Path(command[-1]).write_bytes(f"AAC playback {len(commands)}".encode())

            # An audio-only playback has no H.264 stream to check.
            with patch("meeting_archive_worker.model_processor.find_executable", return_value="ffmpeg"), \
                 patch("meeting_archive_worker.model_processor._playback_is_h264", side_effect=AssertionError), \
                 patch("meeting_archive_worker.model_processor.subprocess.run", side_effect=fake_run):
                create_playback(root, manifest)
                with patch("meeting_archive_worker.model_processor._playback_is_aac", return_value=True):
                    create_playback(root, manifest)
                self.assertEqual(len(commands), 1)
                with patch("meeting_archive_worker.model_processor._playback_is_aac", return_value=False):
                    output = create_playback(root, manifest)

            self.assertEqual(len(commands), 2)
            self.assertEqual(output.read_bytes(), b"AAC playback 2")

    def test_derived_output_symlink_is_replaced_and_never_receipted_as_reused(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            output = root / "playback" / "meeting.mp4"
            output.parent.mkdir()
            external = root / "external.mp4"
            output.symlink_to(external)
            files = (
                VerifiedFile("meeting-view.mov", 10, "a" * 64, "video"),
                VerifiedFile("microphone.m4a", 10, "b" * 64, "microphone_audio"),
            )
            manifest = SimpleNamespace(files=files, metadata={})
            generations = []

            def fake_run(command, **_kwargs):
                generations.append(command)
                Path(command[-1]).write_bytes(f"generated-{len(generations)}".encode())

            with patch("meeting_archive_worker.model_processor.find_executable", return_value="ffmpeg"), \
                 patch("meeting_archive_worker.model_processor._playback_is_h264") as probe, \
                 patch("meeting_archive_worker.model_processor.subprocess.run", side_effect=fake_run):
                create_playback(root, manifest)
            self.assertFalse(output.is_symlink())
            self.assertEqual(output.read_bytes(), b"generated-1")
            self.assertFalse(external.exists())
            probe.assert_not_called()

            output.unlink()
            external.write_bytes(b"accepted elsewhere")
            output.symlink_to(external)
            with patch("meeting_archive_worker.model_processor.find_executable", return_value="ffmpeg"), \
                 patch("meeting_archive_worker.model_processor._playback_is_h264") as probe, \
                 patch("meeting_archive_worker.model_processor.subprocess.run", side_effect=fake_run):
                create_playback(root, manifest)
            self.assertFalse(output.is_symlink())
            self.assertEqual(output.read_bytes(), b"generated-2")
            self.assertEqual(external.read_bytes(), b"accepted elsewhere")
            probe.assert_not_called()

    def test_playback_directory_symlink_is_rejected_without_touching_external_target(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            external = root / "external"
            external.mkdir()
            marker = external / "keep.txt"
            marker.write_bytes(b"outside archive output")
            (root / "playback").symlink_to(external, target_is_directory=True)
            files = (
                VerifiedFile("meeting-view.mov", 10, "a" * 64, "video"),
                VerifiedFile("microphone.m4a", 10, "b" * 64, "microphone_audio"),
            )
            with patch("meeting_archive_worker.model_processor.find_executable") as find, \
                 patch("meeting_archive_worker.model_processor.subprocess.run") as run:
                with self.assertRaisesRegex(RuntimeError, "playback.*real directory"):
                    create_playback(root, SimpleNamespace(files=files, metadata={}))

            self.assertEqual(marker.read_bytes(), b"outside archive output")
            self.assertEqual(list(external.iterdir()), [marker])
            find.assert_not_called()
            run.assert_not_called()

    def test_transcript_parent_symlinks_are_rejected_without_touching_external_target(self) -> None:
        for symlink_component in ("transcripts", "transcripts/v1"):
            with self.subTest(component=symlink_component), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                external = root / "external"
                external.mkdir()
                marker = external / "keep.txt"
                marker.write_bytes(b"outside transcript output")
                link = root.joinpath(*symlink_component.split("/"))
                link.parent.mkdir(parents=True, exist_ok=True)
                link.symlink_to(external, target_is_directory=True)
                manifest = SimpleNamespace(
                    meeting_id="22222222-2222-4222-8222-222222222222",
                    revision=1,
                    manifest_sha256="c" * 64,
                    files=(
                        VerifiedFile("meeting-view.mov", 10, "a" * 64, "video"),
                        VerifiedFile("microphone.m4a", 10, "b" * 64, "microphone_audio"),
                    ),
                )
                job = SimpleNamespace(
                    meeting_id=manifest.meeting_id,
                    manifest_revision=manifest.revision,
                    manifest_sha256=manifest.manifest_sha256,
                )
                with patch("meeting_archive_worker.model_processor.verify_incoming", return_value=manifest), \
                     patch("meeting_archive_worker.model_processor.WhisperPyannoteTranscriber") as transcriber:
                    with self.assertRaisesRegex(RuntimeError, "transcripts.*real directory"):
                        process_archive(root, job)

                self.assertEqual(marker.read_bytes(), b"outside transcript output")
                self.assertEqual(list(external.iterdir()), [marker])
                transcriber.assert_not_called()

    @unittest.skipUnless(
        FFMPEG and _encoder_available("libx265"),
        "ffmpeg with libx265 is required",
    )
    def test_hevc_sources_become_aligned_browser_h264_playback(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            video = root / "meeting-view.mov"
            microphone = root / "microphone.m4a"
            incoming = root / "incoming.m4a"
            subprocess.run([
                FFMPEG, "-v", "error", "-f", "lavfi", "-i", "color=black:s=160x90:r=20:d=2",
                "-vf", "drawbox=color=white:t=fill:enable='between(t,0.7,0.9)',setpts=PTS+0.3/TB",
                "-c:v", "libx265", "-tag:v", "hvc1", "-y", str(video),
            ], check=True, capture_output=True)
            for path, start, frequency, container_offset in (
                (microphone, 1.1, 1000, 0.05),
                (incoming, 0.9, 700, 0.12),
            ):
                subprocess.run([
                    FFMPEG, "-v", "error", "-f", "lavfi", "-i",
                    f"aevalsrc=if(between(t\\,{start}\\,{start + 0.1})\\,"
                    f"0.8*sin(2*PI*{frequency}*t)\\,0):s=48000:d=2",
                    "-af", f"asetpts=PTS+{container_offset}/TB", "-c:a", "aac", "-y", str(path),
                ], check=True, capture_output=True)

            files = (
                VerifiedFile(video.name, video.stat().st_size, "0" * 64, "video"),
                VerifiedFile(microphone.name, microphone.stat().st_size, "0" * 64, "microphone_audio"),
                VerifiedFile(incoming.name, incoming.stat().st_size, "0" * 64, "incoming_audio"),
            )
            source_hashes = {
                path: hashlib.sha256(path.read_bytes()).hexdigest()
                for path in (video, microphone, incoming)
            }
            manifest = SimpleNamespace(
                files=files,
                metadata={"tracks": {
                    "video": {"firstOffset": 0.6},
                    "microphone": {"firstOffset": 0.2},
                    "incoming": {"firstOffset": 0.4},
                }},
            )
            output = create_playback(root, manifest)
            self.assertIsNotNone(output)
            self.assertEqual(
                {path: hashlib.sha256(path.read_bytes()).hexdigest() for path in source_hashes},
                source_hashes,
            )

            media_info = subprocess.run([
                FFMPEG, "-hide_banner", "-i", str(output), "-map", "0", "-frames:v", "1",
                "-frames:a", "1", "-f", "null", "-",
            ], check=True, capture_output=True, text=True).stderr
            self.assertRegex(media_info, r"Video: h264 .* yuv420p")
            self.assertRegex(media_info, r"Audio: aac")

            blackdetect = subprocess.run([
                FFMPEG, "-hide_banner", "-i", str(output), "-vf",
                "blackdetect=d=0.05:pix_th=0.1", "-an", "-f", "null", "-",
            ], check=True, capture_output=True, text=True).stderr
            silencedetect = subprocess.run([
                FFMPEG, "-hide_banner", "-i", str(output), "-af",
                "silencedetect=noise=-30dB:d=0.05", "-vn", "-f", "null", "-",
            ], check=True, capture_output=True, text=True).stderr
            flash_time = float(re.search(r"black_end:([0-9.]+)", blackdetect).group(1))
            beep_time = float(re.search(r"silence_end: ([0-9.]+)", silencedetect).group(1))

            class FakeTranscriber:
                def transcribe(self, _path: Path, origin: str, *, single_speaker: bool = False):
                    start = 1.1 if origin == "microphone" else 0.9
                    return [{"start": start, "end": start + 0.1, "text": "beep"}]

            transcript_manifest = SimpleNamespace(
                files=files,
                metadata=manifest.metadata,
                meeting_id="11111111-1111-4111-8111-111111111111",
                revision=1,
            )
            transcript = TranscriptProcessor(FakeTranscriber()).process(root, transcript_manifest)
            transcript_times = [turn["start"] for turn in transcript["turns"]]
            self.assertAlmostEqual(flash_time, 1.3, delta=0.1)
            self.assertAlmostEqual(beep_time, 1.3, delta=0.1)
            self.assertEqual(len(transcript_times), 2)
            for transcript_time in transcript_times:
                self.assertAlmostEqual(transcript_time, 1.3, delta=0.0001)

    @unittest.skipUnless(FFMPEG and FFPROBE, "ffmpeg and ffprobe are required")
    def test_audio_only_sources_become_aligned_aac_playback(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            microphone = root / "microphone.m4a"
            incoming = root / "incoming.m4a"
            # v2 records a mono microphone and stereo incoming audio. Each file
            # has its own AAC priming and container start.
            for path, start, frequency, container_offset, layout in (
                (microphone, 1.1, 1000, 0.05, "mono"),
                (incoming, 0.9, 700, 0.12, "stereo"),
            ):
                subprocess.run([
                    FFMPEG, "-v", "error", "-f", "lavfi", "-i",
                    f"aevalsrc=if(between(t\\,{start}\\,{start + 0.1})\\,"
                    f"0.8*sin(2*PI*{frequency}*t)\\,0):s=48000:d=2:c={layout}",
                    "-af", f"asetpts=PTS+{container_offset}/TB", "-c:a", "aac", "-y", str(path),
                ], check=True, capture_output=True)

            files = (
                VerifiedFile(microphone.name, microphone.stat().st_size, "0" * 64, "microphone_audio"),
                VerifiedFile(incoming.name, incoming.stat().st_size, "0" * 64, "incoming_audio"),
            )
            source_hashes = {
                path: hashlib.sha256(path.read_bytes()).hexdigest()
                for path in (microphone, incoming)
            }
            manifest = SimpleNamespace(
                files=files,
                metadata={"tracks": {"microphone": {"firstOffset": 0.2}, "incoming": {"firstOffset": 0.4}}},
                meeting_id="11111111-1111-4111-8111-111111111111",
                revision=1,
            )
            output = create_playback(root, manifest)
            self.assertEqual(output, root / "playback" / "meeting.mp4")
            self.assertEqual(
                {path: hashlib.sha256(path.read_bytes()).hexdigest() for path in source_hashes},
                source_hashes,
            )

            streams = json.loads(subprocess.run([
                FFPROBE, "-v", "error", "-show_entries", "stream=codec_type,codec_name",
                "-of", "json", str(output),
            ], check=True, capture_output=True, text=True).stdout)["streams"]
            self.assertEqual(streams, [{"codec_name": "aac", "codec_type": "audio"}])

            silencedetect = subprocess.run([
                FFMPEG, "-hide_banner", "-i", str(output), "-af",
                "silencedetect=noise=-30dB:d=0.05", "-f", "null", "-",
            ], check=True, capture_output=True, text=True).stderr
            beep_time = float(re.search(r"silence_end: ([0-9.]+)", silencedetect).group(1))
            self.assertAlmostEqual(beep_time, 1.3, delta=0.1)

            class FakeTranscriber:
                def transcribe(self, _path: Path, origin: str, *, single_speaker: bool = False):
                    start = 1.1 if origin == "microphone" else 0.9
                    return [{"start": start, "end": start + 0.1, "text": "beep"}]

            transcript = TranscriptProcessor(FakeTranscriber()).process(root, manifest)
            self.assertEqual([round(turn["start"], 4) for turn in transcript["turns"]], [1.3, 1.3])

            # The receipt and a real AAC probe let a retry keep the same file.
            inode = output.stat().st_ino
            self.assertEqual(create_playback(root, manifest), output)
            self.assertEqual(output.stat().st_ino, inode)


if __name__ == "__main__":
    unittest.main()
