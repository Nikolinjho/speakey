#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:-}" in baseline) ;; *) echo "Неизвестный или пустой набор: ${1:-}" >&2; exit 2 ;; esac
work="$(mktemp -d "${TMPDIR:-/tmp}/keyboop-detector.XXXXXX")"
trap 'rm -rf "$work"' EXIT
sources=()
for name in Keymap DynamicKeymap LayoutData ExtraWords ExceptionStore LayoutDetector; do
    sources+=("Sources/Keyboop/$name.swift")
done
swiftc -swift-version 5 -framework Carbon "${sources[@]}" \
    Tests/LayoutDiagnostics/TestSupport.swift Tests/LayoutDetector/main.swift -o "$work/tests"
# Отдельное имя executable изолирует UserDefaults от установленного приложения.
KEYBOOP_DATA_DIR="${KEYBOOP_DATA_DIR:-$PWD/Sources/Keyboop/Resources}" "$work/tests" baseline "$PWD/Tests/LayoutDetector/baseline.json"
