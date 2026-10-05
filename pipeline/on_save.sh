#!/bin/bash
# EchoPad post-save hook ("Run a script" after-save action), the fallback when EchoPad's built-in
# transcription is used instead of transcribe.sh as its external transcription command.
# EchoPad runs it as: on_save.sh <exported transcript file> <exported audio file or "">
# (vendor/echopad/Sources/EchoPadKit/Recording/AfterSave.swift). Neither is the conversation
# folder, so find the folder whose conversation.json lists the transcript in exportedFiles
# (written before the hook runs; JSONEncoder escapes "/" as "\/"), then run transcribe.sh on it,
# which logs to <transcripts_dir>/pipeline.log.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
library="${ECHOPAD_DATA_DIR:-$HOME/Library/Application Support/EchoPad}/Library"

escaped="${1//\//\\/}"
json="$(grep -lF -e "\"$escaped\"" -e "\"$1\"" "$library"/*/conversation.json | head -n 1 || true)"
if [ -z "$json" ]; then
    echo "on_save.sh: no conversation.json in $library lists $1" >&2
    osascript -e 'display notification "on_save.sh: conversation folder not found" with title "Notetaker failed"'
    exit 1
fi
exec "$here/transcribe.sh" "$(dirname "$json")" >/dev/null 2>&1
