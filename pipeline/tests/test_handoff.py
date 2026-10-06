"""claude_handoff against a stub `claude` that prints stream-json and sets the transcript status
the way the /meeting-note skill would; never the real CLI."""
import json
import shlex
import sys

import pytest

import process

STUB = """import json, sys, time
from pathlib import Path
state = Path({state!r})
n = int(state.read_text()) + 1 if state.exists() else 1
state.write_text(str(n))
Path({argv!r}).write_text(json.dumps(sys.argv[1:]))
mode = {mode!r}
status = "pending" if mode == "pending_once" and n == 1 else "connected"
print(json.dumps({{"type": "system", "subtype": "hook_started"}}), flush=True)
print(json.dumps({{"type": "system", "subtype": "init", "mcp_servers": [{{"name": "claude.ai Microsoft 365", "status": status}}]}}), flush=True)
if mode == "logged_out":
    print(json.dumps({{"type": "result", "subtype": "success", "is_error": True, "result": "Not logged in · Please run /login"}}))
    sys.exit(1)
if status == "pending":
    time.sleep(30)  # the hand-off must kill this run
transcript = Path(sys.argv[2].removeprefix("/meeting-note "))
new = {{"ok": "processed", "retain_none": "delete", "pending_once": "processed"}}.get(mode)
if new:
    transcript.write_text(transcript.read_text().replace("status: raw", "status: " + new))
print(json.dumps({{"type": "result", "subtype": "success", "is_error": False, "result": "done"}}))
"""


@pytest.fixture
def stub(tmp_path, monkeypatch):
    monkeypatch.setattr(process.time, "sleep", lambda s: None)

    def make(mode):
        script = tmp_path / "claude.py"
        script.write_text(STUB.format(state=str(tmp_path / "n"), argv=str(tmp_path / "argv"), mode=mode))
        path = tmp_path / "claude"  # a shell wrapper: a #! line cannot hold a python path with spaces
        path.write_text(f'#!/bin/sh\nexec {shlex.quote(sys.executable)} {shlex.quote(str(script))} "$@"\n')
        path.chmod(0o755)
        return str(path)
    return make


VAULT = "/Users/me/Obsidian Vault/Work"


@pytest.fixture
def transcript(tmp_path):
    path = tmp_path / "x.transcript.md"
    path.write_text("---\nstatus: raw\nmode: call\n---\n\n## Transcript\n")
    return path


def test_success_and_flags(stub, tmp_path, transcript):
    result = process.claude_handoff(transcript, "sonnet", VAULT, claude=stub("ok"))
    assert result["result"] == "done"
    argv = json.loads((tmp_path / "argv").read_text())
    assert argv[:2] == ["-p", f"/meeting-note {transcript}"]
    assert argv[argv.index("--tools") + 1] == "Read,Edit,Write"
    assert argv[argv.index("--permission-mode") + 1] == "dontAsk"
    assert argv[argv.index("--max-turns") + 1] == str(process.MAX_TURNS)
    assert argv[argv.index("--allowedTools") + 1:] == [
        process.CALENDAR_TOOL, "mcp__notes-search__search_notes", "mcp__notes-search__get_note",
        "Read(//Users/me/Obsidian Vault/Work/**)",
        "Edit(//Users/me/Obsidian Vault/Work/Log Book/**)",
        "Edit(//Users/me/Obsidian Vault/Work/_attachments/transcripts/**)",
    ]
    assert process.frontmatter(transcript.read_text())["status"] == "processed"


def test_status_delete_removes_transcript(stub, transcript):
    process.claude_handoff(transcript, "sonnet", VAULT, claude=stub("retain_none"))
    assert not transcript.exists()


def test_unfinished_skill_fails(stub, transcript):
    with pytest.raises(RuntimeError, match="transcript status is 'raw'"):
        process.claude_handoff(transcript, "sonnet", VAULT, claude=stub("skill_gave_up"))
    assert transcript.exists()


def test_pending_connector_retries_once(stub, tmp_path, transcript):
    result = process.claude_handoff(transcript, "sonnet", VAULT, claude=stub("pending_once"))
    assert result["result"] == "done"
    assert (tmp_path / "n").read_text() == "2"


def test_not_logged_in_fails(stub, transcript):
    with pytest.raises(RuntimeError, match="Not logged in"):
        process.claude_handoff(transcript, "sonnet", VAULT, claude=stub("logged_out"))


def test_calendar_off_drops_the_tool_and_the_connector_wait(stub, tmp_path, transcript):
    result = process.claude_handoff(transcript, "sonnet", VAULT, calendar=False, claude=stub("pending_once"))
    assert result["result"] == "done"
    assert (tmp_path / "n").read_text() == "1"  # a pending M365 connector does not matter without the calendar
    argv = json.loads((tmp_path / "argv").read_text())
    assert process.CALENDAR_TOOL not in argv
    assert argv[argv.index("--allowedTools") + 1:][:2] == ["mcp__notes-search__search_notes", "mcp__notes-search__get_note"]
