#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_tmp=$(mktemp -d /private/tmp/speakey-ghost-tests.XXXXXX)
trap 'rm -rf "$task_tmp"' EXIT
swiftc -swift-version 5 -module-cache-path "$task_tmp/module-cache" \
  Sources/Speakey/SettingsDesign.swift Sources/Speakey/GhostSuggestionPanel.swift \
  Tests/GhostSuggestionPanel/main.swift -o "$task_tmp/ghost-tests"
"$task_tmp/ghost-tests"
