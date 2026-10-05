"""Minimal working Qwen3-ASR-1.7B (bf16, MLX) call, with and without context.

    uv run python asr_probe.py testdata/clip_30s.wav            # both variants
    uv run python asr_probe.py some.wav --context "free text"   # custom context

Context goes in `system_prompt=`: mlx-audio puts it in the system turn of the
Qwen3-ASR chat prompt, which is where Qwen's own toolkit puts its `context`.
`hotwords=[...]` is a convenience that appends ", ".join(terms) to it.
Set HF_HOME to the project-local cache (and HF_HUB_OFFLINE=1 once downloaded).
"""

import argparse
import os
import time
from pathlib import Path

os.environ.setdefault("HF_HOME", str(Path(__file__).parent / ".hf-cache"))
os.environ.setdefault("HF_HUB_OFFLINE", "1")
os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")

import mlx.core as mx  # noqa: E402
from mlx_audio.stt import load  # noqa: E402

from glossary import CONTEXT  # noqa: E402

MODEL_ID = "mlx-community/Qwen3-ASR-1.7B-bf16"
MODEL_REV = "e1f6c266914abc5a46e8756e02580f834a6cf8a7"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("audio")
    ap.add_argument("--context", default=CONTEXT)
    args = ap.parse_args()

    model = load(MODEL_ID, revision=MODEL_REV)
    for label, ctx in (("no context", None), ("with context", args.context)):
        mx.reset_peak_memory()
        t0 = time.perf_counter()
        out = model.generate(
            args.audio,              # path, np.ndarray or mx.array (16 kHz mono)
            language="English",      # skip language ID; None = auto-detect
            system_prompt=ctx,       # <- Qwen3-ASR free-form context
            max_tokens=4096,
            temperature=0.0,
        )
        dt = time.perf_counter() - t0
        print(f"--- {label}: {dt:.2f} s, prompt {out.prompt_tokens} tok, "
              f"gen {out.generation_tokens} tok, peak {mx.get_peak_memory() / 1e9:.2f} GB")
        print(out.text.strip())


if __name__ == "__main__":
    main()
