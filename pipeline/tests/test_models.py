"""--check, --setup and the missing-models guard, against an empty fake cache; never downloads."""
import subprocess
from pathlib import Path

import pytest

import models
import process

HERE = Path(__file__).parent.parent


@pytest.fixture
def empty_cache(tmp_path, monkeypatch):
    monkeypatch.setattr(models.constants, "HF_HUB_CACHE", str(tmp_path / "hub"))

    def no_download(*a, **k):
        raise AssertionError("must not download in tests")
    monkeypatch.setattr(models, "snapshot_download", no_download)
    monkeypatch.setattr(models, "HfApi", no_download)


def test_check_empty_cache(empty_cache, capsys):
    assert process.main(["--check"]) == 0
    assert capsys.readouterr().out == "models: missing both\n"


def test_check_real_cache_via_transcribe_sh():
    """transcribe.sh sets HF_HOME itself, so this is the cache EchoPad's runs use."""
    if models.missing():
        pytest.skip("models not downloaded into .hf-cache")
    out = subprocess.run([HERE / "transcribe.sh", "--check"], capture_output=True, text=True, check=True).stdout
    assert out == "models: ok\n"


def test_setup_without_token_asks_for_one(empty_cache, capsys, monkeypatch):
    monkeypatch.delenv("HF_TOKEN", raising=False)
    assert process.main(["--setup"]) == 3  # before downloading anything, Qwen3 included
    assert capsys.readouterr().out == "needs: hf_token\n"


def test_run_with_models_missing_exits_6(empty_cache, call_recording, config, capsys):
    folder = call_recording["folder"]
    assert process.main([str(folder), "--dry-run", "--config", str(config)]) == 6
    assert capsys.readouterr().out == "needs: models\n"
    assert not (folder / "error.txt").exists()
