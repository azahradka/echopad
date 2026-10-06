"""EchoPad conversation folder -> transcript Markdown in the vault, then the Claude hand-off.

    process.py <folder> --config config.toml [--dry-run] [--no-claude]
    process.py --setup

<folder> is what EchoPad writes per recording: microphone.wav, system.wav (absent when
system audio was off), transcript.json, conversation.json, and turns.json (the app's
diarization: mode, track and speaker turns; README "turns.json").

Run it through transcribe.sh (EchoPad's external transcriber), which sets up the environment:
the per-user venv, HF_HOME for the model cache, offline mode, and --config. transcribe.sh also
checks the setup (env and Qwen3) before a run and does `--check` itself.

stdout carries only `stage: <text>` progress lines for EchoPad; everything else goes to stderr.
<folder>/transcript.json is overwritten with our transcript in EchoPad's schema before the hand-off.

--dry-run   write the transcript only: no retention cleanup, no hand-off, WAVs kept, no notification
--no-claude skip the `claude -p "/meeting-note ..."` hand-off (.claude/skills/meeting-note)
--setup     download Qwen3-ASR into HF_HOME (online); exit 0, or 5 on failure (see models.py)
A missing or malformed turns.json is a recording failure (error.txt, exit 1).
"""

import argparse
import fcntl
import json
import os
import subprocess
import sys
import time
import tomllib
import traceback
from datetime import datetime, timedelta
from pathlib import Path
from urllib.parse import quote

import asr
import glossary
import models
from diarize import clean, speech_regions
from merge import echopad_transcript, label_speakers, render

TRACKS = {"call": "system.wav", "in-person": "microphone.wav"}  # turns.json mode -> the track its turns refer to
TERMINAL_NOTIFIER = "/opt/homebrew/bin/terminal-notifier"
CALENDAR_TOOL = "mcp__claude_ai_Microsoft_365__outlook_calendar_search"
NOTES_TOOLS = ["mcp__notes-search__search_notes", "mcp__notes-search__get_note"]  # local read-only MCP server
MAX_TURNS = 30
CONNECTOR = "claude.ai Microsoft 365"


def stage(text: str) -> None:
    """Progress line for EchoPad; the only output on stdout."""
    print(f"stage: {text}", flush=True)


def load_config(path: str | Path) -> dict:
    """config.toml (written by the app; keys in config.example.toml) with its defaults filled in."""
    cfg = tomllib.loads(Path(path).read_text())
    cfg.setdefault("transcripts_dir", str(Path(cfg["vault"]) / "_attachments" / "transcripts"))
    cfg.setdefault("retention_days", 3)
    cfg.setdefault("calendar", True)
    for key in ("vault", "transcripts_dir", "glossary_path", "log_book_dir"):
        cfg[key] = os.path.expanduser(cfg[key])
    if type(cfg["retention_days"]) is not int or cfg["retention_days"] < 0:
        raise ValueError(f"{path}: retention_days must be a whole number of days, got {cfg['retention_days']!r}")
    if type(cfg["calendar"]) is not bool:
        raise ValueError(f"{path}: calendar must be true or false, got {cfg['calendar']!r}")
    return cfg


def frontmatter(text: str) -> dict:
    """Flat `key: value` YAML frontmatter; double-quoted values are JSON strings."""
    if not text.startswith("---\n"):
        return {}
    out = {}
    for line in text.split("---\n", 2)[1].splitlines():
        key, sep, value = line.partition(":")
        if sep:
            value = value.strip()
            out[key.strip()] = json.loads(value) if value.startswith('"') else value
    return out


def cleanup_transcripts(transcripts_dir: Path, now: datetime) -> None:
    """Delete transcripts whose retain_until has passed, unless they say `retain: keep`."""
    for path in transcripts_dir.glob("*.transcript.md"):
        fm = frontmatter(path.read_text())
        if fm.get("retain") == "keep" or "retain_until" not in fm:
            continue
        if datetime.fromisoformat(fm["retain_until"]).astimezone() < now:
            path.unlink()
            print(f"retention: deleted {path.name}", file=sys.stderr)


def read_turns(folder: Path) -> dict:
    """<folder>/turns.json, written by the app before it runs us (README "turns.json"):
    {"mode": "call" | "in-person", "track": "system.wav" | "microphone.wav", "diarizer": str,
     "turns": [{"start", "end", "speaker"}, ...]}. Raises ValueError with the reason if it is not that."""
    path = folder / "turns.json"
    if not path.is_file():
        raise ValueError(f"turns.json missing in {folder}: the app writes it before running the pipeline")
    try:
        spec = json.loads(path.read_text())
    except json.JSONDecodeError as e:
        raise ValueError(f"turns.json is not valid JSON: {e}") from None

    if not isinstance(spec, dict) or spec.get("mode") not in TRACKS:
        raise ValueError(f"turns.json: mode must be one of {list(TRACKS)}")
    if spec.get("track") != TRACKS[spec["mode"]]:
        raise ValueError(f"turns.json: track must be {TRACKS[spec['mode']]} in {spec['mode']} mode, got {spec.get('track')!r}")
    if not isinstance(spec.get("diarizer"), str) or not spec["diarizer"]:
        raise ValueError("turns.json: diarizer must be a non-empty string")
    if not isinstance(spec.get("turns"), list):
        raise ValueError("turns.json: turns must be a list")
    for i, turn in enumerate(spec["turns"]):
        if not (isinstance(turn, dict) and isinstance(turn.get("speaker"), str) and turn["speaker"]
                and all(type(turn.get(k)) in (int, float) for k in ("start", "end")) and 0 <= turn["start"] < turn["end"]):
            raise ValueError(f"turns.json: turn {i} must be {{start, end, speaker}} with 0 <= start < end, got {turn!r}")
    return spec


def transcribe_folder(folder: Path, cfg: dict, spec: dict) -> list[dict]:
    """Turns with text for both tracks; spec is read_turns(). Call mode: the app's turns are the remote
    speakers on system.wav, the mic's speech regions are you. In person: the app's turns on the mic track."""
    rows = glossary.load(cfg["glossary_path"])
    context, table = glossary.context(rows), glossary.replacements(rows)
    track, mic = folder / spec["track"], folder / "microphone.wav"
    turns = clean(spec["turns"])
    done = 0

    def progress(n: int):
        def tick() -> None:
            nonlocal done
            done += 1
            stage(f"transcribing {done}/{n}")
        return tick

    if spec["mode"] == "call":
        remote = label_speakers(turns, "Remote S", "system")
        mine = [{"start": s, "end": e, "speaker": cfg["your_name"], "channel": "mic"}
                for s, e in (speech_regions(mic) if mic.exists() else [])]  # no mic track when mic recording is off
        chunks = asr.chunk(remote + mine)
        tick = progress(len(chunks))
        mic_chunks = [c for c in chunks if c["channel"] == "mic"]
        return (asr.transcribe(track, [c for c in chunks if c["channel"] == "system"], context, table, tick)
                + (asr.transcribe(mic, mic_chunks, context, table, tick) if mic_chunks else []))
    chunks = asr.chunk(label_speakers(turns, "S", "mic"))
    return asr.transcribe(track, chunks, context, table, progress(len(chunks)))


def write_atomic(path: Path, text: str) -> None:
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(text)
    os.replace(tmp, path)


def write_transcript(folder: Path, cfg: dict) -> Path:
    """<folder>/transcript.json for EchoPad (replacing its own), then the vault transcript Markdown."""
    conv = json.loads((folder / "conversation.json").read_text())
    start = datetime.fromisoformat(conv["date"]).astimezone()
    spec = read_turns(folder)
    turns = transcribe_folder(folder, cfg, spec)
    stage("writing transcript")
    write_atomic(folder / "transcript.json",
                 json.dumps(echopad_transcript(turns, cfg["your_name"], conv["duration"]), indent=2, ensure_ascii=False))
    fm = {
        "status": "raw",
        "retain_until": (start + timedelta(days=cfg["retention_days"])).isoformat(timespec="seconds"),
        "mode": spec["mode"],
        "start": start.isoformat(timespec="seconds"),
        "title": json.dumps(conv["title"], ensure_ascii=False),
        "app": json.dumps(conv.get("app"), ensure_ascii=False),
        "duration_s": round(conv["duration"]),
        "asr_model": f"{asr.MODEL_ID}@{asr.MODEL_REV[:7]}",
        "diarization_model": spec["diarizer"],
        "source_folder": json.dumps(str(folder), ensure_ascii=False),
        "glossary": json.dumps(cfg["glossary_path"], ensure_ascii=False),
    }
    if not cfg["calendar"]:
        fm["calendar"] = "off"  # the skill then skips its calendar lookup
    text = ("---\n" + "".join(f"{k}: {v}\n" for k, v in fm.items()) + "---\n\n## Transcript\n\n" + render(turns))
    path = Path(cfg["transcripts_dir"]) / f"{start:%Y-%m-%d %H%M}.transcript.md"
    write_atomic(path, text)
    return path


def run_claude(cmd: list[str], stop_if_pending: bool) -> tuple[dict | None, bool]:
    """(result event, connector was pending). Stops the run at init if the connector is pending."""
    proc = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, text=True)
    result = None
    for line in proc.stdout:
        if not line.startswith("{"):
            continue
        event = json.loads(line)
        if event.get("subtype") == "init":
            status = {s["name"]: s["status"] for s in event.get("mcp_servers", [])}
            if status.get(CONNECTOR) == "pending" and stop_if_pending:
                proc.kill()
                proc.wait()
                return None, True
        elif event.get("type") == "result":
            result = event
    proc.wait()
    if proc.returncode != 0 or result is None or result.get("is_error"):
        reason = result.get("result") if result else "no result event"
        raise RuntimeError(f"claude -p failed (exit {proc.returncode}): {reason}")
    return result, False


def allowed_tools(vault: str, calendar: bool = True) -> list[str]:
    """dontAsk allowlist. `//` makes a rule path absolute (a single `/` is relative to the project);
    Edit rules also cover Write. Each rule is one argv item, so spaces in paths are fine."""
    v = "//" + str(vault).strip("/")
    return [*([CALENDAR_TOOL] if calendar else []), *NOTES_TOOLS,
            f"Read({v}/**)", f"Edit({v}/Log Book/**)", f"Edit({v}/_attachments/transcripts/**)"]


def claude_handoff(transcript: Path, model: str, vault: str, calendar: bool = True, claude: str = "claude") -> dict:
    """claude -p "/meeting-note <transcript>" headless (spike-headless-calendar.md, README "Hand-off").
    With the calendar on, retries once if the M365 connector is still `pending` at init.
    A `Not logged in` exit raises.
    The skill must leave the transcript at `status: processed` (or `delete` for `retain: none`,
    which is deleted here); anything else is a failure."""
    cmd = [claude, "-p", f"/meeting-note {transcript}",  # the prompt must directly follow -p
           "--model", model, "--output-format", "stream-json", "--verbose", "--max-turns", str(MAX_TURNS),
           "--permission-mode", "dontAsk", "--tools", "Read,Edit,Write",  # no Bash: dontAsk still runs read-only commands
           "--allowedTools", *allowed_tools(vault, calendar)]
    result, pending = run_claude(cmd, stop_if_pending=calendar)
    if pending:
        print("claude: M365 connector pending, retrying once", file=sys.stderr)
        time.sleep(5)
        result, _ = run_claude(cmd, stop_if_pending=False)
    status = frontmatter(transcript.read_text()).get("status")
    if status == "delete":
        transcript.unlink()
        print(f"retain: none, deleted {transcript.name}", file=sys.stderr)
    elif status != "processed":
        raise RuntimeError(f"/meeting-note did not finish: transcript status is {status!r}")
    print(f"claude: {result.get('num_turns')} turns, {result.get('duration_ms', 0) / 1000:.0f} s: {result.get('result')}",
          file=sys.stderr)
    return result


def notify(title: str, message: str, open_path: Path | None = None) -> None:
    if Path(TERMINAL_NOTIFIER).exists():
        cmd = [TERMINAL_NOTIFIER, "-title", title, "-message", message]
        if open_path:
            cmd += ["-open", "obsidian://open?path=" + quote(str(open_path), safe="")]
    else:
        cmd = ["osascript", "-e", "on run argv", "-e",
               "display notification (item 1 of argv) with title (item 2 of argv)", "-e", "end run", message, title]
    subprocess.run(cmd, check=True)


def process(folder: Path, cfg: dict, args: argparse.Namespace) -> int:
    error = folder / "error.txt"
    error.unlink(missing_ok=True)  # a rerun (EchoPad "Transcribe again" or by hand) is always intentional
    if not args.dry_run:
        cleanup_transcripts(Path(cfg["transcripts_dir"]), datetime.now().astimezone())

    try:
        path = write_transcript(folder, cfg)
        print(f"wrote {path}", file=sys.stderr)
        note = None
        if not (args.dry_run or args.no_claude):
            stage("drafting note")
            reply = claude_handoff(path, cfg["claude_model"], cfg["vault"], cfg["calendar"]).get("result") or ""
            note = Path(reply.strip().splitlines()[-1].strip("` ")) if reply.strip() else None  # the skill replies with the note path
    except Exception as e:
        if args.dry_run:
            raise
        first = f"{type(e).__name__}: {e}".splitlines()[0]
        error.write_text(f"{first}\n\n{traceback.format_exc()}")
        traceback.print_exc()
        print(first, file=sys.stderr)  # last stderr line = the reason
        notify("Notetaker failed", first)
        return 1

    if args.dry_run:
        stage("done")
        return 0
    error.unlink(missing_ok=True)
    for name in ("microphone.wav", "system.wav"):
        (folder / name).unlink(missing_ok=True)
    if note and note.is_file():
        notify("Notetaker", f"Draft note: {note.stem}", note)
    else:
        notify("Notetaker", f"Transcript ready: {path.stem}", path if path.exists() else None)
    stage("done")
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("folder", nargs="?")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--no-claude", action="store_true")
    ap.add_argument("--config")
    ap.add_argument("--setup", action="store_true")
    args = ap.parse_args(argv)
    if args.setup:
        return models.setup()
    if not (args.folder and args.config):
        ap.error("<folder> and --config are required (or --setup)")
    cfg = load_config(args.config)
    transcripts_dir = Path(cfg["transcripts_dir"])
    transcripts_dir.mkdir(parents=True, exist_ok=True)
    with open(transcripts_dir / ".pipeline.lock", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)  # one recording at a time; later invocations wait here
        return process(Path(args.folder).resolve(), cfg, args)


if __name__ == "__main__":
    sys.exit(main())
