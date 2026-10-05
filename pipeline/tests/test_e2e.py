"""process.py end to end on synthetic audio, in-process so the ASR model loads once."""
import json
import shutil
from datetime import datetime, timedelta

import numpy as np

import process
from conftest import FIXTURES, START_UTC, write_wav


def expected_name():
    return f"{datetime.fromisoformat(START_UTC).astimezone():%Y-%m-%d %H%M}.transcript.md"


def test_call(call_recording, config, capfd):
    folder = call_recording["folder"]
    rc = process.main([str(folder), "--dry-run", "--no-claude", "--turns", str(call_recording["turns"]), "--config", str(config)])
    assert rc == 0

    # stdout is only stage lines, in order, one per ASR chunk (EchoPad reads these)
    lines = capfd.readouterr().out.splitlines()
    assert all(line.startswith("stage: ") for line in lines), lines
    stages = [line.removeprefix("stage: ") for line in lines]
    n = sum(s.startswith("transcribing ") for s in stages)
    assert n > 0 and stages == ["detecting mode", "diarizing", *[f"transcribing {i}/{n}" for i in range(1, n + 1)],
                                "writing transcript", "done"]

    # transcript.json written back into the folder in EchoPad's (ScribeKit) schema
    tj = json.loads((folder / "transcript.json").read_text())
    assert set(tj) == {"segments", "speakers", "language", "duration"}
    assert tj["duration"] == call_recording["seconds"]
    assert tj["speakers"] == [{"id": "local", "name": "Aron", "isLocal": True},
                              {"id": "remote-s1", "name": "Remote S1", "isLocal": False},
                              {"id": "remote-s2", "name": "Remote S2", "isLocal": False}]
    segs = tj["segments"]
    assert all(set(s) == {"speakerID", "start", "end", "text", "words"} and s["words"] == [] and s["text"] for s in segs)
    assert [s["start"] for s in segs] == sorted(s["start"] for s in segs)
    truth = json.loads(call_recording["turns"].read_text())
    assert segs[0]["speakerID"] == "remote-s1" and segs[0]["start"] == truth[0]["start"]
    assert {s["speakerID"] for s in segs} == {"local", "remote-s1", "remote-s2"}
    assert all(0 <= s["start"] < s["end"] <= tj["duration"] for s in segs)
    path = config.parent / "vault" / "_attachments" / "transcripts" / expected_name()
    text = path.read_text()
    fm = process.frontmatter(text)
    start = datetime.fromisoformat(START_UTC).astimezone()
    assert fm["status"] == "raw" and fm["mode"] == "call"
    assert datetime.fromisoformat(fm["start"]) == start
    assert datetime.fromisoformat(fm["retain_until"]) == start + timedelta(days=3)
    assert fm["asr_model"].startswith("mlx-community/Qwen3-ASR-1.7B-bf16@")
    assert fm["diarization_model"] == "turns override (system.turns.json)"
    assert fm["source_folder"] == str(folder) and fm["title"] == "Microsoft Teams call"
    assert fm["glossary"] == str(FIXTURES / "glossary.md")
    body = text.split("## Transcript", 1)[1]
    for speaker in ("**Aron:**", "**Remote S1:**", "**Remote S2:**"):
        assert speaker in body
    assert "LandMARC" in body and "Watermarc" in body  # spoken as "Land Mark" / "Water Mark"
    assert (folder / "microphone.wav").exists() and (folder / "system.wav").exists()  # dry run keeps WAVs
    print(text)


def test_in_person_when_system_is_silent(call_recording, config, tmp_path):
    folder = tmp_path / "in-person"
    shutil.copytree(call_recording["folder"], folder)
    write_wav(folder / "system.wav", np.zeros(16000 * 5, np.float32))
    turns = tmp_path / "mic.turns.json"
    turns.write_text(json.dumps([{"start": 0.0, "end": call_recording["seconds"], "speaker": "SPEAKER_00"}]))
    assert process.main([str(folder), "--dry-run", "--turns", str(turns), "--config", str(config)]) == 0
    text = (config.parent / "vault" / "_attachments" / "transcripts" / expected_name()).read_text()
    assert process.frontmatter(text)["mode"] == "in-person"
    assert "**S1:**" in text and "Remote" not in text and "**Aron:**" not in text


def test_failure_writes_error_and_keeps_wavs(call_recording, config, tmp_path, monkeypatch):
    folder = tmp_path / "broken"
    shutil.copytree(call_recording["folder"], folder)
    (folder / "conversation.json").unlink()
    notes = []
    monkeypatch.setattr(process, "notify", lambda title, msg, path=None: notes.append((title, msg)))
    assert process.main([str(folder), "--no-claude", "--config", str(config)]) == 1
    first = (folder / "error.txt").read_text().splitlines()[0]
    assert first.startswith("FileNotFoundError") and notes == [("Notetaker failed", first)]
    assert (folder / "microphone.wav").exists()
