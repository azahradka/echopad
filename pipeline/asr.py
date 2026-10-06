"""Speech to text per turn: Qwen3-ASR-1.7B bf16 via mlx-audio, glossary as context.

    chunk(turns) -> turns of at most 30 s
    transcribe(wav, chunks, context, replacements, progress) -> chunks with "text"

Rules from the Phase 0 spike (../spike-qwen3.md):
- ASR per diarized turn: adjacent same-speaker turns merged up to 30 s, longer turns split.
  chunk() runs on the turns of both tracks together, so a mic turn and the next mic turn
  are not merged across a remote turn between them (that would put text out of order).
- Only speech turns go in (the app's diarization turns or the energy gate, at least 0.5 s).
- max_tokens is capped by turn length.
- On non-speech the model prints the context back verbatim, so output that shares
  LEAK_WORDS consecutive words with the context is dropped.
"""

import functools
import math
import os
import re
import sys
from pathlib import Path

# The model cache is HF_HOME (<data dir>/models), set by transcribe.sh; runs are offline.
os.environ.setdefault("HF_HUB_OFFLINE", "1")
os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")
os.environ.setdefault("HF_HUB_DISABLE_PROGRESS_BARS", "1")

from mlx_audio.stt import load  # noqa: E402

from diarize import SR, read_wav  # noqa: E402

MODEL_ID = "mlx-community/Qwen3-ASR-1.7B-bf16"
MODEL_REV = "e1f6c266914abc5a46e8756e02580f834a6cf8a7"

MAX_TURN_S = 30.0
MIN_TURN_S = 0.5
PAD_S = 0.1
LEAK_WORDS = 6


@functools.cache
def model():
    """Loaded once per process."""
    return load(MODEL_ID, revision=MODEL_REV)


def merge_adjacent(turns: list[dict], max_s: float = MAX_TURN_S) -> list[dict]:
    """Join consecutive turns of the same speaker and channel while the joined span stays within max_s."""
    out: list[dict] = []
    for t in sorted(turns, key=lambda t: t["start"]):
        prev = out[-1] if out else None
        if (prev and (prev["speaker"], prev.get("channel")) == (t["speaker"], t.get("channel"))
                and t["end"] - prev["start"] <= max_s):
            prev["end"] = max(prev["end"], t["end"])
        else:
            out.append(dict(t))
    return out


def split_long(turns: list[dict], max_s: float = MAX_TURN_S) -> list[dict]:
    """Cut turns longer than max_s into equal pieces of at most max_s."""
    out = []
    for t in turns:
        n = max(1, math.ceil((t["end"] - t["start"]) / max_s))
        step = (t["end"] - t["start"]) / n
        out += [{**t, "start": t["start"] + i * step, "end": t["start"] + (i + 1) * step} for i in range(n)]
    return out


def chunk(turns: list[dict]) -> list[dict]:
    return split_long(merge_adjacent(turns))


def words(text: str) -> list[str]:
    return re.findall(r"\w+", text.lower())


def leaks(text: str, context: str | None, n: int = LEAK_WORDS) -> bool:
    """True if text shares n consecutive words with the context."""
    if not context:
        return False
    w, c = words(text), words(context)
    grams = {tuple(c[i:i + n]) for i in range(len(c) - n + 1)}
    return any(tuple(w[i:i + n]) in grams for i in range(len(w) - n + 1))


def apply_replacements(text: str, table: dict[str, str]) -> str:
    """Whole-word, case-insensitive alias -> term, longest alias first."""
    for alias in sorted(table, key=len, reverse=True):
        text = re.sub(r"(?<!\w)" + re.escape(alias) + r"(?!\w)", table[alias], text, flags=re.IGNORECASE)
    return text


def max_tokens(seconds: float) -> int:
    return int(20 + 8 * seconds)


def transcribe(wav_path: str | Path, chunks: list[dict], context: str | None,
               replacements: dict[str, str] | None = None, progress=None) -> list[dict]:
    """ASR for each chunk (from chunk()) of one track. Chunks that come out empty or leak the context are left out.
    progress() is called before each chunk."""
    audio = read_wav(wav_path)
    out = []
    for t in chunks:
        if progress:
            progress()
        if t["end"] - t["start"] < MIN_TURN_S:
            continue
        clip = audio[int(max(0.0, t["start"] - PAD_S) * SR): int((t["end"] + PAD_S) * SR)]
        r = model().generate(clip, language="English", system_prompt=context,
                             max_tokens=max_tokens(t["end"] - t["start"]), temperature=0.0)
        text = r.text.strip()
        if leaks(text, context):
            print(f"asr: dropped context leak at {t['start']:.1f}s ({t['speaker']})", file=sys.stderr)
            continue
        if text:
            out.append({**t, "text": apply_replacements(text, replacements or {})})
    return out
