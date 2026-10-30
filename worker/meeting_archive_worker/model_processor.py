"""Lazy optional faster-whisper, Nemotron and pyannote adapter for Bruce."""

from __future__ import annotations

import contextlib
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
PYANNOTE_PIPELINE = "pyannote/speaker-diarization-community-1"
NEMOTRON_MODEL = "nvidia/Nemotron-3-Diarization"
#: large-v3-turbo gets names and punctuation right more often than small.en.
#: On Bruce's CPU it takes about 0.21x the audio's length (small.en 0.11x) and
#: peaks at about 2.1 GB (small.en 1.4 GB), measured 30 Oct 2026.
DEFAULT_WHISPER_MODEL = "large-v3-turbo"
#: Nemotron 3 tracks at most this many speakers. A track that fills every slot
#: probably had more people, so pyannote, which has no cap, diarizes it instead.
NEMOTRON_MAX_SPEAKERS = 8


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
        model = os.environ.get("MEETING_ARCHIVE_WHISPER_MODEL", DEFAULT_WHISPER_MODEL)
        # The large models are multilingual. Calls are in English, and guessing
        # the language from a quiet opening can transcribe a whole track in
        # the wrong one, so it is fixed unless set to "auto".
        language = os.environ.get("MEETING_ARCHIVE_WHISPER_LANGUAGE", "en").strip().lower()
        self.whisper_language = None if language == "auto" else language
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
        self.nemotron: NemotronDiarizer | None = None
        #: Which diarizer labelled each multi-speaker track, for the receipt.
        self.track_diarizers: dict[str, str] = {}
        if token:
            try:
                from pyannote.audio import Pipeline
            except ImportError as error:
                raise RuntimeError("pyannote.audio is not installed in the worker environment.") from error
            # pyannote stays loaded even when Nemotron does the labelling: its
            # embedding model makes the voice samples the profiles are matched
            # on, and it diarizes any track Nemotron can't.
            self.diarizer = Pipeline.from_pretrained(
                os.environ.get("MEETING_ARCHIVE_DIARIZATION_MODEL", PYANNOTE_PIPELINE),
                token=token,
            )
            self._move_diarizer(diarization_device(os.environ.get("MEETING_ARCHIVE_DIARIZATION_DEVICE"), _mps_available()))
            self.nemotron = NemotronDiarizer.from_environment()

    def transcribe(
        self,
        path: Path,
        channel_origin: str,
        *,
        single_speaker: bool = False,
    ) -> list[dict[str, Any]]:
        # Word times are only needed to split a line between speakers, and
        # make Whisper slower, so a track with at most one speaker skips them.
        by_word = self.diarizer is not None and not single_speaker
        options = {"vad_filter": True, "word_timestamps": by_word}
        if getattr(self, "whisper_language", None):
            options["language"] = self.whisper_language
        segments, _ = self.whisper.transcribe(str(path), **options)
        segments = [item for item in segments if item.text.strip()]
        turns = [
            {"start": float(item.start), "end": float(item.end), "text": item.text.strip()}
            for item in segments
        ]
        # A channel with no transcribed speech has nothing to label, so skip
        # decoding it again and loading audio for pyannote.
        if self.diarizer is None or not turns:
            return turns
        if single_speaker:
            return self._label_one_speaker(path, channel_origin, turns)
        speaker_turns = self._nemotron_turns(path, channel_origin)
        if speaker_turns is None:
            speaker_turns = self._pyannote_turns(path, channel_origin)
        turns = [turn for item in segments for turn in segment_turns(item, speaker_turns)]
        for turn in turns:
            if "speaker" in turn:
                turn["speaker"] = f"{channel_origin}:{turn['speaker']}"
        return turns

    def _nemotron_turns(self, path: Path, channel_origin: str) -> list[tuple[float, float, str]] | None:
        """Nemotron's speaker turns and voice samples, or None to use pyannote.

        Nemotron splits one person into two far less often than pyannote did
        (the 30 Oct bake-off in the README), but gives no voice embeddings, so
        each speaker's sample comes from pyannote's own embedding model over
        that speaker's turns. That keeps the samples comparable with every
        voice profile enrolled before the switch.
        """
        nemotron = getattr(self, "nemotron", None)
        if nemotron is None:
            return None
        try:
            speaker_turns = nemotron.speaker_turns(path)
        except Exception as error:
            print(f"Nemotron diarization failed ({error}); pyannote labels the {channel_origin} track.", file=sys.stderr)
            return None
        if len({speaker for _start, _end, speaker in speaker_turns}) >= NEMOTRON_MAX_SPEAKERS:
            print(
                f"Nemotron used all {NEMOTRON_MAX_SPEAKERS} speaker slots on the {channel_origin} track; "
                "pyannote labels it instead.",
                file=sys.stderr,
            )
            return None
        with self._decoded_samples(path) as samples:
            centroids = self._run_on_device(
                lambda: speaker_centroids(self._embed_window, samples, DIARIZATION_SAMPLE_RATE, speaker_turns),
            )
        self.embeddings.update({f"{channel_origin}:{speaker}": vector for speaker, vector in centroids.items()})
        self.track_diarizers[channel_origin] = "nemotron"
        return speaker_turns

    def _pyannote_turns(self, path: Path, channel_origin: str) -> list[tuple[float, float, str]]:
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
        if hasattr(self, "track_diarizers"):
            self.track_diarizers[channel_origin] = "pyannote"
        return speaker_turns

    def _embed_window(self, chunk, mask):
        """pyannote's speaker embedding for one window, counting only the masked frames."""
        import torch

        waveform = torch.from_numpy(chunk)[None, None]
        weights = torch.from_numpy(mask.astype("float32"))[None]
        return self.diarizer._embedding(waveform, masks=weights)[0]

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
        with self._decoded_samples(path) as samples:
            import torch

            waveform = torch.from_numpy(samples).to(torch.float32).div_(32768.0).unsqueeze(0)
            return self._run_diarizer(waveform, **options)

    @contextlib.contextmanager
    def _decoded_samples(self, path: Path):
        """The track as 16 kHz mono int16 samples, memory-mapped from scratch."""
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
            yield np.memmap(raw_path, mode="c", dtype="<i2")
        finally:
            raw_path.unlink(missing_ok=True)

    def _run_diarizer(self, waveform, **options):
        return self._run_on_device(lambda: diarize_waveform(self.diarizer, waveform, 16000, **options))

    def _run_on_device(self, work):
        """Run pyannote work on the chosen device, falling back to the CPU once if the GPU fails."""
        try:
            return work()
        except Exception as error:
            if self.diarizer_device == "cpu":
                raise
            print(f"Diarization on {self.diarizer_device} failed ({type(error).__name__}); retrying on the CPU.", file=sys.stderr)
            self._move_diarizer("cpu")
            if self.diarizer_device != "cpu":
                # Still on the device that just failed, so don't run it there
                # again. The job retries with backoff in a fresh process.
                raise
            return work()

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
            # The CPU always works, just slower, so a GPU that won't take the
            # pipeline never fails a job.
            print(f"Diarization stays on {self.diarizer_device} ({type(error).__name__}).", file=sys.stderr)


#: A run of this many words or fewer, shorter than the duration below, between
#: two stretches of the same speaker is a backchannel or a diarization blip, not
#: a turn of its own.
SLIVER_MAX_WORDS = 2
SLIVER_MAX_SECONDS = 0.3


def speaker_at(speaker_turns: list[tuple[float, float, str]], moment: float) -> str | None:
    """The diarization speaker talking at a moment, else the nearest turn's."""
    active = [turn for turn in speaker_turns if turn[0] <= moment <= turn[1]]
    if active:
        # With overlapping speech the one who started most recently is the
        # more likely owner of this word.
        return max(active, key=lambda turn: turn[0])[2]
    if not speaker_turns:
        return None
    return min(speaker_turns, key=lambda turn: min(abs(moment - turn[0]), abs(moment - turn[1])))[2]


def _majority_speaker(start: float, end: float, speaker_turns: list[tuple[float, float, str]]) -> str | None:
    overlaps = [
        (max(0.0, min(end, turn_end) - max(start, turn_start)), speaker)
        for turn_start, turn_end, speaker in speaker_turns
    ]
    return max(overlaps)[1] if overlaps and max(overlaps)[0] > 0 else None


def segment_turns(segment, speaker_turns: list[tuple[float, float, str]]) -> list[dict[str, Any]]:
    """Turns for one Whisper segment, split wherever the speaker changes.

    Each word goes to the speaker active at its midpoint, so a line where
    someone else cuts in is no longer given whole to whoever spoke most of it.
    Speaker labels here are pyannote's own, with no channel prefix.
    """
    text = segment.text.strip()
    if not text:
        return []
    words = [word for word in (getattr(segment, "words", None) or []) if word.word.strip()]
    if not words:
        turn: dict[str, Any] = {"start": float(segment.start), "end": float(segment.end), "text": text}
        speaker = _majority_speaker(turn["start"], turn["end"], speaker_turns)
        if speaker is not None:
            turn["speaker"] = speaker
        return [turn]
    # Runs of consecutive words by one speaker, as [speaker, words].
    runs: list[list[Any]] = []
    for word in words:
        speaker = speaker_at(speaker_turns, (float(word.start) + float(word.end)) / 2)
        if runs and runs[-1][0] == speaker:
            runs[-1][1].append(word)
        else:
            runs.append([speaker, [word]])
    index = 1
    while index < len(runs) - 1:
        run_words = runs[index][1]
        if (
            runs[index - 1][0] == runs[index + 1][0]
            and len(run_words) <= SLIVER_MAX_WORDS
            and float(run_words[-1].end) - float(run_words[0].start) < SLIVER_MAX_SECONDS
        ):
            runs[index - 1][1] += run_words + runs[index + 1][1]
            del runs[index:index + 2]
        else:
            index += 1
    if len(runs) == 1:
        # Nobody cut in, so keep Whisper's own text and times.
        pieces = [(runs[0][0], float(segment.start), float(segment.end), text)]
    else:
        pieces = [
            (
                speaker,
                float(run_words[0].start),
                float(run_words[-1].end),
                "".join(word.word for word in run_words).strip(),
            )
            for speaker, run_words in runs
        ]
    turns = []
    for speaker, start, end, piece in pieces:
        turn = {"start": start, "end": end, "text": piece}
        if speaker is not None:
            turn["speaker"] = speaker
        turns.append(turn)
    return turns


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


class NemotronDiarizer:
    """Nemotron 3 Diarization on Apple Silicon, through FluidAudio's CLI.

    install-bruce.sh builds the CLI at a pinned FluidAudio commit. Its CoreML
    port matched NVIDIA's own model on the GPU for 99-100% of speech on the
    archived calls, and labels a 30 minute track in seconds on Bruce.
    """

    def __init__(self, executable: str, variant: str = "offline") -> None:
        self.executable = executable
        # "offline" is FluidAudio's most accurate preset for recorded audio.
        self.variant = variant

    @classmethod
    def from_environment(cls) -> NemotronDiarizer | None:
        if os.environ.get("MEETING_ARCHIVE_DIARIZER", "nemotron").strip().lower() != "nemotron":
            return None
        executable = os.environ.get("MEETING_ARCHIVE_NEMOTRON_CLI", "").strip()
        if not executable or not os.access(executable, os.X_OK):
            print("Nemotron's FluidAudio CLI is not installed; pyannote labels speakers.", file=sys.stderr)
            return None
        return cls(executable, os.environ.get("MEETING_ARCHIVE_NEMOTRON_VARIANT", "offline").strip() or "offline")

    def speaker_turns(self, path: Path) -> list[tuple[float, float, str]]:
        scratch = Path(os.environ.get("MEETING_ARCHIVE_SCRATCH", tempfile.gettempdir()))
        scratch.mkdir(parents=True, exist_ok=True)
        descriptor, rttm_name = tempfile.mkstemp(prefix="nemotron-", suffix=".rttm", dir=scratch)
        os.close(descriptor)
        rttm = Path(rttm_name)
        try:
            completed = subprocess.run(
                [self.executable, "nemotron3-diarize", str(path), "--variant", self.variant, "--output", str(rttm)],
                capture_output=True,
                text=True,
                timeout=_timeout("MEETING_ARCHIVE_NEMOTRON_TIMEOUT_SECONDS", 1800),
            )
            if completed.returncode != 0:
                detail = (completed.stderr or completed.stdout or "").strip()[-300:]
                raise RuntimeError(f"exit {completed.returncode}: {detail or 'no output'}")
            return read_rttm(rttm.read_text(encoding="utf-8"))
        finally:
            rttm.unlink(missing_ok=True)


def read_rttm(text: str) -> list[tuple[float, float, str]]:
    """Turns from RTTM, with FluidAudio's speaker_N renamed SPEAKER_0N like pyannote's."""
    turns = []
    for line in text.splitlines():
        fields = line.split()
        if len(fields) < 8 or fields[0] != "SPEAKER":
            continue
        start, duration, label = float(fields[3]), float(fields[4]), fields[7]
        if label.startswith("speaker_") and label[8:].isdigit():
            label = f"SPEAKER_{int(label[8:]):02d}"
        # RTTM times are in milliseconds; rounding keeps the sum from drifting.
        turns.append((start, round(start + duration, 3), label))
    return sorted(turns)


def speaker_centroids(
    embed,
    samples,
    sample_rate: int,
    speaker_turns: list[tuple[float, float, str]],
    *,
    window: float = 10.0,
    step: float = 5.0,
    min_speech: float = 2.0,
) -> dict[str, list[float]]:
    """Each speaker's voice sample: the mean embedding over windows of their speech.

    community-1 reports a speaker's embedding as the mean of its chunk
    embeddings, so this lands in the same space. A window counts a speaker
    only where nobody else is talking, and only with `min_speech` seconds of
    it, so crosstalk and a stray "yeah" don't blur the voice.
    """
    import numpy as np

    frames_per_second = 100
    total_frames = math.ceil(len(samples) / sample_rate * frames_per_second)
    speakers = sorted({speaker for _start, _end, speaker in speaker_turns})
    if not speakers or total_frames == 0:
        return {}
    activity = np.zeros((len(speakers), total_frames), dtype=bool)
    for start, end, speaker in speaker_turns:
        activity[speakers.index(speaker), int(start * frames_per_second):int(end * frames_per_second)] = True
    alone = activity & (activity.sum(axis=0) == 1)
    vectors: dict[str, list] = {speaker: [] for speaker in speakers}
    window_frames, step_frames = int(window * frames_per_second), int(step * frames_per_second)
    for first in range(0, total_frames, step_frames):
        last = min(total_frames, first + window_frames)
        chunk = None
        for index, speaker in enumerate(speakers):
            mask = alone[index, first:last]
            if mask.sum() < min_speech * frames_per_second:
                continue
            if chunk is None:
                begin, end = first * sample_rate // frames_per_second, last * sample_rate // frames_per_second
                chunk = np.asarray(samples[begin:end], dtype=np.float32) / 32768.0
            vector = np.asarray(embed(chunk, mask), dtype=np.float64).reshape(-1)
            if vector.size and np.all(np.isfinite(vector)):
                vectors[speaker].append(vector)
    result = {}
    for speaker, found in vectors.items():
        if found:
            embedding = [float(value) for value in np.mean(found, axis=0)]
            if usable_embedding(embedding):
                result[speaker] = embedding
    return result


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
    processor = TranscriptProcessor(transcriber, offsets)
    result = processor.process(archive_directory, manifest)
    if processor.echo_turns_removed:
        print(f"Removed {processor.echo_turns_removed} microphone lines that echoed the call audio.", file=sys.stderr)
    pyannote_pipeline = os.environ.get("MEETING_ARCHIVE_DIARIZATION_MODEL", PYANNOTE_PIPELINE)
    track_diarizers = getattr(transcriber, "track_diarizers", {})
    result["processing"] = {
        "manifest_sha256": manifest.manifest_sha256,
        "whisper_model": os.environ.get("MEETING_ARCHIVE_WHISPER_MODEL", DEFAULT_WHISPER_MODEL),
        "diarization_model": NEMOTRON_MODEL if "nemotron" in track_diarizers.values() else pyannote_pipeline,
        "speaker_embedding_model": pyannote_pipeline,
        "diarization_status": "enabled" if transcriber.diarization_enabled else "explicitly_disabled",
    }
    if track_diarizers:
        result["processing"]["track_diarizers"] = dict(sorted(track_diarizers.items()))
    try:
        result["processing"]["pyannote_audio_version"] = version("pyannote.audio")
    except PackageNotFoundError:
        result["processing"]["pyannote_audio_version"] = "unavailable"
    # Voice samples always come from pyannote's embedding model, whichever
    # diarizer drew the turns, so profiles enrolled before Nemotron still match.
    embedding_model_id = f"{pyannote_pipeline}@{result['processing']['pyannote_audio_version']}"
    worker_db = os.environ.get("MEETING_ARCHIVE_WORKER_DB")
    if worker_db:
        registry = SpeakerRegistry(worker_db)
        # A speaker whose every line was echo isn't anyone to name.
        heard = {turn.get("speaker") for turn in result["turns"]}
        for speaker_id, embedding in transcriber.embeddings.items():
            if speaker_id not in heard:
                continue
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
