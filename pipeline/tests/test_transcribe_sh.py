"""transcribe.sh as the app runs it: --check, the needs-setup guard, and a full run through the real
data dir (ECHOPAD_DATA_DIR or ~/Library/Application Support/EchoPad). Never goes online."""
import json
import os
import shutil
import subprocess
from pathlib import Path

import pytest

import asr
from conftest import BASE, write_config

SCRIPT = Path(__file__).parent.parent / "transcribe.sh"


def run(*args, data_dir=None, config=None):
    env = {k: v for k, v in os.environ.items() if k not in ("ECHOPAD_DATA_DIR", "NOTETAKER_CONFIG")}
    env["ECHOPAD_DATA_DIR"] = str(data_dir or BASE)
    if config:
        env["NOTETAKER_CONFIG"] = str(config)
    return subprocess.run([SCRIPT, *map(str, args)], capture_output=True, text=True, env=env)


def test_qwen3_pin_matches_asr():
    snapshot = f"models--{asr.MODEL_ID.replace('/', '--')}/snapshots/{asr.MODEL_REV}\""
    assert snapshot in SCRIPT.read_text()


def test_check_empty_data_dir(tmp_path):
    r = run("--check", data_dir=tmp_path)
    assert (r.returncode, r.stdout) == (0, "setup: missing both\n")


def test_run_without_setup_exits_6_and_touches_nothing(call_recording, config, tmp_path):
    r = run(call_recording["folder"], "--dry-run", data_dir=tmp_path, config=config)
    assert (r.returncode, r.stdout) == (6, "needs: setup\n")
    assert r.stderr.splitlines()[-1].startswith("setup missing both in ")
    assert not (call_recording["folder"] / "error.txt").exists()


def test_full_run(call_recording, tmp_path):
    """The real env and model, a dry run so the WAVs stay and nothing is notified."""
    if run("--check").stdout != "setup: ok\n":
        pytest.skip(f"run transcribe.sh --setup for {BASE} first")
    folder = tmp_path / call_recording["folder"].name
    shutil.copytree(call_recording["folder"], folder)
    config = write_config(tmp_path / "config.toml", tmp_path / "vault")
    r = run(folder, "--dry-run", config=config)
    assert r.returncode == 0, r.stderr
    stages = r.stdout.splitlines()
    n = len(stages) - 2
    assert n > 0 and stages == [*[f"stage: transcribing {i}/{n}" for i in range(1, n + 1)],
                                "stage: writing transcript", "stage: done"]
    tj = json.loads((folder / "transcript.json").read_text())
    assert {s["speakerID"] for s in tj["segments"]} == {"local", "remote-s1", "remote-s2"}
    [md] = (tmp_path / "vault" / "_attachments" / "transcripts").glob("*.transcript.md")
    assert "diarization_model: fluidaudio-community-1" in md.read_text() and "**Remote S2:**" in md.read_text()
