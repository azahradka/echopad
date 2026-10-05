"""diarize.diarize() with the real community-1 model on the fake call's two-voice system track.

Skipped when the pinned model revision is not in the project cache (.hf-cache); see README.
"""
import json

import pytest

import diarize


def model_cached() -> bool:
    from huggingface_hub import try_to_load_from_cache
    return isinstance(try_to_load_from_cache(diarize.MODEL_ID, "config.yaml", revision=diarize.MODEL_REV), str)


if not model_cached():  # before the fixture renders any audio
    pytest.skip(f"{diarize.MODEL_ID}@{diarize.MODEL_REV[:7]} not downloaded (see README, Diarization)",
                allow_module_level=True)


def overlap(a: dict, b: dict) -> float:
    return max(0.0, min(a["end"], b["end"]) - max(a["start"], b["start"]))


def test_two_voices_on_system_track(call_recording):
    truth = json.loads(call_recording["turns"].read_text())
    turns = diarize.diarize(call_recording["folder"] / "system.wav")
    assert len({t["speaker"] for t in turns}) == 2
    # every true turn is mostly covered by one predicted speaker, and the mapping is consistent
    mapping = {}
    for t in truth:
        best = max(turns, key=lambda p: overlap(p, t))
        assert overlap(best, t) > 0.8 * (t["end"] - t["start"])
        assert mapping.setdefault(t["speaker"], best["speaker"]) == best["speaker"]
    assert len(set(mapping.values())) == 2
