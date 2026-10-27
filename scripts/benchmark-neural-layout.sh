#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work="$(mktemp -d "${TMPDIR:-/tmp}/keyboop-benchmark.XXXXXX")"
trap 'rm -rf "$work"' EXIT
swiftc -O -swift-version 5 -framework CoreML -framework ApplicationServices \
    Sources/Keyboop/NeuralLayoutTypes.swift Sources/Keyboop/RightLayoutModel.swift \
    Sources/Keyboop/NeuralLayoutCoordinator.swift Tools/NeuralLayoutBenchmark/main.swift -o "$work/benchmark"
swift scripts/compile-rightlayout-model.swift Sources/Keyboop/Resources/RightLayout/LayoutClassifier.mlmodel "$work/LayoutClassifier.mlmodelc"
"$work/benchmark" "$work/LayoutClassifier.mlmodelc" Sources/Keyboop/Resources/RightLayout/LayoutClassifier.mlmodel "${@}"
