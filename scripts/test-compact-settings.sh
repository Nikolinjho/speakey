#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

app="${1:-/private/tmp/Keyboop_compact_settings.app}"
artifacts="${2:-/private/tmp/keyboop-compact-verification}"
mkdir -p "$artifacts"

for theme in dark light; do
    light=0
    [ "$theme" != light ] || light=1
    KEYBOOP_PRO=1 KEYBOOP_NEURAL_PREVIEW_CHECK=1 KEYBOOP_COMPACT_SETTINGS_CHECK=1 \
        KEYBOOP_JOURNAL_PREVIEW_LIGHT="$light" KEYBOOP_COMPACT_SETTINGS_ARTIFACTS="$artifacts/$theme" \
        "$app/Contents/MacOS/Keyboop" > "$artifacts/neural-$theme.txt" 2>&1
    tail -1 "$artifacts/neural-$theme.txt"
    KEYBOOP_PRO=1 KEYBOOP_JOURNAL_PREVIEW=1 KEYBOOP_JOURNAL_PREVIEW_CHECK=1 \
        KEYBOOP_JOURNAL_PREVIEW_LIGHT="$light" \
        "$app/Contents/MacOS/Keyboop" > "$artifacts/journal-$theme.txt" 2>&1
    tail -1 "$artifacts/journal-$theme.txt"
done
