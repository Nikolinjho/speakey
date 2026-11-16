#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_tmp=$(mktemp -d "${TMPDIR:-/tmp}/speakey-recording-test.XXXXXX")
trap 'rm -rf "$task_tmp"' EXIT
swiftc -swift-version 5 Sources/Speakey/AutocompleteRecordingSession.swift \
  Tests/AutocompleteRecording/main.swift -o "$task_tmp/recording-tests"
"$task_tmp/recording-tests"
