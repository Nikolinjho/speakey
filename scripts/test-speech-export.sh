#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_tmp=$(mktemp -d "${TMPDIR:-/tmp}/speakey-speech-export.XXXXXX")
trap 'rm -rf "$task_tmp"' EXIT
policy_sources=(Sources/Speakey/SpeechDiagnostics.swift)
if [[ -f Sources/Speakey/SpeechCollectionPolicy.swift ]]; then
    policy_sources+=(Sources/Speakey/SpeechCollectionPolicy.swift)
fi
swiftc -swift-version 5 -D SPEAKEY_SPEECH_TEST -module-cache-path "$task_tmp/module-cache" \
    "${policy_sources[@]}" Sources/Speakey/SpeechDiagnosticsExport.swift \
    Sources/Speakey/SpeechEvaluationCLI.swift Sources/Speakey/SpeechParakeetEvaluation.swift Tests/SpeechExport/main.swift -o "$task_tmp/speech-export-tests"
env -u SPEAKEY_SPEECH_DIAGNOSTICS "$task_tmp/speech-export-tests"
