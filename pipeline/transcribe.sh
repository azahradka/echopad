#!/bin/bash
# Runs the pipeline on one EchoPad conversation folder. EchoPad's external transcription command
# (Settings > Transcription > External command) runs it as: transcribe.sh <conversation folder>;
# on_save.sh calls it after finding the folder. Extra arguments go to process.py.
#
#   transcribe.sh <folder> [process.py options]   stdout: `stage: ...` lines; logged to <transcripts_dir>/pipeline.log
#   transcribe.sh --check                         `models: ok` | `models: missing qwen3|pyannote|both`
#   transcribe.sh --setup                         download missing models; HF_TOKEN is read from the environment only
#
# Runs under `env -i` so a launch from EchoPad and one from a terminal behave the same. Only HOME, PATH,
# ECHOPAD_DATA_DIR and (for --setup) HF_TOKEN pass through. The exit code is process.py's.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
path="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
clean=(env -i HOME="$HOME" PATH="$path" HF_HOME="$here/.hf-cache" PYANNOTE_METRICS_ENABLED=0 HF_HUB_DISABLE_TELEMETRY=1)
[ -n "${ECHOPAD_DATA_DIR:-}" ] && clean+=(ECHOPAD_DATA_DIR="$ECHOPAD_DATA_DIR")
cd "$here"

case "${1:-}" in
    --check)
        exec "${clean[@]}" HF_HUB_OFFLINE=1 uv run process.py --check ;;
    --setup)  # online; the token is never logged or written anywhere
        [ -n "${HF_TOKEN:-}" ] && clean+=(HF_TOKEN="$HF_TOKEN")
        exec "${clean[@]}" uv run process.py --setup ;;
    "")
        echo "usage: transcribe.sh <conversation folder> | --check | --setup" >&2
        exit 2 ;;
esac

clean+=(HF_HUB_OFFLINE=1)
transcripts="$("${clean[@]}" uv run python -c 'import process; print(process.load_config()["transcripts_dir"])')"
[ -d "$transcripts" ] || mkdir "$transcripts"
log="$transcripts/pipeline.log"

echo "=== $(date '+%Y-%m-%d %H:%M:%S') transcribe.sh $*" >>"$log"
# stdout and stderr each go to the log and stay separate for the caller.
set +e
"${clean[@]}" uv run process.py "$@" 2> >(tee -a "$log" >&2) | tee -a "$log"
status="${PIPESTATUS[0]}"
set -e
exit "$status"
