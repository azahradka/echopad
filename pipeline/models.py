"""Downloading the pinned Qwen3-ASR model, for `transcribe.sh --setup` (the only online step).

    setup() -> exit code for `process.py --setup`: 0, or 5 with the reason as the last stderr line

The cache is huggingface_hub's own HF_HUB_CACHE, i.e. <HF_HOME>/hub, with HF_HOME = <data dir>/models
set by transcribe.sh. transcribe.sh decides whether the model is present (all files of the pinned
snapshot; files only appear there once fully downloaded) and calls this only when it is not.
The model is not gated: no token.
"""

import sys
import threading
from pathlib import Path

from huggingface_hub import HfApi, constants, snapshot_download
from tqdm import tqdm

import asr

POLL_S = 2.0
NAME = "Qwen3-ASR"


def stage(text: str) -> None:
    print(f"stage: {text}", flush=True)


def snapshot() -> Path:
    return Path(constants.HF_HUB_CACHE) / f"models--{asr.MODEL_ID.replace('/', '--')}" / "snapshots" / asr.MODEL_REV


def byte_counter(counter: list[int]) -> type[tqdm]:
    """A silent tqdm_class for snapshot_download that adds up its "Reconstructing" bar, which every
    file's bytes written to disk feed into (huggingface_hub 1.x; checked against the cache growing
    on a 550 MB download). If a hub upgrade renames the bar, progress stays at 0 but the download
    still works."""
    class Bytes(tqdm):
        def __init__(self, *args, **kwargs):
            self.counts = str(kwargs.get("desc", "")).startswith("Reconstructing")
            super().__init__(*args, **{**kwargs, "disable": True})

        def update(self, n=1):
            if self.counts:
                counter[0] += n or 0
            return super().update(n)
    return Bytes


def download() -> None:
    """snapshot_download at the pinned revision, printing `stage: downloading Qwen3-ASR x/y GB` every POLL_S."""
    info = HfApi().model_info(asr.MODEL_ID, revision=asr.MODEL_REV, files_metadata=True, token=False)
    have = snapshot()
    total = sum(s.size or 0 for s in info.siblings if not (have / s.rfilename).is_file())
    unit, div = ("GB", 1e9) if total >= 1e9 else ("MB", 1e6)
    got, done = [0], threading.Event()

    def report() -> None:
        while True:
            stage(f"downloading {NAME} {min(got[0], total) / div:.1f}/{total / div:.1f} {unit}")
            if done.wait(POLL_S):
                return

    thread = threading.Thread(target=report, daemon=True)
    thread.start()
    try:
        snapshot_download(asr.MODEL_ID, revision=asr.MODEL_REV, token=False, tqdm_class=byte_counter(got))
    finally:
        done.set()
        thread.join()
    stage(f"downloaded {NAME}")


def setup() -> int:
    """Download the model at the pinned revision. 0 = done, 5 = failure (reason on stderr, last line)."""
    try:
        download()
    except Exception as e:
        print(f"{NAME} download failed: {type(e).__name__}: {e}".splitlines()[0], file=sys.stderr)
        return 5
    return 0
