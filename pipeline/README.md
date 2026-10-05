# Notetaker pipeline

Turns an EchoPad recording folder into a transcript note in the vault
(`<transcripts_dir>/<YYYY-MM-DD HHMM>.transcript.md`) and into EchoPad's own `transcript.json`,
then hands it to Claude. EchoPad (our fork) runs it as its transcriber.
Design: `../PLAN.md` section 2. Phase 0 spike results: `../spike-qwen3.md`.

| File | Does |
|---|---|
| `transcribe.sh` | What EchoPad runs: `transcribe.sh <folder>`, `--check`, `--setup` (clean env, logging) |
| `process.py` | Entry point: mode detection, diarize, ASR, merge, write, hand-off, cleanup, notify |
| `models.py` | `--check` / `--setup`: the two pinned models in `.hf-cache/` |
| `diarize.py` | `diarize(wav)` (pyannote community-1 on MPS), `speech_regions(wav)` (energy gate) |
| `asr.py` | `transcribe(wav, chunks, context)` (Qwen3-ASR-1.7B bf16 via mlx-audio) |
| `glossary.py` | Reads the glossary table; builds the ASR context and the alias → term table |
| `merge.py` | Speaker labels, the `[hh:mm:ss] **Speaker:** text` body, EchoPad's `transcript.json` |
| `on_save.sh` | Fallback: EchoPad post-save hook; finds the folder and runs `transcribe.sh` |

## Install

    cd pipeline
    uv sync

Both models live in the project-local cache `.hf-cache/` and are downloaded once, normally by
EchoPad (see *Models* below). From a terminal:

    ./transcribe.sh --check                    # models: ok | models: missing qwen3|pyannote|both
    HF_TOKEN=hf_... ./transcribe.sh --setup    # token only needed while pyannote is missing

The pipeline then runs offline (`HF_HUB_OFFLINE=1`, `PYANNOTE_METRICS_ENABLED=0`).

## Models

| Model | Repo @ pinned revision | Size | Gated |
|---|---|---|---|
| `qwen3` | `mlx-community/Qwen3-ASR-1.7B-bf16` @ `e1f6c26` (`asr.MODEL_REV`) | 4.1 GB | no |
| `pyannote` | `pyannote/speaker-diarization-community-1` @ `3533c8c` (`diarize.MODEL_REV`) | 34 MB | yes: accept the conditions at https://huggingface.co/pyannote/speaker-diarization-community-1 |

One cache for everything: `process.py` sets `HF_HOME=<pipeline>/.hf-cache` before anything imports
`huggingface_hub` (and `transcribe.sh` passes the same), so `--check`, `--setup` and real runs look
in the same place. A model counts as present when its pinned snapshot holds all its weight and
config files (`models.MODELS`); a half-finished download counts as missing.

- **`--check`**: cache only, no network. Prints `models: ok` or `models: missing qwen3|pyannote|both`,
  exit 0 either way.
- **`--setup`**: downloads what is missing with `huggingface_hub.snapshot_download` at the pinned
  revisions, printing `stage: downloading Qwen3-ASR 1.2/4.1 GB` every 2 s and `stage: done` at the end.
  It is the only online mode (`HF_HUB_OFFLINE=0`). Qwen3 is fetched without a token. If pyannote is
  missing and there is no token, it stops before downloading anything, so the app asks once and the
  whole download then runs unattended.

| Exit | stdout | Meaning |
|---|---|---|
| 0 | `stage: done` | All models present |
| 3 | `needs: hf_token` | pyannote is missing and `HF_TOKEN` is not set |
| 4 | `needs: gate https://huggingface.co/pyannote/speaker-diarization-community-1` | 401/403: token refused or conditions not accepted (HTTP error text on stderr) |
| 5 | | Network or other failure (reason on stderr) |

**The token is only ever passed in the environment** (`HF_TOKEN`, which `transcribe.sh` lets
through `env -i` for `--setup` only). Nothing here writes it to disk, puts it in argv, or prints it;
`huggingface_hub` is never asked to log in.

A normal run checks the models first: if any are missing it prints `needs: models`, exits 6 and
touches nothing (no `error.txt`, no notification), so EchoPad can run `--setup` and then retry.
With `--turns`, pyannote is not required.

## Configure

    cp config.example.toml config.toml

`config.toml` sits next to `process.py` (or pass `--config <path>`). Keys: `vault`,
`transcripts_dir` (default `<vault>/_attachments/transcripts`), `glossary_path`, `log_book_dir`,
`your_name` (the mic speaker in calls), `claude_model`.

The glossary file must exist. It needs a table like:

    | term | aliases (misheard as) | asr (yes/no) | notes |
    |---|---|---|---|
    | LandMARC | Land Mark, landmark | yes | Cambio product |

The first 80 `asr: yes` terms, in file order, become the ASR context. **Every alias is replaced
by its term after ASR** (whole word, any case), so only list aliases that are always wrong.
A header-only table is fine (no context, no replacements).

## Run

    uv run process.py "<EchoPad library>/<id>"                  # full run
    uv run process.py <folder> --no-claude                       # skip the claude -p hand-off
    uv run process.py <folder> --dry-run --turns turns.json      # transcript only, no pyannote
    uv run process.py <folder>                                   # rerunning a failed folder clears error.txt and tries again
    uv run process.py --check | --setup                          # models (above)

`transcribe.sh <folder> [options]` runs the same thing the way EchoPad does (below).

- **stdout** carries only progress lines, flushed, for EchoPad: `stage: detecting mode`,
  `stage: diarizing`, `stage: transcribing <i>/<n>` (per ASR chunk), `stage: writing transcript`,
  `stage: drafting note` (the hand-off), `stage: done`. Everything else goes to stderr.
- **`<folder>/transcript.json`** is replaced with our transcript in EchoPad's schema (ScribeKit
  `Transcript`, below) at `writing transcript`, before the hand-off, so EchoPad can show it even if
  the hand-off fails.

- **Mode:** in-person when `system.wav` is missing or has under 1 s of speech by the energy gate.
  Call mode diarizes `system.wav` into `Remote S1..SN` and labels the mic's speech regions
  `your_name`. In-person mode diarizes `microphone.wav` (2–4 speakers) into `S1..SN`.
- **`--turns file.json`:** `[{"start": 1.0, "end": 6.2, "speaker": "SPEAKER_00"}, ...]` replaces
  pyannote for the track that would be diarized. The frontmatter then says `diarization_model:
  turns override (file.json)`.
- **`--dry-run`:** writes the transcript only. No retention cleanup, no hand-off, WAVs kept,
  no notification, and errors are raised instead of written to `error.txt`.
- **Success:** deletes `microphone.wav` and `system.wav` from the conversation folder, posts a
  notification, exits 0. **Failure:** writes `error.txt` (first line = the error, then the traceback),
  keeps the WAVs, posts a notification with the first line, exits 1 with the traceback and then the
- **Queue:** an `flock` on `<transcripts_dir>/.pipeline.lock`; concurrent runs wait their turn.
- **Retention:** each run first deletes `*.transcript.md` in `transcripts_dir` whose
  `retain_until` has passed, unless the frontmatter says `retain: keep`.
- **Hand-off:** see below.

## Hand-off to Claude

`claude -p "/meeting-note <transcript>"` runs the project skill `../.claude/skills/meeting-note/SKILL.md`
(found because the CLI runs with `pipeline/` as cwd, inside this project). Flags: Sonnet, stream-json,
`--max-turns 30`, `--permission-mode dontAsk`, `--tools Read,Edit,Write`, and this `--allowedTools` list, one argv item per rule
(`<vault>` = the `vault` config value without its leading `/`):

    mcp__claude_ai_Microsoft_365__outlook_calendar_search
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

If the init event shows the M365 connector `pending`, the run is stopped and retried once. A non-zero
exit or an error result (for example `Not logged in`) is a failure.

Measured on the 70 s synthetic call (2026-10-05): 9–14 turns, 23–39 s and $0.18–0.26 per
hand-off. A full `process.py` run including ASR took 61 s.

**Notifications:** `terminal-notifier` is not installed, so the pipeline uses
`osascript -e 'display notification ...'` (no click action; macOS may ask once to allow
notifications for Script Editor). After `brew install terminal-notifier` it is used instead,
and clicking the notification opens the draft note (or the transcript) in Obsidian (`obsidian://open?path=...`).

## Wire into EchoPad

1. `cp config.example.toml config.toml` and check the paths. Create the glossary note.
2. EchoPad → Settings → Transcription → **External command** →
   `/Users/azahradka/Documents/Notetaker/pipeline/transcribe.sh`.
3. Turn **off** the destination's *After saving → Run a script* action (the fallback below), or each
   recording is processed twice and the second run fails once the WAVs are gone.
4. Keep audio in EchoPad's library (*Keep audio of the last* 500); the pipeline deletes the WAVs
   itself after success.

EchoPad runs `transcribe.sh <conversation folder>` (the folder holds `microphone.wav`, maybe
`system.wav`, and `conversation.json`) and also `transcribe.sh --check` / `--setup` for the models.
The script `cd`s here and runs `uv run process.py <folder>` under
`env -i HOME PATH HF_HOME PYANNOTE_METRICS_ENABLED=0 HF_HUB_OFFLINE=1 HF_HUB_DISABLE_TELEMETRY=1`
(PATH = `~/.local/bin`, Homebrew, system), plus `ECHOPAD_DATA_DIR` if set, so a run from EchoPad
and one from a terminal behave the same. stdout and stderr stay separate for EchoPad and are both
appended to `<transcripts_dir>/pipeline.log`. The exit code is `process.py`'s: 0 success, 1 failure
(reason on stderr), 6 models missing.

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

### Fallback: built-in transcription plus post-save hook

If EchoPad's own transcription is used instead, run the pipeline after it saves:
EchoPad → Settings → Destinations → your destination → *After saving* → **Run a script** →
`/Users/azahradka/Documents/Notetaker/pipeline/on_save.sh`, and point the destination's folder at a
scratch folder (EchoPad's own Markdown is not used).

EchoPad calls `on_save.sh <exported transcript> <exported audio or "">`. The script finds the
conversation folder whose `conversation.json` lists that transcript in `exportedFiles` and runs
`transcribe.sh <folder>` (same environment and log as above). Our `transcript.json` then replaces
EchoPad's Parakeet one in the library. "Transcribe Again" or re-exporting in EchoPad runs the hook
again; once the WAVs are gone that run fails and leaves an `error.txt`. If the folder is not found,
it posts a failure notification (nothing reaches `pipeline.log`).

## Diarization

`diarize.py` runs `pyannote/speaker-diarization-community-1` pinned at revision
`3533c8cf8e369892e6b79ff1bf80f7b0286a54ee` (33 MB, CC-BY-4.0) on MPS, with audio passed in memory.
One-time download into the project cache with `transcribe.sh --setup` (*Models* above; accept the
conditions on the model page first). After that no token and no network are needed:
`HF_HUB_OFFLINE=1`, and `PYANNOTE_METRICS_ENABLED=0` always. If the revision is not cached a run
stops with `needs: models` (exit 6) before diarizing.

- **Speed (M2 Max, see `../spike-diarize.md`):** a 10-min, three-voice clip takes about 25–40 s on
  MPS (real-time factor 0.04–0.065) and about 6.5 min on CPU. Loading the model takes 1–6 s.
  MPS uses about 4.5 GB of GPU memory at peak plus about 1.4 GB RSS. No ops fall back to CPU
  (`PYTORCH_ENABLE_MPS_FALLBACK` is not needed). `diarize(wav, device="cpu")` forces CPU.
- **Output:** `exclusive_speaker_diarization` (one speaker at a time), then `clean()`: a label with
  under 1 s of speech in total, or a segment under 0.25 s that touches another one, is folded into
  the neighbouring turn. community-1 produces such slivers at speaker changes. A remote speaker who
  only says one short word is therefore merged into the previous speaker.
- **Hints:** call mode passes none; in-person mode passes `min_speakers=2, max_speakers=4`.
- **Test:** `tests/test_diarize.py` runs the real model on the fake call's `system.wav` and checks
  for two speakers that match the true turns. It is skipped when the revision is not cached.

## Tests

    uv run pytest -q

About 35 s. The end-to-end tests render a fake 70 s call with `say` (two voices on `system.wav`,
one on `microphone.wav`, 2 s of overlap) and run `process.main(... --dry-run --turns ...)` against
a temporary vault, loading the ASR model once; they also check the stdout stage lines and the
`transcript.json` written back into the folder. The hand-off is tested against a stub `claude` that sets the transcript status like the skill.
`tests/test_models.py` runs `--check`, `--setup` without a token, and the exit-6 guard against an empty
fake cache (downloads are stubbed to fail), plus `transcribe.sh --check` against the real cache.

## Spike scripts

    uv run python gen_test_audio.py   # synthetic test audio (macOS say)
    uv run python asr_probe.py testdata/clip_30s.wav
    uv run python bench_asr.py
