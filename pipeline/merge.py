"""Turns from both tracks -> transcript body.

Each turn is {"start", "end", "speaker", "channel", "text"}; channel is "mic" or "system".
Consecutive turns of the same speaker are merged, never across channels.
echopad_transcript() is the same merged turns as EchoPad's transcript.json (ScribeKit `Transcript`).
"""


def label_speakers(turns: list[dict], prefix: str, channel: str) -> list[dict]:
    """Rename raw diarization labels to prefix + 1..N in order of first appearance."""
    names: dict[str, str] = {}
    out = []
    for t in sorted(turns, key=lambda t: t["start"]):
        name = names.setdefault(t["speaker"], f"{prefix}{len(names) + 1}")
        out.append({**t, "speaker": name, "channel": channel})
    return out


def merge_turns(turns: list[dict]) -> list[dict]:
    out: list[dict] = []
    for t in sorted(turns, key=lambda t: t["start"]):
        prev = out[-1] if out else None
        if prev and prev["speaker"] == t["speaker"] and prev["channel"] == t["channel"]:
            prev["end"] = max(prev["end"], t["end"])
            prev["text"] = f"{prev['text']} {t['text']}"
        else:
            out.append(dict(t))
    return out


def timestamp(seconds: float) -> str:
    s = int(seconds)
    return f"{s // 3600:02d}:{s % 3600 // 60:02d}:{s % 60:02d}"


def render(turns: list[dict]) -> str:
    return "\n\n".join(f"[{timestamp(t['start'])}] **{t['speaker']}:** {t['text']}" for t in merge_turns(turns)) + "\n"


def speaker_id(turn: dict, your_name: str) -> str:
    """ScribeKit's ids: "local" for you on the mic, "remote-s1".. for the system track, "s1".. in person."""
    if turn["channel"] == "mic" and turn["speaker"] == your_name:
        return "local"
    return turn["speaker"].lower().replace(" ", "-")


def echopad_transcript(turns: list[dict], your_name: str, duration: float, language: str = "en") -> dict:
    """ScribeKit's `Transcript` (vendor/ScribeKit/Sources/ScribeKit/Transcript.swift), decoded by EchoPad
    from <folder>/transcript.json. Every key is required except `language` and `speakerID`. We have
    turn timings only, so `words` is empty; EchoPad's renderers fall back to the segment's own times."""
    segments = merge_turns(turns)
    speakers: dict[str, dict] = {}
    for t in segments:
        sid = speaker_id(t, your_name)
        speakers.setdefault(sid, {"id": sid, "name": t["speaker"], "isLocal": sid == "local"})
    order = sorted(speakers, key=lambda s: s != "local")  # you first, then by first appearance, like ScribeKit
    return {
        "segments": [{"speakerID": speaker_id(t, your_name), "start": round(t["start"], 3), "end": round(t["end"], 3),
                      "text": t["text"], "words": []} for t in segments],
        "speakers": [speakers[s] for s in order],
        "language": language,
        "duration": duration,
    }
