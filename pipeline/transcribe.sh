#!/bin/bash
# What EchoPad runs (its external transcriber). README "Contract" has the exact output and exit codes.
#
#   transcribe.sh <folder> [process.py options]   stdout: `stage: ...` lines; exit 0 ok, 1 failed (error.txt),
#                                                 6 `needs: setup` (env or Qwen3 missing; nothing touched)
#   transcribe.sh --check                         `setup: ok` | `setup: missing env|qwen3|both`; exit 0; no network
#   transcribe.sh --setup                         create the Python env and download Qwen3; exit 0 ok, 5 failed
#
# This directory is read-only at runtime (it will sit inside the signed app): everything is written under
# BASE = $ECHOPAD_DATA_DIR or ~/Library/Application Support/EchoPad, which holds config.toml (written by
# the app; NOTETAKER_CONFIG overrides it), pipeline-env/ (the venv), models/ (HF_HOME), uv-cache/,
# python/ (uv's Python installs) and pipeline.log. Uses <this dir>/bin/uv if present, else uv from PATH.
# Runs under `env -i` so a launch from EchoPad and one from a terminal behave the same. Only --setup
# goes online.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
base="${ECHOPAD_DATA_DIR:-$HOME/Library/Application Support/EchoPad}"
venv="$base/pipeline-env"
config="${NOTETAKER_CONFIG:-$base/config.toml}"
log="$base/pipeline.log"
uv="$here/bin/uv"
[ -x "$uv" ] || uv=uv

# Qwen3-ASR at the revision pinned in asr.py; present when the snapshot holds all these files
# (huggingface_hub only links a file into the snapshot once it is fully downloaded).
qwen3="$base/models/hub/models--mlx-community--Qwen3-ASR-1.7B-bf16/snapshots/e1f6c266914abc5a46e8756e02580f834a6cf8a7"
qwen3_files="config.json model.safetensors model.safetensors.index.json tokenizer_config.json vocab.json
             merges.txt preprocessor_config.json chat_template.json generation_config.json"

path="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
clean=(env -i HOME="$HOME" PATH="$path" HF_HOME="$base/models" HF_HUB_DISABLE_TELEMETRY=1
       UV_PROJECT_ENVIRONMENT="$venv" UV_CACHE_DIR="$base/uv-cache" UV_PYTHON_INSTALL_DIR="$base/python"
       UV_PYTHON_PREFERENCE=only-managed PYTHONDONTWRITEBYTECODE=1)
[ -n "${ECHOPAD_DATA_DIR:-}" ] && clean+=(ECHOPAD_DATA_DIR="$ECHOPAD_DATA_DIR")
offline=(UV_OFFLINE=1 HF_HUB_OFFLINE=1)
cd "$here"  # claude -p finds the meeting-note skill in .claude/ here

env_ok() {  # the venv exists and matches uv.lock (dev extras allowed)
    [ -x "$venv/bin/python" ] &&
        "${clean[@]}" "${offline[@]}" "$uv" sync --frozen --no-dev --inexact --check --project "$here" >/dev/null 2>&1
}
qwen3_ok() {
    local f
    for f in $qwen3_files; do [ -f "$qwen3/$f" ] || return 1; done
}
state() {  # ok | missing env|qwen3|both
    local env=ok model=ok
    env_ok || env=missing
    qwen3_ok || model=missing
    case "$env $model" in
        "ok ok") echo ok ;;
        "missing missing") echo "missing both" ;;
        "missing ok") echo "missing env" ;;
        *) echo "missing qwen3" ;;
    esac
}
logged() {  # run "$@" with stdout and stderr each appended to the log and kept separate for the caller
    echo "=== $(date '+%Y-%m-%d %H:%M:%S') transcribe.sh $*" >>"$log"  # "setup" or "run <folder> ..."
    set +e
    "$@" 2> >(tee -a "$log" >&2) | tee -a "$log"
    local status="${PIPESTATUS[0]}"
    set -e
    return "$status"
}

setup() {
    echo "stage: creating python environment"
    local out
    if ! out="$("${clean[@]}" "$uv" sync --frozen --no-dev --project "$here" 2>&1)"; then
        printf '%s\n' "$out" >&2
        echo "creating the Python environment failed: $(grep -m1 '^error' <<<"$out" || echo "uv sync failed")" >&2
        return 5
    fi
    if ! qwen3_ok; then
        "${clean[@]}" HF_HUB_OFFLINE=0 "$uv" run --frozen --no-sync --project "$here" process.py --setup || return 5
    fi
    local s
    s="$(state)"
    if [ "$s" != ok ]; then
        echo "setup finished but still $s" >&2
        return 5
    fi
    echo "stage: done"
}

run() {
    local s
    s="$(state)"
    if [ "$s" != ok ]; then  # before any work and no error.txt: the app runs --setup, then retries
        echo "needs: setup"
        echo "setup $s in $base; run transcribe.sh --setup" >&2
        return 6
    fi
    "${clean[@]}" "${offline[@]}" "$uv" run --frozen --no-sync --project "$here" process.py --config "$config" "$@"
}

mkdir -p "$base"
case "${1:-}" in
    --check) echo "setup: $(state)" ;;
    --setup) logged setup ;;
    "" | -*) echo "usage: transcribe.sh <conversation folder> [process.py options] | --check | --setup" >&2; exit 2 ;;
    *) logged run "$@" ;;
esac
