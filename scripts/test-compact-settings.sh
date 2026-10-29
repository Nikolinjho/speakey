#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

app="${1:-/private/tmp/Speakey_compact_settings.app}"
artifacts="${2:-/private/tmp/speakey-compact-verification}"
mkdir -p "$artifacts"

for theme in dark light; do
    light=0
    [ "$theme" != light ] || light=1
    SPEAKEY_PRO=1 SPEAKEY_NEURAL_PREVIEW_CHECK=1 SPEAKEY_COMPACT_SETTINGS_CHECK=1 \
        SPEAKEY_JOURNAL_PREVIEW_LIGHT="$light" SPEAKEY_COMPACT_SETTINGS_ARTIFACTS="$artifacts/$theme" \
        "$app/Contents/MacOS/Speakey" > "$artifacts/neural-$theme.txt" 2>&1
    tail -1 "$artifacts/neural-$theme.txt"
    SPEAKEY_PRO=1 SPEAKEY_JOURNAL_PREVIEW=1 SPEAKEY_JOURNAL_PREVIEW_CHECK=1 \
        SPEAKEY_JOURNAL_PREVIEW_LIGHT="$light" \
        "$app/Contents/MacOS/Speakey" > "$artifacts/journal-$theme.txt" 2>&1
    tail -1 "$artifacts/journal-$theme.txt"
done
