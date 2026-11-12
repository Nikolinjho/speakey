#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_tmp=$(mktemp -d "${TMPDIR:-/tmp}/speakey-corpus-test.XXXXXX")
trap 'rm -rf "$task_tmp"' EXIT
swiftc -swift-version 5 -module-cache-path "$task_tmp/module-cache" \
  Sources/Speakey/PersonalCorpus.swift \
  Tests/AutocompleteCorpus/main.swift -o "$task_tmp/corpus-tests"
"$task_tmp/corpus-tests"
