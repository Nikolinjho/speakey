#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_tmp=$(mktemp -d "${TMPDIR:-/tmp}/speakey-engine.XXXXXX")
trap 'rm -rf "$task_tmp"' EXIT
swiftc -swift-version 5 -module-cache-path "$task_tmp/module-cache" Sources/Speakey/CompletionEngine.swift Tests/CompletionEngineOwnership/main.swift -o "$task_tmp/engine-tests"
"$task_tmp/engine-tests"
