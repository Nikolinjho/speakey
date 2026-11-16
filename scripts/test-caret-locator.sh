#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_tmp=$(mktemp -d "${TMPDIR:-/tmp}/speakey-caret.XXXXXX")
trap 'rm -rf "$task_tmp"' EXIT
swiftc -swift-version 5 -module-cache-path "$task_tmp/module-cache" \
  Sources/Speakey/AXFocusedElement.swift Sources/Speakey/CaretLocator.swift Tests/CaretLocator/main.swift \
  -o "$task_tmp/caret-tests"
"$task_tmp/caret-tests"
