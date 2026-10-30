#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_tmp=$(mktemp -d "${TMPDIR:-/tmp}/speakey-review-test.XXXXXX")
trap 'rm -rf "$task_tmp"' EXIT
swiftc -swift-version 5 -module-cache-path "$task_tmp/module-cache" \
  Sources/Speakey/SpeechDiagnostics.swift Sources/Speakey/SpeechDiagnosticsExport.swift \
  Sources/Speakey/SpeechReviewStore.swift Tests/SpeechReview/main.swift \
  -o "$task_tmp/review-tests"
env -u SPEAKEY_SPEECH_DIAGNOSTICS "$task_tmp/review-tests" "$task_tmp/fixture"
python3 Tools/SpeechEvaluation/evaluate.py validate "$task_tmp/fixture/export/manifest.jsonl"
python3 Tools/SpeechEvaluation/evaluate.py validate "$task_tmp/fixture/silence-export/manifest.jsonl"
