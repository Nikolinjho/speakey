#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_tmp=$(mktemp -d "${TMPDIR:-/tmp}/speakey-monitor-test.XXXXXX")
trap 'rm -rf "$task_tmp"' EXIT
swiftc -swift-version 5 -module-cache-path "$task_tmp/module-cache" \
  Sources/Speakey/MicrophoneMonitor.swift Tests/MicrophoneMonitor/main.swift \
  -o "$task_tmp/monitor-tests"
"$task_tmp/monitor-tests"
