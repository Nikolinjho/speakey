#!/bin/bash
# Замер источников контекста на синтетических фразах, без личных текстов и настроек.
set -euo pipefail
cd "$(dirname "$0")/.."
task_tmp=$(mktemp -d "/private/tmp/speakey-personalization.XXXXXX")
trap 'rm -rf "$task_tmp"' EXIT
swiftc -swift-version 5 -module-cache-path "$task_tmp/module-cache" \
  Sources/Speakey/CompletionEngine.swift Sources/Speakey/CompletionModels.swift \
  Sources/Speakey/CompletionText.swift Sources/Speakey/CompletionPrompt.swift \
  Sources/Speakey/LayoutData.swift Sources/Speakey/ExtraWords.swift \
  Tests/AutocompletePersonalization/main.swift -o "$task_tmp/probe"
SPEAKEY_COMPLETE_TEST_DIR="$task_tmp/runtime" \
  SPEAKEY_DATA_DIR="$PWD/Sources/Speakey/Resources" \
  SPEAKEY_COMPLETE_BIN="${SPEAKEY_COMPLETE_BIN:-$PWD/vendor/llama.cpp/build-speakey/bin/llama-server}" \
  "$task_tmp/probe" "$@"
