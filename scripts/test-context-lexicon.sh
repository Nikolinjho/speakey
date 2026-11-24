#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_tmp=$(mktemp -d "${TMPDIR:-/tmp}/speakey-lexicon.XXXXXX")
trap 'rm -rf "$task_tmp"' EXIT
swiftc -O -swift-version 5 -module-cache-path "$task_tmp/module-cache" \
  Sources/Speakey/ContextLexicon.swift Tests/ContextLexicon/main.swift \
  -o "$task_tmp/lexicon-tests"
"$task_tmp/lexicon-tests" "$@"
