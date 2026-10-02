"""Speaker labels and voice embeddings from the Whisper and pyannote adapter."""

from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch


WORKER_ROOT = Path(__file__).resolve().parents[1] / "worker"
sys.path.insert(0, str(WORKER_ROOT))

from meeting_archive_worker.manifest import VerifiedFile, verify_incoming  # noqa: E402
from meeting_archive_worker.model_processor import (  # noqa: E402
    WhisperPyannoteTranscriber,
    diarize_waveform,
    extract_speaker_embeddings,
    process as model_process,
)
from meeting_archive_worker.processing import (  # noqa: E402
    TranscriptProcessor,
    microphone_is_one_speaker,
)
from meeting_archive_worker.speakers import SpeakerRegistry  # noqa: E402
from test_worker import write_bundle  # noqa: E402


NAN = float("nan")
MIKE = [0.6, 0.8]
MODEL_ID = "pyannote/speaker-diarization-community-1@4.0.3"


class Annotation:
    """The parts of a pyannote annotation the adapter reads."""

    def __init__(self, turns: list[tuple[float, float, str]]):
        self.turns = turns

    def labels(self) -> list[str]:
        return sorted({label for _, _, label in self.turns})

    def itertracks(self, yield_label: bool = False):
        for start, end, label in self.turns:
            yield SimpleNamespace(start=start, end=end), None, label


def diarization(turns: list[tuple[float, float, str]], embeddings: list[list[float]]):
    return SimpleNamespace(
        speaker_diarization=Annotation(turns),
        exclusive_speaker_diarization=Annotation(turns),
        speaker_embeddings=embeddings,
    )


def channel(path) -> str:
    return "microphone" if "microphone" in Path(path).name else "incoming"


def stub_transcriber(segments: dict, outputs: dict):
    """A real adapter whose Whisper and pyannote calls return fixed results."""
    transcriber = object.__new__(WhisperPyannoteTranscriber)
    transcriber.whisper = SimpleNamespace(transcribe=lambda path, **_options: (
        [SimpleNamespace(start=start, end=end, text=text) for start, end, text in segments.get(channel(path), [])],
        None,
    ))
    transcriber.diarizer = object()
    transcriber.diarization_enabled = True
    transcriber.embeddings = {}
    calls = []

    def diarize(path, **options):
        calls.append((channel(path), options))
        return outputs[channel(path)]

    transcriber._diarize_without_torchcodec = diarize
    return transcriber, calls


def run_process(incoming: Path, transcriber, database: Path) -> None:
    verified = verify_incoming(incoming)
    job = SimpleNamespace(
        meeting_id=verified.meeting_id,
        manifest_revision=verified.revision,
        manifest_sha256=verified.manifest_sha256,
    )
    with patch.dict(os.environ, {"MEETING_ARCHIVE_WORKER_DB": str(database)}, clear=True), \
         patch("meeting_archive_worker.model_processor.WhisperPyannoteTranscriber", return_value=transcriber), \
         patch("meeting_archive_worker.model_processor.version", return_value="4.0.3"), \
         patch("meeting_archive_worker.model_processor.probe_start_time", return_value=None), \
         patch("meeting_archive_worker.model_processor.create_playback"):
        model_process(incoming, job)


def saved_transcript(incoming: Path) -> dict:
    return json.loads((incoming / "transcripts/v1/transcript.json").read_text(encoding="utf-8"))


class MicrophoneSpeakerTests(unittest.TestCase):
    def test_half_a_minute_of_incoming_speech_makes_the_microphone_one_speaker(self) -> None:
        self.assertFalse(microphone_is_one_speaker([]))
        self.assertFalse(microphone_is_one_speaker([{"start": 0.0, "end": 60.0, "text": "  "}]))
        # A stray phrase from a video, or Whisper filling silence, isn't a call.
        self.assertFalse(microphone_is_one_speaker([{"start": 2.0, "end": 3.0, "text": "Can you hear me?"}]))
        self.assertTrue(microphone_is_one_speaker([
            {"start": 0.0, "end": 1.0, "text": " "},
            {"start": 2.0, "end": 20.0, "text": "Can you hear me?"},
            {"start": 25.0, "end": 37.0, "text": "Great, let's start."},
        ]))

    def test_a_manual_recording_always_diarizes_the_microphone(self) -> None:
        call = [{"start": 0.0, "end": 120.0, "text": "A video playing on the Mac."}]
        self.assertTrue(microphone_is_one_speaker(call, source_app="us.zoom.xos"))
        self.assertFalse(microphone_is_one_speaker(call, source_app="manual"))

    def test_incoming_is_transcribed_first_and_decides_the_microphone(self) -> None:
        # The app lists the microphone before incoming in its manifest.
        files = (
            VerifiedFile("microphone.m4a", 1, "0" * 64, "microphone_audio"),
            VerifiedFile("incoming.m4a", 1, "0" * 64, "incoming_audio"),
        )
        manifest = SimpleNamespace(files=files, metadata={}, meeting_id="meeting", revision=1)
        for incoming_speech, one_speaker in ((["Morning all."], True), ([], False)):
            with self.subTest(incoming_speech=incoming_speech):
                calls = []

                class RecordingTranscriber:
                    def transcribe(self, _path, channel_origin, *, single_speaker=False):
                        calls.append((channel_origin, single_speaker))
                        texts = incoming_speech if channel_origin == "incoming" else ["Hi."]
                        end = 40.0 if channel_origin == "incoming" else 1.0
                        return [{"start": 0.0, "end": end, "text": text} for text in texts]

                result = TranscriptProcessor(RecordingTranscriber()).process(Path("archive"), manifest)

                self.assertEqual(calls, [("incoming", False), ("microphone", one_speaker)])
                self.assertEqual(
                    [source["channel_origin"] for source in result["sources"]],
                    ["microphone", "incoming"],
                )

    def test_one_speaker_microphone_labels_every_turn_and_keeps_its_voice(self) -> None:
        transcriber, calls = stub_transcriber(
            {"microphone": [(0.0, 2.0, "Hi everyone."), (3.0, 4.0, "Mm."), (9.0, 12.0, "Let's start.")]},
            # pyannote heard nothing at 3s, yet that turn is still Mike's.
            {"microphone": diarization([(0.0, 2.0, "SPEAKER_00"), (9.0, 12.0, "SPEAKER_00")], [MIKE])},
        )

        turns = transcriber.transcribe(Path("microphone.m4a"), "microphone", single_speaker=True)

        self.assertEqual(calls, [("microphone", {"num_speakers": 1})])
        self.assertEqual([turn["speaker"] for turn in turns], ["microphone:SPEAKER_00"] * 3)
        self.assertEqual(transcriber.embeddings, {"microphone:SPEAKER_00": MIKE})

    def test_speaker_count_reaches_the_pyannote_pipeline_call(self) -> None:
        calls = []

        def pipeline(audio, **options):
            calls.append((audio, options))
            return "output"

        waveform = object()
        self.assertEqual(diarize_waveform(pipeline, waveform, 16000, num_speakers=1), "output")
        self.assertEqual(calls, [({"waveform": waveform, "sample_rate": 16000}, {"num_speakers": 1})])

    def test_one_speaker_microphone_without_a_usable_voice_is_still_labelled(self) -> None:
        transcriber, _ = stub_transcriber(
            {"microphone": [(0.0, 0.4, "Yep.")]},
            {"microphone": diarization([(0.0, 0.4, "SPEAKER_00")], [[NAN, NAN]])},
        )

        turns = transcriber.transcribe(Path("microphone.m4a"), "microphone", single_speaker=True)

        self.assertEqual([turn["speaker"] for turn in turns], ["microphone:SPEAKER_00"])
        self.assertEqual(transcriber.embeddings, {})

    def test_call_makes_the_microphone_one_speaker_named_by_voice(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            incoming, _ = write_bundle(root)
            database = root / "worker.sqlite"
            registry = SpeakerRegistry(database)
            # Mike confirmed his voice on an earlier call.
            registry.save_observation("earlier-call", 1, "microphone:SPEAKER_00", MIKE, MODEL_ID)
            registry.confirm_observation("earlier-call", 1, "microphone:SPEAKER_00", "Mike Cann")
            transcriber, calls = stub_transcriber(
                {
                    "microphone": [(1.0, 3.0, "Thanks for making time."), (41.0, 42.0, "Sure.")],
                    "incoming": [(3.5, 26.0, "No worries."), (26.5, 40.0, "Hello!")],
                },
                {
                    "microphone": diarization([(1.0, 3.0, "SPEAKER_00"), (41.0, 42.0, "SPEAKER_00")], [MIKE]),
                    "incoming": diarization(
                        [(3.5, 26.0, "SPEAKER_00"), (26.5, 40.0, "SPEAKER_01")],
                        [[0.8, -0.6], [-0.8, 0.6]],
                    ),
                },
            )

            run_process(incoming, transcriber, database)

            turns = saved_transcript(incoming)["turns"]
            self.assertEqual(calls, [("incoming", {}), ("microphone", {"num_speakers": 1})])
            self.assertEqual(
                [(turn["speaker"], turn.get("name")) for turn in turns],
                [
                    ("microphone:SPEAKER_00", "Mike Cann"),
                    ("incoming:SPEAKER_00", None),
                    ("incoming:SPEAKER_01", None),
                    ("microphone:SPEAKER_00", "Mike Cann"),
                ],
            )
            meeting_id = verify_incoming(incoming).meeting_id
            self.assertEqual(SpeakerRegistry(database).observation(meeting_id, 1, "microphone:SPEAKER_00"), MIKE)

    def test_recording_without_remote_speech_still_diarizes_the_microphone(self) -> None:
        # An in-person meeting, or a manual recording with nothing playing, has
        # everyone on the microphone.
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            incoming, _ = write_bundle(root)
            transcriber, calls = stub_transcriber(
                {"microphone": [(1.0, 3.0, "Shall we start?"), (3.5, 6.0, "Yes, go ahead.")]},
                {"microphone": diarization(
                    [(1.0, 3.0, "SPEAKER_00"), (3.5, 6.0, "SPEAKER_01")],
                    [MIKE, [0.8, -0.6]],
                )},
            )

            run_process(incoming, transcriber, root / "worker.sqlite")

            self.assertEqual(calls, [("microphone", {})])
            self.assertEqual(
                [turn["speaker"] for turn in saved_transcript(incoming)["turns"]],
                ["microphone:SPEAKER_00", "microphone:SPEAKER_01"],
            )


class VoiceEmbeddingTests(unittest.TestCase):
    def test_non_finite_empty_or_zero_embedding_is_no_voice_sample(self) -> None:
        rows = [[NAN, NAN], [1.0, float("inf")], [], [0.0, 0.0], [0.6, 0.8]]
        labels = SimpleNamespace(labels=lambda: [f"SPEAKER_0{index}" for index in range(5)])

        self.assertEqual(
            extract_speaker_embeddings(rows, labels, "incoming"),
            {"incoming:SPEAKER_04": [0.6, 0.8]},
        )

    def test_speaker_with_a_nan_centroid_keeps_the_rest_of_the_job(self) -> None:
        # pyannote averages an empty set of chunk embeddings for a speaker heard
        # too briefly, which gives a NaN centroid. Saving it as an observation
        # failed a real meeting on all eight attempts.
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            incoming, _ = write_bundle(root)
            database = root / "worker.sqlite"
            transcriber, _ = stub_transcriber(
                {"incoming": [(0.0, 4.0, "Thanks for joining."), (5.0, 5.4, "Yep.")]},
                {"incoming": diarization(
                    [(0.0, 4.0, "SPEAKER_00"), (5.0, 5.4, "SPEAKER_01")],
                    [[0.6, 0.8], [NAN, NAN]],
                )},
            )

            run_process(incoming, transcriber, database)

            meeting_id = verify_incoming(incoming).meeting_id
            registry = SpeakerRegistry(database)
            self.assertEqual(registry.observation(meeting_id, 1, "incoming:SPEAKER_00"), [0.6, 0.8])
            self.assertIsNone(registry.observation(meeting_id, 1, "incoming:SPEAKER_01"))
            transcript = saved_transcript(incoming)
            self.assertEqual(
                [turn.get("speaker") for turn in transcript["turns"]],
                ["incoming:SPEAKER_00", "incoming:SPEAKER_01"],
            )
            self.assertTrue(transcript["processing"]["speaker_observations_committed"])


if __name__ == "__main__":
    unittest.main()


class DiarizationDeviceTests(unittest.TestCase):
    def test_the_gpu_is_used_when_there_is_one_unless_the_cpu_is_asked_for(self) -> None:
        from meeting_archive_worker.model_processor import diarization_device

        self.assertEqual(diarization_device(None, True), "mps")
        self.assertEqual(diarization_device("auto", True), "mps")
        self.assertEqual(diarization_device("MPS", True), "mps")
        self.assertEqual(diarization_device("cpu", True), "cpu")
        self.assertEqual(diarization_device(None, False), "cpu")
        self.assertEqual(diarization_device("mps", False), "cpu")
        self.assertEqual(diarization_device("something else", True), "cpu")

    def test_a_gpu_failure_retries_the_same_audio_on_the_cpu(self) -> None:
        class Pipeline:
            def __init__(self) -> None:
                self.device = "mps"
                self.calls: list[str] = []

            def to(self, device) -> None:
                self.device = str(device)

            def __call__(self, audio, **options):
                self.calls.append(self.device)
                if self.device == "mps":
                    raise RuntimeError("MPS backend out of memory")
                return "diarized"

        transcriber = object.__new__(WhisperPyannoteTranscriber)
        transcriber.diarizer = Pipeline()
        transcriber.diarizer_device = "mps"

        self.assertEqual(transcriber._run_diarizer(object(), num_speakers=1), "diarized")
        self.assertEqual(transcriber.diarizer.calls, ["mps", "cpu"])
        self.assertEqual(transcriber.diarizer_device, "cpu")

    def test_a_cpu_failure_is_not_retried(self) -> None:
        class Pipeline:
            def __call__(self, audio, **options):
                raise RuntimeError("broken audio")

        transcriber = object.__new__(WhisperPyannoteTranscriber)
        transcriber.diarizer = Pipeline()
        transcriber.diarizer_device = "cpu"

        with self.assertRaises(RuntimeError):
            transcriber._run_diarizer(object())


class EchoTests(unittest.TestCase):
    """The 1 Oct test call, played through speakers into the Yeti."""

    def turn(self, channel: str, start: float, end: float, text: str) -> dict:
        return {"start": start, "end": end, "text": text, "channel_origin": channel}

    def test_mic_lines_repeating_the_call_audio_are_dropped(self) -> None:
        from meeting_archive_worker.processing import remove_echoed_microphone_turns

        turns = [
            self.turn("incoming", 4.4, 9.0, "Hi Mike, this is a test call for meeting archive. Can you hear me all right?"),
            self.turn("microphone", 4.6, 9.2, "Hi Mike, this is a test call for meeting our guy. Can you hear me alright?"),
            self.turn("incoming", 18.6, 25.5, "Great. The other thing to check is that the call audio comes through clearly. So this is me talking for a little while longer"),
            self.turn("microphone", 18.8, 22.6, "Great, the other thing to check is that the call audio comes through it clearly,"),
            self.turn("microphone", 22.8, 25.4, "so this is me talking through a little while longer."),
            self.turn("incoming", 25.7, 26.6, "Thanks speak soon"),
            self.turn("microphone", 25.6, 26.5, "Thanks, speak soon."),
            self.turn("microphone", 87.2, 88.0, "I'm outta here."),
        ]

        kept, removed = remove_echoed_microphone_turns(turns)

        self.assertEqual(removed, 4)
        self.assertEqual([turn["channel_origin"] for turn in kept], ["incoming", "incoming", "incoming", "microphone"])
        self.assertEqual(kept[-1]["text"], "I'm outta here.")

    def test_mikes_own_words_are_kept_even_mid_call(self) -> None:
        from meeting_archive_worker.processing import remove_echoed_microphone_turns

        turns = [
            self.turn("incoming", 0.0, 5.0, "So the quote for the lights came in at five hundred dollars"),
            self.turn("microphone", 4.0, 7.0, "That sounds fine, let's go ahead with it"),
            # A one or two word reply always stays, even right after the call
            # said the same word: it's as likely Mike agreeing as an echo.
            self.turn("incoming", 8.0, 9.0, "Okay great"),
            self.turn("microphone", 8.5, 9.0, "Yeah"),
            self.turn("microphone", 9.2, 9.6, "Okay."),
            self.turn("microphone", 30.0, 32.0, "Five hundred dollars"),
        ]

        kept, removed = remove_echoed_microphone_turns(turns)

        self.assertEqual(removed, 0)
        self.assertEqual(len(kept), 6)
