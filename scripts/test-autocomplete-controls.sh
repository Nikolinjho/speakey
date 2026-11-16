#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_tmp=$(mktemp -d "${TMPDIR:-/tmp}/speakey-controls-test.XXXXXX")
trap 'rm -rf "$task_tmp"' EXIT
swiftc -swift-version 5 -module-cache-path "$task_tmp/module-cache" \
  Sources/Speakey/CompletionText.swift Sources/Speakey/AutocompleteControls.swift \
  Sources/Speakey/AutocompleteSettings.swift Tests/AutocompleteControls/ModelStub.swift \
  Tests/AutocompleteControls/main.swift -o "$task_tmp/controls-tests"
"$task_tmp/controls-tests"
