"""Lazy optional faster-whisper and pyannote adapter for Bruce."""

from __future__ import annotations

import json
import math
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import uuid
from importlib.metadata import PackageNotFoundError, version
from pathlib import Path
from typing import Any

from .durable_files import atomic_write_bytes, atomic_write_text
from .manifest import verify_incoming
from .processing import TranscriptProcessor, timeline_offset
from .queue import Job
from .speakers import SpeakerRegistry
from .speaker_evidence import refresh_speaker_matches


PLAYBACK_PATH = "playback/meeting.mp4"
PLAYBACK_RECEIPT_PATH = "playback/meeting-playback.json"
PLAYBACK_RECIPE_VERSION = 2
RESERVED_GENERATED_NAMESPACES = frozenset({"playback", "transcripts"})
DIARIZATION_SAMPLE_RATE = 16000


def _timeout(name: str, default: float) -> float:
    """Bound every ffmpeg/ffprobe call so one bad file cannot hang the job."""
    value = float(os.environ.get(name, str(default)))
    if not math.isfinite(value) or value <= 0:
        raise RuntimeError(f"{name} must be a positive number of seconds.")
    return value


def _probe_timeout() -> float:
    return _timeout("MEETING_ARCHIVE_FFPROBE_TIMEOUT_SECONDS", 30)


def _check_diarization_budget(sample_count: int) -> None:
    estimated_waveform_bytes = sample_count * 4
    memory_limit = int(
        os.environ.get(
            "MEETING_ARCHIVE_MAX_DIARIZATION_MEMORY_BYTES",
            str(1536 * 1024 * 1024),
        ),
    )
    if memory_limit <= 0:
        raise RuntimeError("MEETING_ARCHIVE_MAX_DIARIZATION_MEMORY_BYTES must be positive.")
    if estimated_waveform_bytes > memory_limit:
        hours = sample_count / DIARIZATION_SAMPLE_RATE / 3600
        raise RuntimeError(
            f"The {hours:.1f} hour track needs about {estimated_waveform_bytes} bytes "
            f"for diarization, above the {memory_limit}-byte memory budget. "
            "Chunked diarization is not implemented yet; the complete source remains queued.",
        )


class WhisperPyannoteTranscriber:
    def __init__(self) -> None:
        token = os.environ.get("HF_TOKEN", "").strip()
        allow_without_diarization = os.environ.get(
            "MEETING_ARCHIVE_ALLOW_TRANSCRIPTION_WITHOUT_DIARIZATION",
            "",
        ) == "1"
        if not token and not allow_without_diarization:
            raise RuntimeError(
                "Speaker diarization is required but HF_TOKEN is unavailable. "
                "The job remains queued for retry after credential setup.",
            )
        try:
            from faster_whisper import WhisperModel
        except ImportError as error:
            raise RuntimeError("faster-whisper is not installed in the worker environment.") from error
        model = os.environ.get("MEETING_ARCHIVE_WHISPER_MODEL", "small.en")
        cpu_threads = max(
            1,
            min(4, int(os.environ.get("MEETING_ARCHIVE_WHISPER_CPU_THREADS", "2"))),
        )
        self.whisper = WhisperModel(
            model,
            device="cpu",
            compute_type="int8",
            cpu_threads=cpu_threads,
        )
        self.diarizer = None
        self.diarizer_device = "cpu"
        self.diarization_enabled = bool(token)
        self.embeddings: dict[str, list[float]] = {}
        if token:
            try:
                from pyannote.audio import Pipeline
            except ImportError as error:
                raise RuntimeError("pyannote.audio is not installed in the worker environment.") from error
            self.diarizer = Pipeline.from_pretrained(
                os.environ.get("MEETING_ARCHIVE_DIARIZATION_MODEL", "pyannote/speaker-diarization-community-1"),
                token=token,
            )
            self._move_diarizer(diarization_device(os.environ.get("MEETING_ARCHIVE_DIARIZATION_DEVICE"), _mps_available()))

    def transcribe(
        self,
        path: Path,
        channel_origin: str,
        *,
        single_speaker: bool = False,
    ) -> list[dict[str, Any]]:
        segments, _ = self.whisper.transcribe(str(path), vad_filter=True)
        turns = [
            {"start": float(item.start), "end": float(item.end), "text": item.text.strip()}
            for item in segments if item.text.strip()
        ]
        # A channel with no transcribed speech has nothing to label, so skip
        # decoding it again and loading audio for pyannote.
        if self.diarizer is None or not turns:
            return turns
        if single_speaker:
            return self._label_one_speaker(path, channel_origin, turns)
        output = self._diarize_without_torchcodec(path)
        annotation = getattr(output, "exclusive_speaker_diarization", None) or getattr(
            output, "speaker_diarization", output,
        )
        speaker_turns = []
        if hasattr(annotation, "itertracks"):
            speaker_turns = [
                (float(turn.start), float(turn.end), str(speaker))
                for turn, _track, speaker in annotation.itertracks(yield_label=True)
            ]
        # community-1 exposes one embedding per diarized speaker. Reuse those
        # outputs instead of loading a second model alongside the pipeline on
        # Bruce's 8 GB machine.
        raw_embeddings = getattr(output, "speaker_embeddings", {})
        # pyannote 4 orders this array by speaker_diarization.labels(), even
        # when exclusive diarization is used for the turn timeline.
        embedding_annotation = getattr(output, "speaker_diarization", annotation)
        self.embeddings.update(
            extract_speaker_embeddings(raw_embeddings, embedding_annotation, channel_origin),
        )
        for turn in turns:
            overlaps = [
                (max(0.0, min(turn["end"], end) - max(turn["start"], start)), speaker)
                for start, end, speaker in speaker_turns
            ]
            if overlaps and max(overlaps)[0] > 0:
                turn["speaker"] = f"{channel_origin}:{max(overlaps)[1]}"
        return turns

    def _label_one_speaker(
        self,
        path: Path,
        channel_origin: str,
        turns: list[dict[str, Any]],
    ) -> list[dict[str, Any]]:
        speaker = f"{channel_origin}:SPEAKER_00"
        # pyannote runs once, held to one speaker, only for that speaker's
        # centroid. It is the same kind of embedding the voice profiles were
        # enrolled from, so matching can still name the speaker. Its timeline
        # is not used: every transcribed turn belongs to the one speaker.
        output = self._diarize_without_torchcodec(path, num_speakers=1)
        embeddings = list(extract_speaker_embeddings(
            getattr(output, "speaker_embeddings", {}),
            getattr(output, "speaker_diarization", output),
            channel_origin,
        ).values())
        if len(embeddings) == 1:
            self.embeddings[speaker] = embeddings[0]
        for turn in turns:
            turn["speaker"] = speaker
        return turns

    def _diarize_without_torchcodec(self, path: Path, **options):
        """Decode with ffmpeg 8, then pass a waveform so pyannote skips torchcodec."""
        ffmpeg = find_executable("ffmpeg")
        if ffmpeg is None:
            raise RuntimeError("ffmpeg is required for speaker diarization.")
        scratch = Path(os.environ.get("MEETING_ARCHIVE_SCRATCH", tempfile.gettempdir()))
        scratch.mkdir(parents=True, exist_ok=True)
        descriptor, raw_name = tempfile.mkstemp(prefix="meeting-audio-", suffix=".s16le", dir=scratch)
        os.close(descriptor)
        raw_path = Path(raw_name)
        try:
            subprocess.run(
                [ffmpeg, "-v", "error", "-threads", "1", "-i", str(path), "-vn", "-ac", "1", "-ar", "16000", "-f", "s16le", "-y", str(raw_path)],
                check=True,
                timeout=_timeout("MEETING_ARCHIVE_MEDIA_DECODE_TIMEOUT_SECONDS", 7200),
            )
            # Backstop for the ffprobe estimate checked before Whisper ran.
            _check_diarization_budget(raw_path.stat().st_size // 2)
            import numpy as np
            import torch

            torch.set_num_threads(max(1, min(4, int(os.environ.get("MEETING_ARCHIVE_TORCH_THREADS", "2")))))
            samples = np.memmap(raw_path, mode="c", dtype="<i2")
            waveform = torch.from_numpy(samples).to(torch.float32).div_(32768.0).unsqueeze(0)
            return self._run_diarizer(waveform, **options)
        finally:
            raw_path.unlink(missing_ok=True)

    def _run_diarizer(self, waveform, **options):
        """Diarize on the chosen device, falling back to the CPU once if the GPU fails."""
        try:
            return diarize_waveform(self.diarizer, waveform, 16000, **options)
        except Exception as error:
            if self.diarizer_device == "cpu":
                raise
            print(f"Diarization on {self.diarizer_device} failed ({type(error).__name__}); retrying on the CPU.", file=sys.stderr)
            self._move_diarizer("cpu")
            return diarize_waveform(self.diarizer, waveform, 16000, **options)

    def _move_diarizer(self, device: str) -> None:
        if device == self.diarizer_device:
            return
        try:
            try:
                import torch

                target = torch.device(device)
            except ImportError:
                target = device
            self.diarizer.to(target)
            self.diarizer_device = device
        except Exception as error:
            # The CPU always works, just slower, so a GPU problem never fails a job.
            print(f"Diarization stays on {self.diarizer_device} ({type(error).__name__}).", file=sys.stderr)


def diarization_device(preference: str | None, mps_available: bool) -> str:
    """Where pyannote runs. On Bruce's M1 the GPU gave identical turns about 8x
    faster than two CPU threads: a 20 minute track took 3.3 minutes instead of
    23.5, which was most of a meeting's processing time.
    """
    choice = (preference or "auto").strip().lower()
    if choice in ("auto", "mps") and mps_available:
        return "mps"
    return "cpu"


def _mps_available() -> bool:
    try:
        import torch

        return bool(torch.backends.mps.is_available())
    except Exception:
        return False


def diarize_waveform(pipeline, waveform, sample_rate: int, **options):
    return pipeline({"waveform": waveform, "sample_rate": sample_rate}, **options)


def process(archive_directory: Path, job: Job) -> None:
    """CLI processor callable. Outputs are versioned and source files stay untouched."""
    manifest = verify_incoming(archive_directory)
    if (
        job.meeting_id != manifest.meeting_id
        or job.manifest_revision != manifest.revision
        or job.manifest_sha256 != manifest.manifest_sha256
    ):
        # The queue claim is the authority for which immutable archive revision
        # this worker may process. Refuse a changed or misrouted directory before
        # creating generated paths or loading either model.
        raise RuntimeError("Claimed job does not match the verified archive manifest.")
    _assert_generated_namespaces_unowned(manifest)
    output = _ensure_real_generated_directory(
        archive_directory,
        ("transcripts", f"v{job.manifest_revision}"),
    )
    json_path = output / "transcript.json"
    if json_path.is_file():
        try:
            existing = json.loads(json_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise RuntimeError(f"Existing transcript checkpoint is unreadable: {error}") from error
        if (
            existing.get("meeting_id") != manifest.meeting_id
            or existing.get("manifest_revision") != manifest.revision
            or existing.get("processing", {}).get("manifest_sha256") != manifest.manifest_sha256
        ):
            raise RuntimeError("Existing transcript provenance does not match this manifest.")
        # transcript.json is the processing receipt. Observations are committed
        # before that receipt, while these derived views can always be rebuilt.
        _refresh_confirmed_names(existing, os.environ.get("MEETING_ARCHIVE_WORKER_DB"))
        _write_transcript_artifacts(output, existing)
        create_playback(archive_directory, manifest)
        return
    if os.environ.get("HF_TOKEN", "").strip():
        # Fail an over-budget track in seconds, not after a full Whisper pass.
        for item in manifest.files:
            if TranscriptProcessor.CHANNEL_KINDS.get(item.kind):
                duration = probe_duration(archive_directory / item.path)
                if duration is not None:
                    _check_diarization_budget(math.ceil(duration * DIARIZATION_SAMPLE_RATE))
    transcriber = WhisperPyannoteTranscriber()
    offsets = {}
    for item in manifest.files:
        origin = TranscriptProcessor.CHANNEL_KINDS.get(item.kind)
        if origin:
            first = TranscriptProcessor.metadata_offset(manifest, origin)
            offsets[origin] = timeline_offset(first, probe_start_time(archive_directory / item.path))
    result = TranscriptProcessor(transcriber, offsets).process(archive_directory, manifest)
    result["processing"] = {
        "manifest_sha256": manifest.manifest_sha256,
        "whisper_model": os.environ.get("MEETING_ARCHIVE_WHISPER_MODEL", "small.en"),
        "diarization_model": os.environ.get(
            "MEETING_ARCHIVE_DIARIZATION_MODEL",
            "pyannote/speaker-diarization-community-1",
        ),
        "diarization_status": "enabled" if transcriber.diarization_enabled else "explicitly_disabled",
    }
    try:
        result["processing"]["pyannote_audio_version"] = version("pyannote.audio")
    except PackageNotFoundError:
        result["processing"]["pyannote_audio_version"] = "unavailable"
    embedding_model_id = (
        f"{result['processing']['diarization_model']}@"
        f"{result['processing']['pyannote_audio_version']}"
    )
    worker_db = os.environ.get("MEETING_ARCHIVE_WORKER_DB")
    if worker_db:
        registry = SpeakerRegistry(worker_db)
        for speaker_id, embedding in transcriber.embeddings.items():
            registry.save_observation(
                manifest.meeting_id,
                manifest.revision,
                speaker_id,
                embedding,
                embedding_model_id,
            )
        refresh_speaker_matches(result, registry)
        # SQLite commits each observation before transcript.json becomes the
        # durable processing receipt used to skip expensive model work.
        result["processing"]["speaker_observations_committed"] = True
    else:
        result["processing"]["speaker_observations_committed"] = False
    # The playback encode needs no speech model. Release those first so Bruce
    # does not keep both workloads resident on its 8 GB machine.
    del transcriber
    _write_transcript_artifacts(output, result)
    create_playback(archive_directory, manifest)


def _refresh_confirmed_names(result: dict[str, Any], worker_db: str | None) -> None:
    if not worker_db:
        return
    registry = SpeakerRegistry(worker_db)
    refresh_speaker_matches(result, registry)


def render_markdown(result: dict[str, Any]) -> str:
    lines = ["# Transcript", ""]
    for turn in result.get("turns", []):
        label = turn.get("name", turn.get("speaker", turn["channel_origin"]))
        lines.append(f"- **{label}** [{turn['start']:.1f}s] {turn['text']}")
    return "\n".join(lines) + "\n"


def _write_transcript_artifacts(output: Path, result: dict[str, Any]) -> None:
    """Rebuild Markdown first and commit JSON last as the durable receipt."""

    output.mkdir(parents=True, exist_ok=True)
    markdown_path = output / "transcript.md"
    markdown = render_markdown(result)
    if not markdown_path.is_file() or markdown_path.read_text(encoding="utf-8") != markdown:
        atomic_write_text(markdown_path, markdown)
    json_path = output / "transcript.json"
    encoded = (json.dumps(result, sort_keys=True, ensure_ascii=False, indent=2) + "\n").encode()
    if not json_path.is_file() or json_path.read_bytes() != encoded:
        atomic_write_bytes(json_path, encoded)


def usable_embedding(values: list[float]) -> bool:
    """Whether a speaker embedding is a real voice sample.

    pyannote gives a speaker heard too briefly to keep any chunk embedding a
    NaN centroid, and pads a speaker it could not cluster with zeros. That
    speaker then has no embedding, as with very short speech, rather than
    failing the whole job.
    """
    return bool(values) and all(math.isfinite(value) for value in values) and any(
        value != 0 for value in values
    )


def extract_speaker_embeddings(raw_embeddings, annotation, channel_origin: str) -> dict[str, list[float]]:
    labels = annotation.labels() if hasattr(annotation, "labels") else []
    items = raw_embeddings.items() if isinstance(raw_embeddings, dict) else zip(
        labels,
        [] if raw_embeddings is None else raw_embeddings,
    )
    result = {}
    for speaker, raw in items:
        values = raw.tolist() if hasattr(raw, "tolist") else list(raw)
        while values and isinstance(values[0], list):
            values = values[0]
        embedding = [float(value) for value in values]
        if usable_embedding(embedding):
            result[f"{channel_origin}:{speaker}"] = embedding
    return result


def create_playback(archive_directory: Path, manifest) -> Path | None:
    """Build browser-compatible playback without touching preserved sources.

    A bundle with video gets H.264 video. An audio-only bundle, as every v2
    recording is, gets an AAC-only MP4, so review excerpts and the viewer can
    still play it.
    """
    _assert_generated_namespaces_unowned(manifest)
    video = next((item for item in manifest.files if item.kind == "video"), None)
    audio = [item for item in manifest.files if item.kind in ("microphone_audio", "incoming_audio")]
    if not audio:
        return None
    playback_directory = _ensure_real_generated_directory(archive_directory, ("playback",))
    output = playback_directory / "meeting.mp4"
    receipt_path = playback_directory / "meeting-playback.json"
    recipe = _playback_recipe(manifest, video, audio)
    playback_is_current = _playback_is_aac if video is None else _playback_is_h264
    if _is_regular_non_symlink(output) and _playback_receipt_matches(receipt_path, recipe) and playback_is_current(output):
        return output
    ffmpeg = find_executable("ffmpeg")
    if ffmpeg is None:
        raise RuntimeError("ffmpeg is required to create the playback asset.")
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.parent / f".{output.name}.{uuid.uuid4().hex}.part.mp4"
    inputs = audio if video is None else [video, *audio]
    command = [ffmpeg, "-hide_banner", "-loglevel", "error", "-threads", "2"]
    for item in inputs:
        command.extend(["-i", str(archive_directory / item.path)])

    # AVAssetWriter uses a shared host-clock origin, recorded as firstOffset in
    # metadata. Decode away each file's independent AAC priming/edit list,
    # normalize that decoded track to zero, then apply the capture offset once.
    filters, audio_map = _aligned_audio_filters(manifest, audio, first_input=len(inputs) - len(audio))
    try:
        if video is None:
            try:
                subprocess.run(
                    command + [
                        "-filter_complex", ";".join(filters), "-map", audio_map,
                        "-c:a", "aac", "-movflags", "+faststart", "-y", str(temporary),
                    ],
                    check=True,
                    capture_output=True,
                    text=True,
                    timeout=_timeout("MEETING_ARCHIVE_PLAYBACK_TIMEOUT_SECONDS", 4 * 3600),
                )
            except subprocess.CalledProcessError as error:
                detail = (error.stderr or "").strip()[-500:]
                raise RuntimeError(
                    f"ffmpeg could not create the audio playback: {detail or 'no error output'}",
                ) from error
        else:
            video_offset = _playback_track_offset(manifest, "video")
            filters.insert(0, f"[0:v:0]setpts=PTS-STARTPTS+{_ffmpeg_number(video_offset)}/TB[v]")
            base = command + [
                "-filter_complex", ";".join(filters),
                "-map", "[v]", "-map", audio_map,
                "-pix_fmt", "yuv420p", "-tag:v", "avc1", "-fps_mode:v", "passthrough",
                "-profile:v", "high", "-level:v", "4.1",
                "-b:v", "4M", "-maxrate:v", "6M", "-bufsize:v", "8M",
                "-threads:v", "2", "-c:a", "aac", "-movflags", "+faststart", "-y",
            ]
            last_error: subprocess.CalledProcessError | None = None
            encoders = ("h264_videotoolbox",) if os.environ.get(
                "MEETING_ARCHIVE_REQUIRE_HARDWARE_H264", ""
            ) == "1" else ("h264_videotoolbox", "libx264")
            for encoder in encoders:
                temporary.unlink(missing_ok=True)
                try:
                    subprocess.run(
                        base + ["-c:v", encoder, str(temporary)],
                        check=True,
                        capture_output=True,
                        text=True,
                        timeout=_timeout("MEETING_ARCHIVE_PLAYBACK_TIMEOUT_SECONDS", 4 * 3600),
                    )
                    last_error = None
                    break
                except subprocess.CalledProcessError as error:
                    last_error = error
            if last_error is not None:
                raise RuntimeError("No working H.264 playback encoder is available.") from last_error
        os.replace(temporary, output)
        atomic_write_text(
            receipt_path,
            json.dumps(recipe, ensure_ascii=False, sort_keys=True, indent=2) + "\n",
        )
    finally:
        temporary.unlink(missing_ok=True)
    return output


def _aligned_audio_filters(manifest, audio, first_input: int) -> tuple[list[str], str]:
    """Place each audio input on the capture clock and mix them into one track."""
    filters = []
    labels = []
    for index, item in enumerate(audio, start=first_input):
        origin = TranscriptProcessor.CHANNEL_KINDS[item.kind]
        offset = _playback_track_offset(manifest, origin)
        label = f"a{index}"
        delay_milliseconds = _ffmpeg_number(offset * 1_000)
        filters.append(
            f"[{index}:a:0]asetpts=PTS-STARTPTS,adelay={delay_milliseconds}:all=1[{label}]"
        )
        labels.append(f"[{label}]")
    if len(labels) == 1:
        return filters, labels[0]
    filters.append(f"{''.join(labels)}amix=inputs={len(labels)}:duration=longest[a]")
    return filters, "[a]"


def _assert_generated_namespaces_unowned(manifest) -> None:
    for item in manifest.files:
        namespace = item.path.split("/", 1)[0].casefold()
        if namespace in RESERVED_GENERATED_NAMESPACES:
            raise RuntimeError(
                f"accepted source {item.path} occupies reserved generated namespace {namespace}/."
            )


def _is_regular_non_symlink(path: Path) -> bool:
    try:
        mode = path.lstat().st_mode
    except OSError:
        return False
    return stat.S_ISREG(mode)


def _ensure_real_generated_directory(root: Path, components: tuple[str, ...]) -> Path:
    current = root
    for component in components:
        current = current / component
        try:
            current.mkdir()
        except FileExistsError:
            pass
        try:
            mode = current.lstat().st_mode
        except OSError as error:
            raise RuntimeError(f"Generated path {current} is not available: {error}") from error
        if not stat.S_ISDIR(mode):
            relative = current.relative_to(root)
            raise RuntimeError(f"Generated path {relative} must be a real directory, not a symlink or file.")
    return current


def _playback_recipe(manifest, video, audio) -> dict[str, Any]:
    sources = audio if video is None else [video, *audio]
    offsets = {} if video is None else {"video": _playback_track_offset(manifest, "video")}
    for item in audio:
        origin = TranscriptProcessor.CHANNEL_KINDS[item.kind]
        offsets[origin] = _playback_track_offset(manifest, origin)
    return {
        "schema_version": 1,
        "recipe_version": PLAYBACK_RECIPE_VERSION,
        "sources": [
            {
                "path": item.path,
                "size_bytes": item.size_bytes,
                "sha256": item.sha256,
                "kind": item.kind,
            }
            for item in sources
        ],
        "first_offsets": offsets,
    }


def _playback_receipt_matches(path: Path, expected: dict[str, Any]) -> bool:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return False
    return value == expected


def _playback_track_offset(manifest, track: str) -> float:
    metadata = getattr(manifest, "metadata", {})
    tracks = metadata.get("tracks", {}) if isinstance(metadata, dict) else {}
    raw = tracks.get(track, {}) if isinstance(tracks, dict) else {}
    value = raw.get("firstOffset", raw.get("first_offset", 0.0)) if isinstance(raw, dict) else 0.0
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0:
        raise ValueError(f"Invalid {track} firstOffset in metadata.json.")
    return float(value)


def _ffmpeg_number(value: float) -> str:
    return f"{value:.9f}".rstrip("0").rstrip(".") or "0"


def _playback_is_h264(path: Path) -> bool:
    return _first_stream_codec_is(path, "v:0", "h264")


def _playback_is_aac(path: Path) -> bool:
    """An audio-only playback is current when its audio stream is AAC."""
    return _first_stream_codec_is(path, "a:0", "aac")


def _first_stream_codec_is(path: Path, stream: str, codec: str) -> bool:
    ffprobe = find_executable("ffprobe")
    if ffprobe is None:
        return True
    try:
        completed = subprocess.run(
            [
                ffprobe, "-v", "error", "-select_streams", stream,
                "-show_entries", "stream=codec_name", "-of", "default=nw=1:nk=1", str(path),
            ],
            check=True,
            capture_output=True,
            text=True,
            timeout=_probe_timeout(),
        )
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return False
    return completed.stdout.strip().lower() == codec


def probe_start_time(path: Path) -> float | None:
    ffprobe = find_executable("ffprobe")
    if ffprobe is None:
        return None
    completed = subprocess.run(
        [ffprobe, "-v", "error", "-show_entries", "format=start_time", "-of", "default=nw=1:nk=1", str(path)],
        check=True,
        capture_output=True,
        text=True,
        timeout=_probe_timeout(),
    )
    value = completed.stdout.strip()
    return float(value) if value and value != "N/A" else None


def probe_duration(path: Path) -> float | None:
    """Container duration in seconds, or None when ffprobe cannot say."""
    ffprobe = find_executable("ffprobe")
    if ffprobe is None:
        return None
    try:
        completed = subprocess.run(
            [ffprobe, "-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1:nk=1", str(path)],
            check=True,
            capture_output=True,
            text=True,
            timeout=_probe_timeout(),
        )
        value = float(completed.stdout.strip())
    except (OSError, ValueError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        # The decode-time check still guards diarization memory.
        return None
    return value if math.isfinite(value) and value > 0 else None


def find_executable(name: str) -> str | None:
    found = shutil.which(name)
    if found:
        return found
    for root in (Path("/opt/homebrew/bin"), Path("/usr/local/bin"), Path.home() / ".local/bin"):
        candidate = root / name
        if candidate.is_file():
            return str(candidate)
    return None
