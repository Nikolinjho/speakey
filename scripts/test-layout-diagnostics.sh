#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work="$(mktemp -d "${TMPDIR:-/tmp}/keyboop-diagnostics.XXXXXX")"
trap 'rm -rf "$work"' EXIT
sources=(Tests/LayoutDiagnostics/TestSupport.swift)
for name in LayoutObservation LayoutDecision LayoutDecisionExplainer LayoutFeedbackTracker LayoutDiagnosticsController KeystrokeBuffer LayoutJournalStore LayoutRuleService; do
    source="Sources/Keyboop/$name.swift"
    [ ! -f "$source" ] || sources+=("$source")
done
# Файл FooTests.swift объявляет FooTests: DiagnosticSuite, имя набора задаёт сам тип.
: > "$work/main.swift"
for source in Tests/LayoutDiagnostics/*Tests.swift; do
    [ -f "$source" ] || continue
    sources+=("$source")
    name="$(basename "$source" .swift)"
    printf 'DiagnosticTestRegistry.add(%s.self)\n' "$name" >> "$work/main.swift"
done
cat Tests/LayoutDiagnostics/main.swift >> "$work/main.swift"
swiftc -swift-version 5 "${sources[@]}" "$work/main.swift" -o "$work/tests"
"$work/tests" "${1:-}"
