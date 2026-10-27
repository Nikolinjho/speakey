#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:-}" in ''|--verify) ;; *) echo "Ожидается --verify или пустой аргумент" >&2; exit 2 ;; esac
work="$(mktemp -d "${TMPDIR:-/tmp}/keyboop-quality.XXXXXX")"
trap 'rm -rf "$work"' EXIT
sources=()
for name in NeuralLayoutTypes NeuralLayoutPolicy RightLayoutModel Keymap DynamicKeymap LayoutData ExtraWords ExceptionStore LayoutDetector; do
    sources+=("Sources/Keyboop/$name.swift")
done
# Логирование evaluator не пишет в живой журнал.
printf 'func kbLog(_ message: String) {}\n' > "$work/log.swift"
swiftc -O -swift-version 5 -framework CoreML -framework Carbon "${sources[@]}" "$work/log.swift" \
    Tools/NeuralLayoutEvaluation/Quality.swift Tools/NeuralLayoutEvaluation/main.swift -o "$work/evaluate"
swift scripts/compile-rightlayout-model.swift Sources/Keyboop/Resources/RightLayout/LayoutClassifier.mlmodel "$work/LayoutClassifier.mlmodelc"
KEYBOOP_DATA_DIR="$PWD/Sources/Keyboop/Resources" "$work/evaluate" "$work/LayoutClassifier.mlmodelc" "${1:-}"
