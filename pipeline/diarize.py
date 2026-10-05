"""Who spoke when: pyannote community-1 on MPS, and an energy gate for the mic track.

    diarize(wav, num_speakers_hint=(2, 4)) -> [{"start", "end", "speaker"}]   # speaker = pyannote label
    speech_regions(wav) -> [(start, end)]                                     # no model

pyannote is imported lazily (torch is slow to import, and --turns runs never need it).
Its telemetry is switched off before import. Audio is passed in memory because
pyannote's file decoder needs FFmpeg, which is not installed. The model revision is
pinned and loaded from the project cache (.hf-cache) offline; no token is needed once cached.
"""

import functools
import os
import warnings
from pathlib import Path

os.environ.setdefault("HF_HOME", str(Path(__file__).parent / ".hf-cache"))
os.environ.setdefault("HF_HUB_OFFLINE", "1")
os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")
os.environ.setdefault("HF_HUB_DISABLE_PROGRESS_BARS", "1")
os.environ["PYANNOTE_METRICS_ENABLED"] = "0"

import numpy as np  # noqa: E402
from scipy.io import wavfile  # noqa: E402

warnings.filterwarnings("ignore", category=wavfile.WavFileWarning)  # Apple FLLR padding chunk
warnings.filterwarnings("ignore", message=r"std\(\): degrees of freedom")  # pyannote stats pooling on short windows, harmless

SR = 16000
MODEL_ID = "pyannote/speaker-diarization-community-1"
MODEL_REV = "3533c8cf8e369892e6b79ff1bf80f7b0286a54ee"

FRAME_S = 0.03
GATE_DBFS = -45.0      # frame RMS above this counts as speech
MERGE_GAP_S = 0.5      # speech regions closer than this are joined

MIN_SPEAKER_S = 1.0    # a pyannote speaker with less exclusive speech than this is a stray cluster
MIN_SEGMENT_S = 0.25   # shorter segments that touch a neighbour are folded into it
TOUCH_S = 0.05         # segments this close count as adjacent


def read_wav(path: str | Path) -> np.ndarray:
    """16 kHz mono float32 in [-1, 1]. EchoPad writes float32; int16 is accepted for test audio."""
    sr, data = wavfile.read(path)
    if sr != SR or data.ndim != 1:
        raise ValueError(f"{path}: expected 16 kHz mono, got {sr} Hz, shape {data.shape}")
    if data.dtype == np.int16:
        return data.astype(np.float32) / 32768.0
    return data.astype(np.float32)


def speech_regions(wav_path: str | Path) -> list[tuple[float, float]]:
    """(start, end) seconds of frames whose RMS is above GATE_DBFS, gaps < MERGE_GAP_S merged."""
    audio = read_wav(wav_path)
    n = int(FRAME_S * SR)
    frames = audio[: len(audio) // n * n].reshape(-1, n)
    loud = np.sqrt((frames ** 2).mean(axis=1)) > 10 ** (GATE_DBFS / 20)
    regions: list[tuple[float, float]] = []
    for i in np.flatnonzero(loud):
        start, end = i * FRAME_S, (i + 1) * FRAME_S
        if regions and start - regions[-1][1] < MERGE_GAP_S:
            regions[-1] = (regions[-1][0], end)
        else:
            regions.append((start, end))
    return [(round(float(s), 2), round(float(e), 2)) for s, e in regions]


def device_name() -> str:
    import torch
    return "mps" if torch.backends.mps.is_available() else "cpu"


@functools.cache
def pipeline(device: str | None = None):
    """community-1 at MODEL_REV on `device` (default MPS when available). Loaded once per process."""
    import torch
    from pyannote.audio import Pipeline

    try:
        pipe = Pipeline.from_pretrained(MODEL_ID, revision=MODEL_REV)
    except Exception as e:  # offline and not cached: LocalEntryNotFoundError
        pipe, err = None, f": {e}"
    else:
        err = ""
    if pipe is None:
        raise RuntimeError(f"could not load {MODEL_ID}@{MODEL_REV[:7]}; download it once with an HF token (see README){err}")
    return pipe.to(torch.device(device or device_name()))


def clean(segments: list[dict]) -> list[dict]:
    """Fold slivers and stray clusters into the turn they touch; join touching same-speaker segments.

    community-1 sometimes gives the last few hundred ms of a turn, or a 10-50 ms sliver at a
    speaker change, to another label (a third, stray one when no speaker count is given).
    A segment is folded when its label has under MIN_SPEAKER_S of speech in total, or when it
    is shorter than MIN_SEGMENT_S and touches a neighbour: it extends the previous adjacent
    segment, else the next one. Stray-label segments that touch nothing are dropped.
    """
    totals: dict[str, float] = {}
    for s in segments:
        totals[s["speaker"]] = totals.get(s["speaker"], 0.0) + s["end"] - s["start"]
    stray = {spk for spk, t in totals.items() if t < MIN_SPEAKER_S and len(totals) > 1}
    segs = sorted((dict(s) for s in segments), key=lambda s: s["start"])
    out: list[dict] = []
    for i, s in enumerate(segs):
        prev = out[-1] if out else None
        nxt = segs[i + 1] if i + 1 < len(segs) else None
        touches_prev = prev is not None and s["start"] - prev["end"] <= TOUCH_S
        touches_next = nxt is not None and nxt["start"] - s["end"] <= TOUCH_S
        short = s["end"] - s["start"] < MIN_SEGMENT_S
        if s["speaker"] in stray or (short and (touches_prev or touches_next)):
            if touches_prev:
                prev["end"] = max(prev["end"], s["end"])
                continue
            if touches_next:
                nxt["start"] = s["start"]
                continue
            if s["speaker"] in stray:
                continue
        if touches_prev and prev["speaker"] == s["speaker"]:
            prev["end"] = max(prev["end"], s["end"])
        else:
            out.append(s)
    return [{**s, "start": round(s["start"], 2), "end": round(s["end"], 2)} for s in out]


def diarize(wav_path: str | Path, num_speakers_hint: tuple[int, int] | None = None,
            device: str | None = None) -> list[dict]:
    """Exclusive (one speaker at a time) diarization. num_speakers_hint = (min, max)."""
    import torch

    audio = torch.from_numpy(read_wav(wav_path))[None]
    hint = {} if num_speakers_hint is None else {"min_speakers": num_speakers_hint[0], "max_speakers": num_speakers_hint[1]}
    out = pipeline(device)({"waveform": audio, "sample_rate": SR}, **hint)
    return clean([{"start": seg.start, "end": seg.end, "speaker": spk}
                  for seg, _, spk in out.exclusive_speaker_diarization.itertracks(yield_label=True)])
