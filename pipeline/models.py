"""The two pinned models in the project cache: what is there (no network), and downloading what is not.

    missing(need_pyannote=True) -> ["qwen3", "pyannote"] subset, from the cache only
    setup(token) -> exit code for `process.py --setup` (README "Models")

The cache is huggingface_hub's own HF_HUB_CACHE, i.e. <HF_HOME>/hub. process.py and transcribe.sh
both set HF_HOME to .hf-cache before huggingface_hub is imported, so --check, --setup and the
pipeline (mlx-audio, pyannote) all look in the same place. Runs are offline (HF_HUB_OFFLINE=1);
--setup is the only online mode (process.py sets HF_HUB_OFFLINE=0 for it).

The HF token is only ever read from the environment by the caller and passed to the pyannote
download; it is never written or printed. Qwen3-ASR is not gated and is fetched without a token.
"""

import sys
import threading
from pathlib import Path

from huggingface_hub import HfApi, constants, snapshot_download
from huggingface_hub.errors import GatedRepoError, HfHubHTTPError
from tqdm import tqdm

import asr
import diarize

GATE_URL = f"https://huggingface.co/{diarize.MODEL_ID}"
POLL_S = 2.0

# key: (repo, revision, display name, gated, files the snapshot must contain to count as present)
MODELS = {
    "qwen3": (asr.MODEL_ID, asr.MODEL_REV, "Qwen3-ASR", False,
              ["config.json", "model.safetensors", "model.safetensors.index.json", "tokenizer_config.json",
               "vocab.json", "merges.txt", "preprocessor_config.json", "chat_template.json", "generation_config.json"]),
    "pyannote": (diarize.MODEL_ID, diarize.MODEL_REV, "pyannote community-1", True,
                 ["config.yaml", "embedding/pytorch_model.bin", "segmentation/pytorch_model.bin",
                  "plda/plda.npz", "plda/xvec_transform.npz"]),
}


def stage(text: str) -> None:
    print(f"stage: {text}", flush=True)


def snapshot(repo: str, revision: str) -> Path:
    return Path(constants.HF_HUB_CACHE) / f"models--{repo.replace('/', '--')}" / "snapshots" / revision


def missing(need_pyannote: bool = True) -> list[str]:
    """Models whose pinned snapshot lacks a required file. Files only appear in a snapshot once
    fully downloaded, so a partial download counts as missing."""
    keys = ["qwen3", "pyannote"] if need_pyannote else ["qwen3"]
    out = []
    for key in keys:
        repo, rev, _, _, files = MODELS[key]
        if not all((snapshot(repo, rev) / f).is_file() for f in files):
            out.append(key)
    return out


def describe(keys: list[str]) -> str:
    """`models: ok` / `models: missing qwen3|pyannote|both` (the --check line)."""
    if not keys:
        return "models: ok"
    return "models: missing " + ("both" if len(keys) == 2 else keys[0])


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


def download(key: str, token: str | bool) -> None:
    """snapshot_download at the pinned revision, printing `stage: downloading <name> x/y GB` every POLL_S."""
    repo, rev, name, _, _ = MODELS[key]
    info = HfApi().model_info(repo, revision=rev, files_metadata=True, token=token)
    have = snapshot(repo, rev)
    total = sum(s.size or 0 for s in info.siblings if not (have / s.rfilename).is_file())
    unit, div = ("GB", 1e9) if total >= 1e9 else ("MB", 1e6)
    got, done = [0], threading.Event()

    def report() -> None:
        while True:
            stage(f"downloading {name} {min(got[0], total) / div:.1f}/{total / div:.1f} {unit}")
            if done.wait(POLL_S):
                return

    thread = threading.Thread(target=report, daemon=True)
    thread.start()
    try:
        snapshot_download(repo, revision=rev, token=token, tqdm_class=byte_counter(got))
    finally:
        done.set()
        thread.join()
    stage(f"downloaded {name}")


def setup(token: str | None) -> int:
    """Download what is missing. 0 = all present, 3 = pyannote needs a token, 4 = gate not accepted
    or token refused, 5 = anything else. Asks for the token before downloading anything, so the
    app can prompt once and then leave the whole download unattended."""
    need = missing()
    if "pyannote" in need and not token:
        print("needs: hf_token", flush=True)
        print(f"{diarize.MODEL_ID} is gated: set HF_TOKEN (a read token) and accept the conditions at {GATE_URL}",
              file=sys.stderr)
        return 3
    for key in need:
        gated = MODELS[key][3]
        try:
            download(key, token if gated else False)
        except HfHubHTTPError as e:
            status = e.response.status_code if e.response is not None else None
            if gated and (isinstance(e, GatedRepoError) or status in (401, 403)):
                print(f"needs: gate {GATE_URL}", flush=True)
                print(f"{MODELS[key][2]}: HTTP {status}: {e}", file=sys.stderr)
                return 4
            print(f"{MODELS[key][2]}: {type(e).__name__}: {e}", file=sys.stderr)
            return 5
        except Exception as e:
            print(f"{MODELS[key][2]}: {type(e).__name__}: {e}", file=sys.stderr)
            return 5
    still = missing()
    if still:
        print(f"download finished but still {describe(still)}", file=sys.stderr)
        return 5
    stage("done")
    return 0
