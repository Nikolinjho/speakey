#!/bin/bash
# Смоук помощника автодополнения: нужен собранный llama-server и установленная модель.
set -euo pipefail
cd "$(dirname "$0")/.."
task_tmp=$(mktemp -d "/private/tmp/speakey-engine-test.XXXXXX")
trap 'rm -rf "$task_tmp"' EXIT
swiftc -swift-version 5 -module-cache-path "$task_tmp/module-cache" \
  Sources/Speakey/CompletionEngine.swift Sources/Speakey/CompletionModels.swift \
  Tests/CompletionEngine/main.swift -o "$task_tmp/engine-tests"
SPEAKEY_COMPLETE_TEST_DIR="$task_tmp/runtime" SPEAKEY_COMPLETE_BIN="${SPEAKEY_COMPLETE_BIN:-$PWD/vendor/llama.cpp/build-speakey/bin/llama-server}" \
  "$task_tmp/engine-tests"
