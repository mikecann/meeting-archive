"""Word by word speaker labels: who spoke each word, and where a line splits."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path
from types import SimpleNamespace


WORKER_ROOT = Path(__file__).resolve().parents[1] / "worker"
sys.path.insert(0, str(WORKER_ROOT))

from meeting_archive_worker.model_processor import (  # noqa: E402
    segment_turns,
    speaker_at,
)


def said(*words: tuple[float, float, str]):
    """A Whisper segment whose words keep their leading space, as faster-whisper's do."""
    return SimpleNamespace(
        start=words[0][0],
        end=words[-1][1],
        text="".join(f" {text}" for _, _, text in words),
        words=[SimpleNamespace(start=start, end=end, word=f" {text}") for start, end, text in words],
    )


def run(text: str, start: float, pace: float = 0.4) -> list[tuple[float, float, str]]:
    return [(start + index * pace, start + (index + 1) * pace, word) for index, word in enumerate(text.split())]


class SpeakerAtTests(unittest.TestCase):
    def test_the_speaker_active_at_that_moment_wins(self) -> None:
        turns = [(0.0, 5.0, "A"), (5.0, 9.0, "B")]
        self.assertEqual(speaker_at(turns, 2.0), "A")
        self.assertEqual(speaker_at(turns, 7.0), "B")

    def test_a_moment_between_turns_takes_the_nearest_turn(self) -> None:
        turns = [(0.0, 4.0, "A"), (6.0, 9.0, "B")]
        self.assertEqual(speaker_at(turns, 4.5), "A")
        self.assertEqual(speaker_at(turns, 5.6), "B")
        self.assertEqual(speaker_at(turns, 20.0), "B")

    def test_overlapping_turns_take_the_one_started_most_recently(self) -> None:
        self.assertEqual(speaker_at([(0.0, 10.0, "A"), (4.0, 6.0, "B")], 5.0), "B")

    def test_no_turns_means_no_speaker(self) -> None:
        self.assertIsNone(speaker_at([], 1.0))


class SegmentTurnTests(unittest.TestCase):
    def test_a_segment_one_person_spoke_stays_one_turn_with_its_own_text_and_times(self) -> None:
        segment = said(*run("Thanks for joining everyone.", 1.0))
        turns = segment_turns(segment, [(0.0, 5.0, "A")])
        self.assertEqual(turns, [
            {"start": segment.start, "end": segment.end, "text": "Thanks for joining everyone.", "speaker": "A"},
        ])

    def test_a_segment_splits_where_the_speaker_changes(self) -> None:
        first = run("So yeah this could get pretty messy pretty fast.", 10.0)
        second = run("So can I use this?", first[-1][1] + 0.1)
        segment = said(*first, *second)
        change = first[-1][1] + 0.05

        turns = segment_turns(segment, [(0.0, change, "A"), (change, 30.0, "B")])

        self.assertEqual([turn["speaker"] for turn in turns], ["A", "B"])
        self.assertEqual(turns[0]["text"], "So yeah this could get pretty messy pretty fast.")
        self.assertEqual(turns[1]["text"], "So can I use this?")
        # Each turn spans exactly its own words.
        self.assertEqual((turns[0]["start"], turns[0]["end"]), (first[0][0], first[-1][1]))
        self.assertEqual((turns[1]["start"], turns[1]["end"]), (second[0][0], second[-1][1]))

    def test_a_word_goes_to_the_speaker_at_its_midpoint(self) -> None:
        # "now" runs 4.8 to 5.4, so its midpoint 5.1 is in B's turn even though
        # most of the word sits before B starts.
        segment = said(*run("well that works", 3.6, 0.4), (4.8, 5.4, "now"), *run("thanks very much", 5.4, 0.4))
        turns = segment_turns(segment, [(0.0, 5.0, "A"), (5.0, 9.0, "B")])
        self.assertEqual([(turn["speaker"], turn["text"]) for turn in turns], [
            ("A", "well that works"),
            ("B", "now thanks very much"),
        ])

    def test_a_short_sliver_between_the_same_speaker_stays_with_them(self) -> None:
        # B's "mm" is a brief 0.2 s backchannel inside A's sentence.
        segment = said(
            (0.0, 0.4, "We"), (0.4, 0.8, "should"), (0.8, 1.2, "ship"),
            (1.2, 1.4, "mm"),
            (1.4, 1.8, "it"), (1.8, 2.2, "on"), (2.2, 2.6, "Friday"),
        )
        turns = segment_turns(segment, [(0.0, 1.2, "A"), (1.2, 1.4, "B"), (1.4, 3.0, "A")])
        self.assertEqual(len(turns), 1)
        self.assertEqual(turns[0]["speaker"], "A")
        self.assertEqual(turns[0]["text"], "We should ship mm it on Friday")
        self.assertEqual((turns[0]["start"], turns[0]["end"]), (0.0, 2.6))

    def test_a_long_interjection_between_the_same_speaker_is_a_real_turn(self) -> None:
        segment = said(
            (0.0, 0.4, "We"), (0.4, 0.8, "should"),
            (0.8, 1.2, "wait"), (1.2, 1.6, "hold"), (1.6, 2.0, "on"),
            (2.0, 2.4, "ship"), (2.4, 2.8, "it"),
        )
        turns = segment_turns(segment, [(0.0, 0.8, "A"), (0.8, 2.0, "B"), (2.0, 3.0, "A")])
        self.assertEqual([turn["speaker"] for turn in turns], ["A", "B", "A"])

    def test_a_sliver_at_the_edge_of_a_segment_is_not_absorbed(self) -> None:
        segment = said((0.0, 0.2, "Right"), *run("so here is the plan", 0.2, 0.4))
        turns = segment_turns(segment, [(0.0, 0.2, "B"), (0.2, 5.0, "A")])
        self.assertEqual([(turn["speaker"], turn["text"]) for turn in turns], [
            ("B", "Right"),
            ("A", "so here is the plan"),
        ])

    def test_a_sliver_between_different_speakers_keeps_its_own_turn(self) -> None:
        segment = said(*run("one two three", 0.0, 0.4), (1.2, 1.4, "ah"), *run("four five six", 1.4, 0.4))
        turns = segment_turns(segment, [(0.0, 1.2, "A"), (1.2, 1.4, "B"), (1.4, 3.0, "C")])
        self.assertEqual([turn["speaker"] for turn in turns], ["A", "B", "C"])

    def test_turns_come_out_in_time_order_with_nothing_lost(self) -> None:
        words = run("a b c d e f g h i j", 0.0, 0.5)
        turns = segment_turns(said(*words), [(0.0, 2.0, "A"), (2.0, 3.5, "B"), (3.5, 9.0, "A")])
        self.assertEqual(" ".join(turn["text"] for turn in turns), "a b c d e f g h i j")
        self.assertEqual([turn["start"] for turn in turns], sorted(turn["start"] for turn in turns))

    def test_a_segment_without_words_goes_to_its_majority_speaker(self) -> None:
        segment = SimpleNamespace(start=2.0, end=8.0, text=" Hello there ")
        turns = segment_turns(segment, [(0.0, 3.0, "A"), (3.0, 9.0, "B")])
        self.assertEqual(turns, [{"start": 2.0, "end": 8.0, "text": "Hello there", "speaker": "B"}])

    def test_a_segment_with_no_speaker_turns_gets_no_label(self) -> None:
        segment = said(*run("Anyone there", 0.0))
        self.assertEqual(
            segment_turns(segment, []),
            [{"start": 0.0, "end": 0.8, "text": "Anyone there"}],
        )

    def test_a_segment_with_only_blank_text_makes_no_turn(self) -> None:
        self.assertEqual(segment_turns(SimpleNamespace(start=0.0, end=1.0, text="  "), [(0.0, 1.0, "A")]), [])


if __name__ == "__main__":
    unittest.main()
