"""Spike benchmark for Qwen3-ASR-1.7B bf16 via mlx-audio (Phase 0 step 4).

    uv run python gen_test_audio.py   # once, writes testdata/
    uv run python bench_asr.py        # writes results/bench.json and prints a summary
"""

from __future__ import annotations

import json
import os
import re
import resource
import statistics as st
import time
from pathlib import Path

ROOT = Path(__file__).parent
os.environ.setdefault("HF_HOME", str(ROOT / ".hf-cache"))
os.environ.setdefault("HF_HUB_OFFLINE", "1")
os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")

import mlx.core as mx  # noqa: E402
import numpy as np  # noqa: E402
from mlx_audio.stt import load  # noqa: E402
from mlx_audio.stt.models.qwen3_asr.qwen3_asr import split_audio_into_chunks  # noqa: E402
from scipy.io import wavfile  # noqa: E402

import glossary  # noqa: E402
from gen_test_audio import TERMS, count_terms  # noqa: E402
from asr_probe import MODEL_ID, MODEL_REV  # noqa: E402

SR = 16000
TD = ROOT / "testdata"
CTX = glossary.CONTEXT


def wav(path: Path) -> np.ndarray:
    sr, d = wavfile.read(path)
    assert sr == SR
    return d.astype(np.float32) / 32768.0


def run(model, audio: np.ndarray, ctx: str | None) -> dict:
    mx.reset_peak_memory()
    t0 = time.perf_counter()
    out = model.generate(audio, language="English", system_prompt=ctx, max_tokens=8192, temperature=0.0)
    dt = time.perf_counter() - t0
    dur = len(audio) / SR
    return {
        "audio_s": round(dur, 2), "wall_s": round(dt, 3), "rtf": round(dt / dur, 4),
        "prompt_tok": out.prompt_tokens, "gen_tok": out.generation_tokens,
        "peak_gb": round(mx.get_peak_memory() / 1e9, 2), "text": out.text.strip(),
    }


def recall(text: str, ref: str) -> dict:
    got, exp = count_terms(text), count_terms(ref)
    return {k: [min(got[k], exp[k]), exp[k], got[k]] for k in TERMS}  # [hits, expected, raw found]


def spurious(text: str, ref: str) -> dict:
    """Glossary terms that appear in the output more often than in the reference."""
    res = {}
    for t in glossary.TERMS:
        p = r"(?<![\w-])" + re.escape(t) + r"(?![\w-])"
        o, r = len(re.findall(p, text)), len(re.findall(p, ref))
        if o > r:
            res[t] = [o, r]
    return res


def summary(name: str, rows: list[dict]) -> dict:
    w = [r["wall_s"] for r in rows]
    a = sum(r["audio_s"] for r in rows)
    return {
        "name": name, "n": len(rows), "audio_s": round(a, 1), "wall_s": round(sum(w), 2),
        "rtf": round(sum(w) / a, 4), "per_call_median_s": round(st.median(w), 3),
        "per_call_min_s": round(min(w), 3), "per_call_max_s": round(max(w), 3),
        "prompt_tok_median": st.median(r["prompt_tok"] for r in rows),
        "peak_gb_max": max(r["peak_gb"] for r in rows),
    }


def main() -> None:
    res: dict = {"model": MODEL_ID, "revision": MODEL_REV, "context": CTX, "context_terms": len(glossary.TERMS)}
    t0 = time.perf_counter()
    model = load(MODEL_ID, revision=MODEL_REV)
    res["load_s"] = round(time.perf_counter() - t0, 2)
    clip = wav(TD / "clip_30s.wav")
    meet = wav(TD / "meeting_10min.wav")
    turns = json.loads((TD / "meeting_10min.turns.json").read_text())
    clip_ref = (TD / "clip_30s.txt").read_text()
    meet_ref = " ".join(t["text"] for t in turns)

    run(model, clip[: 5 * SR], None)  # warm-up (kernel compile)
    run(model, clip[: 5 * SR], CTX)

    # 1. 30 s clip, 3 reps each
    for label, ctx in (("none", None), ("ctx", CTX)):
        rows = [run(model, clip, ctx) for _ in range(3)]
        res[f"clip30_{label}"] = {**summary(f"clip30_{label}", rows), "text": rows[0]["text"],
                                  "recall": recall(rows[0]["text"], clip_ref),
                                  "spurious": spurious(rows[0]["text"], clip_ref)}
        print(json.dumps({k: v for k, v in res[f"clip30_{label}"].items() if k not in ("text", "recall")}), flush=True)

    # 2. whole 10-min file in one call
    for label, ctx in (("none", None), ("ctx", CTX)):
        r = run(model, meet, ctx)
        res[f"whole_{label}"] = {**r, "recall": recall(r["text"], meet_ref), "spurious": spurious(r["text"], meet_ref)}
        print(f"whole_{label}", {k: v for k, v in r.items() if k != "text"}, flush=True)

    # 3. 10-min file split into <=30 s segments at low-energy points (mlx-audio's own splitter)
    segs = split_audio_into_chunks(meet, sr=SR, chunk_duration=30.0)
    for label, ctx in (("none", None), ("ctx", CTX)):
        rows = [run(model, s, ctx) for s, _ in segs]
        text = " ".join(r["text"] for r in rows)
        res[f"seg30_{label}"] = {**summary(f"seg30_{label}", rows), "per_seg": [{k: v for k, v in r.items() if k != "text"} for r in rows],
                                 "text": text, "recall": recall(text, meet_ref), "spurious": spurious(text, meet_ref)}
        print(json.dumps({k: v for k, v in res[f"seg30_{label}"].items() if k not in ("text", "recall", "per_seg")}), flush=True)

    # 4. per ground-truth speaker turn (what the pipeline does after diarization)
    for label, ctx in (("none", None), ("ctx", CTX)):
        rows = []
        for t in turns:
            a = meet[int(max(0, t["start"] - 0.1) * SR): int((t["end"] + 0.1) * SR)]
            rows.append(run(model, a, ctx))
        text = " ".join(r["text"] for r in rows)
        res[f"turns_{label}"] = {**summary(f"turns_{label}", rows), "per_turn": [{k: v for k, v in r.items() if k != "text"} for r in rows],
                                 "text": text, "recall": recall(text, meet_ref), "spurious": spurious(text, meet_ref)}
        print(json.dumps({k: v for k, v in res[f"turns_{label}"].items() if k not in ("text", "recall", "per_turn")}), flush=True)

    # 5. per-call overhead: 20 sequential 5 s clips, two alternating rounds
    fives = [meet[int(o * SR): int((o + 5) * SR)] for o in np.linspace(10, 580, 20)]
    over = {"none": [], "ctx": []}
    for _ in range(2):
        for label, ctx in (("none", None), ("ctx", CTX)):
            t0 = time.perf_counter()
            rows = [run(model, a, ctx) for a in fives]
            over[label].append({"total_s": round(time.perf_counter() - t0, 3), **summary(f"5s_{label}", rows)})
    res["five_sec_x20"] = over
    print(json.dumps(over), flush=True)

    res["max_rss_gb"] = round(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1e9, 2)
    (ROOT / "results").mkdir(exist_ok=True)
    (ROOT / "results" / "bench.json").write_text(json.dumps(res, indent=1))
    print("max_rss_gb", res["max_rss_gb"])


if __name__ == "__main__":
    main()
