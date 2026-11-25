#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_tmp=$(mktemp -d "${TMPDIR:-/tmp}/speakey-autocomplete-test.XXXXXX")
trap 'rm -rf "$task_tmp"' EXIT
swiftc -swift-version 5 -module-cache-path "$task_tmp/module-cache" \
  Sources/Speakey/CompletionText.swift Sources/Speakey/CompletionPrompt.swift \
  Sources/Speakey/LayoutData.swift Sources/Speakey/ExtraWords.swift \
  Tests/Autocomplete/main.swift -o "$task_tmp/autocomplete-tests"
SPEAKEY_DATA_DIR="$PWD/Sources/Speakey/Resources" "$task_tmp/autocomplete-tests"
