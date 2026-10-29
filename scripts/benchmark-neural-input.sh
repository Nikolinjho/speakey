#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work="$(mktemp -d "${TMPDIR:-/tmp}/speakey-input-benchmark.XXXXXX")"
trap 'rm -rf "$work"' EXIT
sources=()
for name in NeuralLayoutTypes NeuralLayoutCoordinator NeuralLayoutRuntime NeuralLayoutPresentation NeuralLayoutEvidence RightLayoutModel LayoutJournalStore LayoutObservation; do
    sources+=("Sources/Speakey/$name.swift")
done
swiftc -O -swift-version 5 -framework CoreML -framework CoreGraphics "${sources[@]}" Tools/NeuralLayoutInputBenchmark/main.swift -o "$work/benchmark"
swift scripts/compile-rightlayout-model.swift Sources/Speakey/Resources/RightLayout/LayoutClassifier.mlmodel "$work/LayoutClassifier.mlmodelc"
"$work/benchmark" "$work/LayoutClassifier.mlmodelc"
