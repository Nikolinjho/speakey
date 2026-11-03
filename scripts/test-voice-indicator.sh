#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_tmp=$(mktemp -d "${TMPDIR:-/tmp}/speakey-indicator-test.XXXXXX")
trap 'rm -rf "$task_tmp"' EXIT
swiftc -swift-version 5 -module-cache-path "$task_tmp/module-cache" \
  Sources/Speakey/VoiceIndicator.swift Sources/Speakey/NotchIsland.swift \
  Tests/VoiceIndicator/main.swift -o "$task_tmp/indicator-tests"
"$task_tmp/indicator-tests"
