#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_tmp=$(mktemp -d "${TMPDIR:-/tmp}/speakey-field-text.XXXXXX")
trap 'rm -rf "$task_tmp"' EXIT
swiftc -swift-version 5 -module-cache-path "$task_tmp/module-cache" \
  Sources/Speakey/CompletionFieldText.swift Tests/CompletionFieldText/main.swift \
  -o "$task_tmp/field-tests"
"$task_tmp/field-tests"
