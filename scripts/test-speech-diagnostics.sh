#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_tmp=$(mktemp -d "${TMPDIR:-/tmp}/speakey-speech-test.XXXXXX")
trap 'rm -rf "$task_tmp"' EXIT
swiftc -swift-version 5 -module-cache-path "$task_tmp/module-cache" \
    Sources/Speakey/SpeechDiagnostics.swift Tests/SpeechDiagnostics/main.swift \
    -o "$task_tmp/speech-diagnostics-tests"
env -u SPEAKEY_SPEECH_DIAGNOSTICS "$task_tmp/speech-diagnostics-tests"
python3 - <<'PY'
from pathlib import Path
controller = Path('Sources/Speakey/VoiceController.swift').read_text()
whisper = Path('Sources/Speakey/WhisperBridge.swift').read_text()
assert 'SpeechDiagnostics.begin(samples: samples' in controller, 'batch trace must be opt-in and retain the exact engine input'
assert 'diagnostics: diagnostics' in controller, 'trace must follow each transcription through its fallback'
for stage in ['ghost_cleanup', 'dictionary', 'output_options']:
    assert f'record("{stage}"' in controller, f'missing stage: {stage}'
assert 'record("whisper_raw"' in whisper, 'raw ASR must precede echo cleanup'
assert whisper.index('record("whisper_raw"') < whisper.index('WhisperPrompt.stripEcho(out'), 'raw stage is after echo cleanup'
assert 'stopStamp' not in Path('Sources/Speakey/SpeechDiagnostics.swift').read_text(), 'diagnostic timing must be per dictation'
print('PASS: batch trace wiring and raw-before-cleanup source checks (not an ASR runtime test)')
PY
