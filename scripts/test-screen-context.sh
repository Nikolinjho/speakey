#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_tmp=$(mktemp -d "${TMPDIR:-/tmp}/speakey-screen-context.XXXXXX")
trap 'rm -rf "$task_tmp"' EXIT
swiftc -swift-version 5 -module-cache-path "$task_tmp/module-cache" \
  Sources/Speakey/ScreenWindowPolicy.swift Tests/ScreenContext/main.swift \
  -o "$task_tmp/screen-context-tests"
"$task_tmp/screen-context-tests"
