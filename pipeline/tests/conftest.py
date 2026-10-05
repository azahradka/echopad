import json
from pathlib import Path

import numpy as np
import pytest
from scipy.io import wavfile

from gen_test_audio import tts

FIXTURES = Path(__file__).parent / "fixtures"
SR = 16000
START_UTC = "2026-10-05T19:35:00Z"

# Fake Teams call: (channel, voice, text). The remote side has two voices on system.wav,
# you are one voice on microphone.wav. "overlap" starts that line 2 s before the previous ends.
CALL = [
    ("system", "Samantha", "Good morning everyone. Let's go through the LandMARC update for the Enbridge line before the client meeting on Thursday."),
    ("system", "Daniel", "Thanks. The ILI run finished last week, and the IMU data looks clean apart from two short gaps near the river."),
    ("mic", "Karen", "Great. Did the bending strain at the second girth weld change since the last run, or is it about the same?"),
    ("system", "Samantha", "Not much. Devin is still checking the girth welds near the watercourse crossing, and he will report back tomorrow.", ),
    ("mic", "Karen", "Okay. Please send me his numbers as soon as you have them, because Curt wants them for the monthly report."),
    ("system", "Daniel", "Will do. We should also have the Watermarc results by Friday, so we can compare both sites next week."),
    ("system", "Samantha", "One more thing. The excavation crew found a dent close to the launcher, and the depth of cover there is only about half a metre."),
    ("mic", "Karen", "That sounds serious. Can we get an NDE team out there this week, before the backfill goes in?"),
    ("system", "Daniel", "I already asked. They can be on site on Wednesday, and they will send the report straight to Devin and Curt."),
    ("mic", "Karen", "Perfect. Then let's meet again on Monday morning and go through everything together. Thanks, everyone."),
]
OVERLAP_AT = 4  # index of the line that starts before the previous one ends


def write_wav(path: Path, audio: np.ndarray) -> None:
    wavfile.write(path, SR, audio.astype(np.float32))  # float32, like EchoPad


@pytest.fixture(scope="session")
def call_recording(tmp_path_factory) -> dict:
    """An EchoPad-like conversation folder for a call, and the ground-truth system turns."""
    clips = [(ch, tts(text, voice)) for ch, voice, text in CALL]
    t, placed = 1.0, []
    for i, (ch, a) in enumerate(clips):
        if i == OVERLAP_AT:
            t -= 2.0 + 0.6
        placed.append((ch, t, a))
        t += len(a) / SR + 0.6
    total = int((t + 1.0) * SR)
    tracks = {"mic": np.zeros(total, np.float32), "system": np.zeros(total, np.float32)}
    turns, voices = [], {}
    for (ch, start, a), (_, voice, _) in zip(placed, CALL):
        i = int(start * SR)
        tracks[ch][i:i + len(a)] += a
        if ch == "system":
            label = voices.setdefault(voice, f"SPEAKER_{len(voices):02d}")
            turns.append({"start": round(start, 2), "end": round(start + len(a) / SR, 2), "speaker": label})

    folder = tmp_path_factory.mktemp("echopad") / "6F1C2A4E-0000-4000-8000-000000000001"
    folder.mkdir()
    write_wav(folder / "microphone.wav", tracks["mic"])
    write_wav(folder / "system.wav", tracks["system"])
    (folder / "transcript.json").write_text("{}")
    (folder / "conversation.json").write_text(json.dumps({
        "app": "Microsoft Teams", "date": START_UTC, "duration": total / SR,
        "exportedFiles": [], "id": folder.name, "speakers": [], "status": {"done": {}},
        "title": "Microsoft Teams call", "wordCount": 0,
    }, indent=2))
    turns_file = folder.parent / "system.turns.json"
    turns_file.write_text(json.dumps(turns))
    return {"folder": folder, "turns": turns_file, "seconds": total / SR}


@pytest.fixture
def config(tmp_path) -> Path:
    """config.toml pointing at a throwaway vault."""
    vault = tmp_path / "vault"
    (vault / "_attachments").mkdir(parents=True)
    path = tmp_path / "config.toml"
    path.write_text(
        f'vault = "{vault}"\n'
        f'glossary_path = "{FIXTURES / "glossary.md"}"\n'
        f'log_book_dir = "{vault / "Log Book"}"\n'
        'your_name = "Aron"\n'
        'claude_model = "sonnet"\n'
    )
    return path
