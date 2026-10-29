#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work="$(mktemp -d "${TMPDIR:-/tmp}/speakey-benchmark.XXXXXX")"
trap 'rm -rf "$work"' EXIT
swiftc -O -swift-version 5 -framework CoreML -framework ApplicationServices \
    Sources/Speakey/NeuralLayoutTypes.swift Sources/Speakey/RightLayoutModel.swift \
    Sources/Speakey/NeuralLayoutCoordinator.swift Tools/NeuralLayoutBenchmark/main.swift -o "$work/benchmark"
swift scripts/compile-rightlayout-model.swift Sources/Speakey/Resources/RightLayout/LayoutClassifier.mlmodel "$work/LayoutClassifier.mlmodelc"
"$work/benchmark" "$work/LayoutClassifier.mlmodelc" Sources/Speakey/Resources/RightLayout/LayoutClassifier.mlmodel "${@}"
