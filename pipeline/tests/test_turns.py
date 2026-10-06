"""turns.json, written by the app: read_turns() validation, clean(), and a bad file as a recording failure."""
import json
import shutil

import pytest

import process
from diarize import clean

GOOD = {"mode": "call", "track": "system.wav", "diarizer": "fluidaudio-community-1",
        "turns": [{"start": 0.5, "end": 3.0, "speaker": "S1"}, {"start": 3.0, "end": 6, "speaker": "S2"}]}


def write(folder, data):
    (folder / "turns.json").write_text(data if isinstance(data, str) else json.dumps(data))


def test_read_turns(tmp_path):
    write(tmp_path, GOOD)
    assert process.read_turns(tmp_path) == GOOD
    write(tmp_path, {**GOOD, "mode": "in-person", "track": "microphone.wav", "turns": []})
    assert process.read_turns(tmp_path)["turns"] == []


@pytest.mark.parametrize("data, reason", [
    (None, "turns.json missing"),
    ("{not json", "not valid JSON"),
    ([], "mode must be one of"),
    ({**GOOD, "mode": "zoom"}, "mode must be one of"),
    ({**GOOD, "track": "microphone.wav"}, "track must be system.wav in call mode"),
    ({**GOOD, "diarizer": ""}, "diarizer must be"),
    ({**GOOD, "turns": {}}, "turns must be a list"),
    ({**GOOD, "turns": [{"start": 2, "end": 1, "speaker": "S1"}]}, "turn 0 must be"),
    ({**GOOD, "turns": [{"start": 0, "end": 1}]}, "turn 0 must be"),
    ({**GOOD, "turns": [{"start": "0", "end": 1, "speaker": "S1"}]}, "turn 0 must be"),
])
def test_read_turns_rejects(tmp_path, data, reason):
    if data is not None:
        write(tmp_path, data)
    with pytest.raises(ValueError, match=reason):
        process.read_turns(tmp_path)


def test_clean_folds_stray_and_sliver_labels():
    turns = [{"start": 0.0, "end": 5.0, "speaker": "S1"}, {"start": 5.0, "end": 5.1, "speaker": "S2"},
             {"start": 5.1, "end": 9.0, "speaker": "S3"}, {"start": 9.0, "end": 9.4, "speaker": "S4"},
             {"start": 12.0, "end": 15.0, "speaker": "S2"}]
    assert clean(turns) == [{"start": 0.0, "end": 5.1, "speaker": "S1"}, {"start": 5.1, "end": 9.4, "speaker": "S3"},
                            {"start": 12.0, "end": 15.0, "speaker": "S2"}]


def test_missing_turns_json_is_a_recording_failure(call_recording, config, tmp_path, monkeypatch):
    folder = tmp_path / "no-turns"
    shutil.copytree(call_recording["folder"], folder)
    (folder / "turns.json").unlink()
    notes = []
    monkeypatch.setattr(process, "notify", lambda title, msg, path=None: notes.append((title, msg)))
    assert process.main([str(folder), "--no-claude", "--config", str(config)]) == 1
    first = (folder / "error.txt").read_text().splitlines()[0]
    assert first.startswith("ValueError: turns.json missing in") and notes == [("Notetaker failed", first)]
    assert (folder / "microphone.wav").exists() and (folder / "system.wav").exists()
