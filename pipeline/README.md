# Notetaker pipeline

Turns an EchoPad recording folder into a transcript note in the vault
(`<transcripts_dir>/<YYYY-MM-DD HHMM>.transcript.md`) and into EchoPad's own `transcript.json`,
then hands it to Claude. EchoPad (our fork) runs it as its external transcriber, after its own
diarizer (FluidAudio's community-1 port) has written the speaker turns to `<folder>/turns.json`.
Design: `../../../PLAN.md` section 2 (in the Notetaker repo). Phase 0 spike results: `spike-qwen3.md` there.

| File | Does |
|---|---|
| `transcribe.sh` | What EchoPad runs: `transcribe.sh <folder>`, `--check`, `--setup` (per-user layout, clean env, logging) |
| `process.py` | Entry point: read `turns.json`, ASR, merge, write, hand-off, cleanup, notify; `--setup` downloads Qwen3 |
| `models.py` | The Qwen3 download for `--setup`, with `stage:` progress |
| `diarize.py` | `speech_regions(wav)` (energy gate for the mic track), `clean(turns)` (folds stray short labels) |
| `asr.py` | `transcribe(wav, chunks, context)` (Qwen3-ASR-1.7B bf16 via mlx-audio) |
| `glossary.py` | Reads the glossary table; builds the ASR context and the alias → term table |
| `merge.py` | Speaker labels, the `[hh:mm:ss] **Speaker:** text` body, EchoPad's `transcript.json` |
| `.claude/skills/meeting-note/` | The `/meeting-note` skill the hand-off runs |

## Per-user layout

This directory is **read-only at runtime**: it will ship inside the signed app
(`Contents/Resources/pipeline/`, with a pinned uv at `bin/uv`). Nothing is written next to the
sources (no `.venv`, no caches, no lockfile changes; `PYTHONDONTWRITEBYTECODE=1`). Everything per user
lives under `BASE` = `$ECHOPAD_DATA_DIR`, else `~/Library/Application Support/EchoPad`:

| Path | What | Set by `transcribe.sh` as |
|---|---|---|
| `config.toml` | Settings, written by the app (*Configure* below) | `--config` (`NOTETAKER_CONFIG` overrides the path) |
| `pipeline-env/` | The Python venv, from `uv.lock` | `UV_PROJECT_ENVIRONMENT` |
| `models/` | Hugging Face cache with Qwen3-ASR | `HF_HOME` |
| `uv-cache/` | uv's package cache | `UV_CACHE_DIR` |
| `python/` | uv-managed CPython (`.python-version`, 3.12.11) | `UV_PYTHON_INSTALL_DIR` (`UV_PYTHON_PREFERENCE=only-managed`) |
| `pipeline.log` | stdout and stderr of every run and `--setup` | |

`transcribe.sh` uses `<this dir>/bin/uv` if it exists, else `uv` from PATH, and runs everything as
`uv run --frozen --no-sync --project <this dir> process.py ...` under
`env -i HOME PATH <the variables above> HF_HUB_DISABLE_TELEMETRY=1` (PATH = `~/.local/bin`, Homebrew,
system), plus `ECHOPAD_DATA_DIR` if set, so a run from EchoPad and one from a terminal behave the same.
Runs are offline (`UV_OFFLINE=1`, `HF_HUB_OFFLINE=1`); only `--setup` goes online.

Measured 2026-10-05: `pipeline-env/` 411 MB, `python/` 49 MB, `uv-cache/` 413 MB (APFS clones of the
same files, so little extra disk), `models/` 4.1 GB. `--setup` takes about 15 s plus the model download.

## Contract with the app

| Command | stdout | Exit |
|---|---|---|
| `transcribe.sh --check` | `setup: ok` or `setup: missing env`, `setup: missing qwen3`, `setup: missing both` | 0 |
| `transcribe.sh --setup` | `stage: creating python environment`, then if Qwen3 is missing `stage: downloading Qwen3-ASR 1.2/4.1 GB` every 2 s and `stage: downloaded Qwen3-ASR`, then `stage: done` | 0 done, 5 failed (reason = last stderr line) |
| `transcribe.sh <folder> [options]` | `stage: transcribing <i>/<n>` per ASR chunk, `stage: writing transcript`, `stage: drafting note` (the hand-off), `stage: done` | 0 done, 1 failed (`error.txt`, reason = last stderr line) |
| same, env or Qwen3 missing | `needs: setup` | 6, before any work: no `error.txt`, no notification |

- **`--check`** never goes online. The env counts as present when `pipeline-env/bin/python` exists and
  `uv sync --frozen --no-dev --inexact --check` says it matches `uv.lock` (so an app update that changes
  the lockfile reads as `missing env`). Qwen3 counts as present when its pinned snapshot holds all
  nine model files; huggingface_hub only links a file there once it is fully downloaded, so a
  half-finished download counts as missing.
- **`--setup`** runs `uv sync --frozen --no-dev` (installing the pinned Python under `python/` if
  needed), then downloads Qwen3 with `huggingface_hub.snapshot_download` at the pinned revision if it
  is missing (no token; the model is not gated), then checks both again. It is safe to rerun.
- Everything except the lines above goes to stderr. stdout and stderr stay separate for EchoPad and
  are both appended to `pipeline.log`.
- **`<folder>/transcript.json`** is replaced with our transcript in EchoPad's schema (ScribeKit
  `Transcript`, below) at `writing transcript`, before the hand-off, so EchoPad can show it even if
  the hand-off fails.

### `turns.json`

The app writes `<folder>/turns.json` before running the pipeline:

    {"mode": "call" | "in-person",
     "track": "system.wav" | "microphone.wav",
     "diarizer": "fluidaudio-community-1",
     "turns": [{"start": 12.4, "end": 18.9, "speaker": "S1"}, ...]}

- `mode` decides everything; the pipeline does no mode detection of its own. `track` is the file the
  turns refer to and must be `system.wav` for a call and `microphone.wav` in person. Speakers are
  `S1..SN` in order of first appearance; `diarizer` goes into the transcript frontmatter as
  `diarization_model`.
- The turns first go through `clean()`: a label with under 1 s of speech in total, or a segment under
  0.25 s that touches another one, is folded into the neighbouring turn (community-1 produces such
  slivers at speaker changes). A remote speaker who only says one short word is therefore merged
  into the previous speaker.
- **Call:** the turns become `Remote S1..SN` on `system.wav`; the mic track is always you, so its
  speech regions by the energy gate (frame RMS above -45 dBFS, gaps under 0.5 s joined) are labelled
  `your_name` (none when there is no `microphone.wav`). **In person:** the turns become `S1..SN` on `microphone.wav` (Claude works out which is you).
- A missing or malformed `turns.json` (bad JSON, unknown mode, track not matching the mode, empty
  `diarizer`, a turn without numeric `0 <= start < end` and a `speaker`) is a recording failure: `error.txt`,
  exit 1, with the reason, before any ASR. An empty `turns` list is valid.

## Models

| Model | Repo @ pinned revision | Size |
|---|---|---|
| Qwen3-ASR | `mlx-community/Qwen3-ASR-1.7B-bf16` @ `e1f6c26` (`asr.MODEL_REV`, repeated in `transcribe.sh`) | 4.1 GB |

Diarization runs in the app, so this is the only model the pipeline needs.

## Configure

The app writes `BASE/config.toml`; `config.example.toml` lists the keys: `vault`, `transcripts_dir`
(default `<vault>/_attachments/transcripts`), `glossary_path`, `log_book_dir`, `your_name` (the mic
speaker in calls), `claude_model`, `retention_days` (default 3) and `calendar` (default true; false
drops the calendar tool from the hand-off and writes `calendar: off` into the transcript frontmatter,
which tells the skill to skip the lookup).

The glossary file must exist. It needs a table like:

    | term | aliases (misheard as) | asr (yes/no) | notes |
    |---|---|---|---|
    | LandMARC | Land Mark, landmark | yes | Cambio product |

The first 80 `asr: yes` terms, in file order, become the ASR context. **Every alias is replaced
by its term after ASR** (whole word, any case), so only list aliases that are always wrong.
A header-only table is fine (no context, no replacements).

## Run

    ./transcribe.sh --setup                                   # once per user (online)
    ./transcribe.sh "<EchoPad library>/<id>"                  # full run
    ./transcribe.sh <folder> --no-claude                      # skip the claude -p hand-off
    ./transcribe.sh <folder> --dry-run                        # transcript only
    NOTETAKER_CONFIG=/tmp/config.toml ./transcribe.sh <folder>   # another config

Rerunning a failed folder clears `error.txt` and tries again.

- **`--dry-run`:** writes the transcript only. No retention cleanup, no hand-off, WAVs kept,
  no notification, and errors are raised instead of written to `error.txt`.
- **Success:** deletes `microphone.wav` and `system.wav` from the conversation folder, posts a
  notification, exits 0. **Failure:** writes `error.txt` (first line = the error, then the traceback),
  keeps the WAVs, posts a notification with the first line, exits 1 with the traceback and then the
  first line again as the last stderr line.
- **Queue:** an `flock` on `<transcripts_dir>/.pipeline.lock`; concurrent runs wait their turn.
- **Retention:** each run first deletes `*.transcript.md` in `transcripts_dir` whose
  `retain_until` (start + `retention_days`) has passed, unless the frontmatter says `retain: keep`.
- **Hand-off:** see below.

## Hand-off to Claude

`claude -p "/meeting-note <transcript>"` runs the project skill `.claude/skills/meeting-note/SKILL.md`
(found because `transcribe.sh` runs with this directory as cwd). Flags: Sonnet, stream-json,
`--max-turns 30`, `--permission-mode dontAsk`, `--tools Read,Edit,Write`, and this `--allowedTools` list, one argv item per rule
(`<vault>` = the `vault` config value without its leading `/`):

    mcp__claude_ai_Microsoft_365__outlook_calendar_search   (left out when calendar = false)
    mcp__notes-search__search_notes
    mcp__notes-search__get_note
    Read(//<vault>/**)
    Edit(//<vault>/Log Book/**)
    Edit(//<vault>/_attachments/transcripts/**)

Permission-rule syntax, verified 2026-10-05 against CLI 2.1.289 with a stub vault:
- `//path` is an absolute path. A single leading `/` is relative to the project, so `Read(/Users/...)`
  matched nothing and every read and write was denied.
- An `Edit(...)` rule also allows `Write` (new files) under that path. No separate `Write` rule is needed.
- Paths with spaces (`Log Book`) work, as long as each rule is its own argv item.
- With `//` rules: Read inside the vault was allowed, Read outside it was denied, Write to `Log Book/`
  and Edit in `_attachments/transcripts/` were allowed, and Write to `Admin/` or outside the vault was
  denied (all listed in `permission_denials`).
- `--tools ""` (from the spike) would remove Read and Edit, so it is replaced by `--tools Read,Edit,Write`.
  Without any `--tools`, `dontAsk` still auto-allows read-only Bash (`ls`, `cat`) and Read inside the
  cwd (`pipeline/`), and Glob/Grep are absent anyway. With it, the built-in tools are exactly
  Read/Edit/Write; MCP tools are unaffected.
- `notes-search` is often still `pending` at init. It is added once connected (seen with
  `--tools Read,Edit,Write`, where ToolSearch is gone); without `--tools` the model loaded it with
  ToolSearch. The skill skips the context step if the tools never appear.

The skill reads the transcript and glossary, makes one calendar call (start ± 1 h), reads 2–6 related
notes through `notes-search`, writes the note to `Log Book/<YYYY>/<MM Month>/`, appends `## Corrections`
to the transcript and sets its `status`. Afterwards `process.py` re-reads the transcript frontmatter:
`status: processed` is success, `status: delete` (the skill's answer to `retain: none`, since it cannot
delete files) makes `process.py` delete the transcript, and anything else is a failure. The skill
replies with the note's path, which the success notification opens.

With the calendar on, if the init event shows the M365 connector `pending`, the run is stopped and retried once. A non-zero
exit or an error result (for example `Not logged in`) is a failure.

Measured on the 70 s synthetic call (2026-10-05): 9–14 turns, 23–39 s and $0.18–0.26 per
hand-off. A full `process.py` run including ASR took 61 s.

**Notifications:** `terminal-notifier` is not installed, so the pipeline uses
`osascript -e 'display notification ...'` (no click action; macOS may ask once to allow
notifications for Script Editor). After `brew install terminal-notifier` it is used instead,
and clicking the notification opens the draft note (or the transcript) in Obsidian (`obsidian://open?path=...`).

## Wire into EchoPad

Until the bundle (PLAN.md Phase B) ships it inside the app:

1. Put the settings in `~/Library/Application Support/EchoPad/config.toml` (start from
   `config.example.toml`). Create the glossary note.
2. EchoPad → Settings → Transcription → **External command** → this directory's `transcribe.sh`.
   The app runs `--check` and, if needed, `--setup`.
3. Keep audio in EchoPad's library (*Keep audio of the last* 500); the pipeline deletes the WAVs
   itself after success.

**`transcript.json`** matches ScribeKit's `Transcript` (`vendor/ScribeKit/Sources/ScribeKit/Transcript.swift`,
pinned rev `2ae61e8`), which EchoPad decodes with a plain `JSONDecoder`:

    {"segments": [{"speakerID": "remote-s1", "start": 1.0, "end": 7.38, "text": "...", "words": []}, ...],
     "speakers": [{"id": "local", "name": "Aron", "isLocal": true},
                  {"id": "remote-s1", "name": "Remote S1", "isLocal": false}, ...],
     "language": "en", "duration": 69.17}

Segments are the same merged turns as the Markdown. Speaker ids follow ScribeKit: `local` for
`your_name` on the mic, `remote-s1..` for the system track, `s1..` in person (none is local; Claude
works out which is you). `words` is required but may be empty; we only have turn timings, and
EchoPad's subtitle export falls back to the segment times. Verified by decoding a pipeline output
with that exact `Transcript.swift` compiled by `swiftc`.

## Tests

Against the env and model in `BASE` (run `--setup` first; this adds pytest to `pipeline-env`, and the
next `--setup` removes it again):

    BASE="${ECHOPAD_DATA_DIR:-$HOME/Library/Application Support/EchoPad}"
    UV_PROJECT_ENVIRONMENT="$BASE/pipeline-env" UV_CACHE_DIR="$BASE/uv-cache" UV_PYTHON_INSTALL_DIR="$BASE/python" \
        UV_PYTHON_PREFERENCE=only-managed uv run --frozen pytest -q

About 65 s. The end-to-end tests render a fake 70 s call with `say` (two voices on `system.wav`,
one on `microphone.wav`, 2 s of overlap), write the `turns.json` the app would, and run
`process.main(... --dry-run ...)` against a temporary vault, loading the ASR model once; they check the
stdout stage lines, the `transcript.json` written back into the folder, the frontmatter (including
`retention_days` and `calendar = false`), and `turns.json` validation. The hand-off is tested against a
stub `claude` that sets the transcript status like the skill. `tests/test_transcribe_sh.py` runs
`transcribe.sh` itself: `--check` and the exit-6 guard against an empty data dir, and a full dry run
through the real env and model.
