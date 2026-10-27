#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
suite="${1:-model}"
case "$suite" in
    model|all) ;;
    *) echo "Неизвестный набор: $suite" >&2; exit 2 ;;
esac
work="$(mktemp -d "${TMPDIR:-/tmp}/keyboop-neural-layout.XXXXXX")"
trap 'rm -rf "$work"' EXIT
sources=(Tests/LayoutDiagnostics/TestSupport.swift)
for name in NeuralLayoutTypes RightLayoutModel; do
    source="Sources/Keyboop/$name.swift"
    [ ! -f "$source" ] || sources+=("$source")
done
sources+=(Tests/NeuralLayout/ModelTests.swift Tests/NeuralLayout/main.swift)
swiftc -swift-version 5 -framework CoreML "${sources[@]}" -o "$work/tests"
swift scripts/compile-rightlayout-model.swift Sources/Keyboop/Resources/RightLayout/LayoutClassifier.mlmodel "$work/LayoutClassifier.mlmodelc"
"$work/tests" "$suite" "$work/LayoutClassifier.mlmodelc"
