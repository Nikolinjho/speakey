#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_tmp=$(mktemp -d "${TMPDIR:-/tmp}/speakey-speech-export.XXXXXX")
trap 'rm -rf "$task_tmp"' EXIT
swiftc -swift-version 5 -module-cache-path "$task_tmp/module-cache" \
    Sources/Speakey/SpeechDiagnostics.swift Sources/Speakey/SpeechDiagnosticsExport.swift \
    Sources/Speakey/SpeechEvaluationCLI.swift Tests/SpeechExport/main.swift -o "$task_tmp/speech-export-tests"
env -u SPEAKEY_SPEECH_DIAGNOSTICS "$task_tmp/speech-export-tests"
