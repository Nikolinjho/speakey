#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_tmp=$(mktemp -d "${TMPDIR:-/tmp}/speakey-writing.XXXXXX")
trap 'rm -rf "$task_tmp"' EXIT
swiftc -O -swift-version 5 -module-cache-path "$task_tmp/module-cache" \
  Sources/Speakey/PersonalWritingIndex.swift Sources/Speakey/PersonalCorpus.swift Sources/Speakey/ContextLexicon.swift Tests/PersonalWriting/main.swift \
  -o "$task_tmp/writing-tests"
"$task_tmp/writing-tests" "$@"
