#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_tmp=$(mktemp -d "${TMPDIR:-/tmp}/speakey-whisper-prompt.XXXXXX")
trap 'rm -rf "$task_tmp"' EXIT
swiftc -O -swift-version 5 -module-cache-path "$task_tmp/module-cache" \
  Sources/Speakey/WhisperPrompt.swift Tests/WhisperPrompt/main.swift \
  -o "$task_tmp/prompt-tests"
"$task_tmp/prompt-tests" "$@"
