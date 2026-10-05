import pytest

from asr import apply_replacements, chunk, leaks, max_tokens, merge_adjacent, split_long
from glossary import CONTEXT


def t(start, end, speaker="A"):
    return {"start": start, "end": end, "speaker": speaker}


def test_merge_adjacent_same_speaker_up_to_30s():
    out = merge_adjacent([t(0, 10), t(11, 20), t(21, 29), t(30, 35)])
    assert out == [t(0, 29), t(30, 35)]


def test_merge_adjacent_stops_at_other_speaker():
    out = merge_adjacent([t(0, 5), t(5, 8, "B"), t(8, 10)])
    assert [x["speaker"] for x in out] == ["A", "B", "A"]


def test_chunk_does_not_merge_across_a_turn_on_the_other_channel():
    mic1, remote, mic2 = ({**t(15, 22, "Aron"), "channel": "mic"}, {**t(21, 31, "Remote S1"), "channel": "system"},
                          {**t(29, 36, "Aron"), "channel": "mic"})
    assert chunk([mic1, mic2, remote]) == [mic1, remote, mic2]
    assert len(chunk([{**t(0, 2), "channel": "mic"}, {**t(3, 4), "channel": "system"}])) == 2


def test_chunk_merges_then_splits():
    out = chunk([t(0, 10), t(11, 25), t(26, 70)])
    assert [(x["start"], x["end"]) for x in out] == [(0, 25), (26, 48), (48, 70)]


def test_split_long_into_equal_pieces():
    out = split_long([t(10, 85)])
    assert len(out) == 3
    assert out[0]["start"] == 10 and out[-1]["end"] == pytest.approx(85)
    assert all(x["end"] - x["start"] == pytest.approx(25) for x in out)
    assert split_long([t(0, 30)]) == [t(0, 30)]


def test_leak_filter_drops_glossary_copy():
    assert leaks(CONTEXT, CONTEXT)
    assert leaks("Okay. " + CONTEXT[40:200], CONTEXT)
    assert not leaks("The ILI run on the Enbridge line found a dent near KP 123+450.", CONTEXT)
    assert not leaks("anything", None)


def test_replacements_whole_word_case_insensitive():
    table = {"Land Mark": "LandMARC", "landmark": "LandMARC", "Devon": "Devin"}
    assert apply_replacements("the land mark tool and Landmark data, ask devon", table) == \
        "the LandMARC tool and LandMARC data, ask Devin"
    assert apply_replacements("landmarks and Devonshire", table) == "landmarks and Devonshire"


def test_max_tokens_scales_with_length():
    assert max_tokens(1) < max_tokens(30) == 260
