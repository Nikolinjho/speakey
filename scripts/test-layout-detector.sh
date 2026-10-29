#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:-}" in baseline|rules|all) ;; *) echo "Неизвестный или пустой набор: ${1:-}" >&2; exit 2 ;; esac
work="$(mktemp -d "${TMPDIR:-/tmp}/speakey-detector.XXXXXX")"
trap 'rm -rf "$work"' EXIT
sources=()
for name in NeuralLayoutTypes NeuralLayoutPolicy NeuralLayoutEvidence NeuralLayoutEvidenceBuffer Keymap DynamicKeymap LayoutData ExtraWords ExceptionStore LayoutDetector LayoutObservation LayoutJournalStore LayoutRuleService LayoutRuleBackend; do
    sources+=("Sources/Speakey/$name.swift")
done
swiftc -swift-version 5 -framework Carbon "${sources[@]}" \
    Tests/LayoutDiagnostics/TestSupport.swift Tests/LayoutDetector/RuleDetectorTests.swift Tests/LayoutDetector/main.swift -o "$work/tests"
# Отдельное имя executable изолирует UserDefaults от установленного приложения.
SPEAKEY_DATA_DIR="${SPEAKEY_DATA_DIR:-$PWD/Sources/Speakey/Resources}" "$work/tests" "${1:-}" "$PWD/Tests/LayoutDetector/baseline.json"
