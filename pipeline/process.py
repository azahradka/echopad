"""EchoPad conversation folder -> transcript Markdown in the vault, then the Claude hand-off.

    uv run process.py <folder> [--dry-run] [--no-claude] [--turns turns.json] [--config config.toml]
    uv run process.py --check | --setup

<folder> is what EchoPad writes per recording: microphone.wav, system.wav (absent when
system audio was off), transcript.json, conversation.json. transcribe.sh calls this (EchoPad's
external transcription command, and on_save.sh for the post-save hook).

stdout carries only `stage: <text>` progress lines (and `needs: ...` / `models: ...`, below) for
EchoPad; everything else goes to stderr. <folder>/transcript.json is overwritten with our transcript
in EchoPad's schema before the hand-off.

--dry-run   write the transcript only: no retention cleanup, no hand-off, WAVs kept, no notification
--no-claude skip the `claude -p "/meeting-note ..."` hand-off (../.claude/skills/meeting-note)
--turns     use this [{"start", "end", "speaker"}] list instead of pyannote for the diarized track
--check     print `models: ok` or `models: missing qwen3|pyannote|both`; no network, exit 0
--setup     download missing models (HF_TOKEN from the environment for pyannote); exit 0, or
            3 `needs: hf_token`, 4 `needs: gate <url>`, 5 other failure (see models.py)
A run that finds models missing prints `needs: models` and exits 6 before any audio work.
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

ROOT = Path(__file__).parent
# One model cache for runs, --check and --setup, fixed before anything imports huggingface_hub
# (which reads these once). Runs are offline; --setup is the only thing that downloads.
os.environ["HF_HOME"] = str(ROOT / ".hf-cache")
if "--setup" in sys.argv[1:]:
    os.environ["HF_HUB_OFFLINE"] = "0"
else:
    os.environ.setdefault("HF_HUB_OFFLINE", "1")

import diarize  # first: sets the pyannote env vars before anything imports it
import asr
import glossary
import models
from merge import echopad_transcript, label_speakers, render

RETAIN = timedelta(days=3)
MIN_SPEECH_S = 1.0  # system.wav with less gated speech than this means in-person mode
IN_PERSON_SPEAKERS = (2, 4)
TERMINAL_NOTIFIER = "/opt/homebrew/bin/terminal-notifier"
CALENDAR_TOOL = "mcp__claude_ai_Microsoft_365__outlook_calendar_search"
NOTES_TOOLS = ["mcp__notes-search__search_notes", "mcp__notes-search__get_note"]  # local read-only MCP server
MAX_TURNS = 30
CONNECTOR = "claude.ai Microsoft 365"


def stage(text: str) -> None:
    """Progress line for EchoPad; the only output on stdout besides needs:/models:."""
    print(f"stage: {text}", flush=True)


def load_config(path: str | Path | None = None) -> dict:
    cfg = tomllib.loads(Path(path or ROOT / "config.toml").read_text())
    cfg.setdefault("transcripts_dir", str(Path(cfg["vault"]) / "_attachments" / "transcripts"))
    for key in ("vault", "transcripts_dir", "glossary_path", "log_book_dir"):
        cfg[key] = os.path.expanduser(cfg[key])
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


def has_speech(wav: Path) -> bool:
    return sum(e - s for s, e in diarize.speech_regions(wav)) >= MIN_SPEECH_S


def transcribe_folder(folder: Path, cfg: dict, turns_override: list[dict] | None) -> tuple[str, list[dict]]:
    """(mode, turns with text) for both tracks."""
    rows = glossary.load(cfg["glossary_path"])
    context, table = glossary.context(rows), glossary.replacements(rows)
    mic, system = folder / "microphone.wav", folder / "system.wav"
    done = 0

    def progress(n: int):
        def tick() -> None:
            nonlocal done
            done += 1
            stage(f"transcribing {done}/{n}")
        return tick

    stage("detecting mode")
    if system.exists() and has_speech(system):
        stage("diarizing")
        remote = label_speakers(turns_override if turns_override is not None else diarize.diarize(system),
                                "Remote S", "system")
        mine = [{"start": s, "end": e, "speaker": cfg["your_name"], "channel": "mic"}
                for s, e in diarize.speech_regions(mic)]
        chunks = asr.chunk(remote + mine)
        tick = progress(len(chunks))
        return "call", (asr.transcribe(system, [c for c in chunks if c["channel"] == "system"], context, table, tick)
                        + asr.transcribe(mic, [c for c in chunks if c["channel"] == "mic"], context, table, tick))

    stage("diarizing")
    local = turns_override if turns_override is not None else diarize.diarize(mic, IN_PERSON_SPEAKERS)
    chunks = asr.chunk(label_speakers(local, "S", "mic"))
    return "in-person", asr.transcribe(mic, chunks, context, table, progress(len(chunks)))


def write_atomic(path: Path, text: str) -> None:
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(text)
    os.replace(tmp, path)


def write_transcript(folder: Path, cfg: dict, turns_override: list[dict] | None, diarization_model: str) -> Path:
    """<folder>/transcript.json for EchoPad (replacing its own), then the vault transcript Markdown."""
    conv = json.loads((folder / "conversation.json").read_text())
    start = datetime.fromisoformat(conv["date"]).astimezone()
    mode, turns = transcribe_folder(folder, cfg, turns_override)
    stage("writing transcript")
    write_atomic(folder / "transcript.json",
                 json.dumps(echopad_transcript(turns, cfg["your_name"], conv["duration"]), indent=2, ensure_ascii=False))
    fm = {
        "status": "raw",
        "retain_until": (start + RETAIN).isoformat(timespec="seconds"),
        "mode": mode,
        "start": start.isoformat(timespec="seconds"),
        "title": json.dumps(conv["title"], ensure_ascii=False),
        "app": json.dumps(conv.get("app"), ensure_ascii=False),
        "duration_s": round(conv["duration"]),
        "asr_model": f"{asr.MODEL_ID}@{asr.MODEL_REV[:7]}",
        "diarization_model": diarization_model,
        "source_folder": json.dumps(str(folder), ensure_ascii=False),
        "glossary": json.dumps(cfg["glossary_path"], ensure_ascii=False),
    }
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


def allowed_tools(vault: str) -> list[str]:
    """dontAsk allowlist. `//` makes a rule path absolute (a single `/` is relative to the project);
    Edit rules also cover Write. Each rule is one argv item, so spaces in paths are fine."""
    v = "//" + str(vault).strip("/")
    return [CALENDAR_TOOL, *NOTES_TOOLS, f"Read({v}/**)", f"Edit({v}/Log Book/**)", f"Edit({v}/_attachments/transcripts/**)"]


def claude_handoff(transcript: Path, model: str, vault: str, claude: str = "claude") -> dict:
    """claude -p "/meeting-note <transcript>" headless (spike-headless-calendar.md, README "Hand-off").
    Retries once if the M365 connector is still `pending` at init. A `Not logged in` exit raises.
    The skill must leave the transcript at `status: processed` (or `delete` for `retain: none`,
    which is deleted here); anything else is a failure."""
    cmd = [claude, "-p", f"/meeting-note {transcript}",  # the prompt must directly follow -p
           "--model", model, "--output-format", "stream-json", "--verbose", "--max-turns", str(MAX_TURNS),
           "--permission-mode", "dontAsk", "--tools", "Read,Edit,Write",  # no Bash: dontAsk still runs read-only commands
           "--allowedTools", *allowed_tools(vault)]
    result, pending = run_claude(cmd, stop_if_pending=True)
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
    need = models.missing(need_pyannote=not args.turns)
    if need:  # before any audio work, so EchoPad can run --setup instead (not a recording failure: no error.txt)
        print("needs: models", flush=True)
        print(f"{models.describe(need)} in {models.constants.HF_HUB_CACHE}; run transcribe.sh --setup", file=sys.stderr)
        return 6
    if not args.dry_run:
        cleanup_transcripts(Path(cfg["transcripts_dir"]), datetime.now().astimezone())

    turns = json.loads(Path(args.turns).read_text()) if args.turns else None
    diarization_model = f"turns override ({Path(args.turns).name})" if args.turns else f"{diarize.MODEL_ID}@{diarize.MODEL_REV[:7]}"
    try:
        path = write_transcript(folder, cfg, turns, diarization_model)
        print(f"wrote {path}", file=sys.stderr)
        note = None
        if not (args.dry_run or args.no_claude):
            stage("drafting note")
            reply = claude_handoff(path, cfg["claude_model"], cfg["vault"]).get("result") or ""
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
    ap.add_argument("--turns")
    ap.add_argument("--config")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--setup", action="store_true")
    args = ap.parse_args(argv)
    if args.check:
        print(models.describe(models.missing()), flush=True)
        return 0
    if args.setup:
        return models.setup(os.environ.get("HF_TOKEN"))  # the token comes only from the environment
    if not args.folder:
        ap.error("folder is required (or --check / --setup)")
    cfg = load_config(args.config)
    transcripts_dir = Path(cfg["transcripts_dir"])
    transcripts_dir.mkdir(exist_ok=True)
    with open(transcripts_dir / ".pipeline.lock", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)  # one recording at a time; later invocations wait here
        return process(Path(args.folder).resolve(), cfg, args)


if __name__ == "__main__":
    sys.exit(main())
