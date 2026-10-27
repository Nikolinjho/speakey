#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
suite="${1:-model}"
case "$suite" in
    model|coordinator|all) ;;
    *) echo "Неизвестный набор: $suite" >&2; exit 2 ;;
esac
work="$(mktemp -d "${TMPDIR:-/tmp}/keyboop-neural-layout.XXXXXX")"
trap 'rm -rf "$work"' EXIT
sources=(Tests/LayoutDiagnostics/TestSupport.swift Sources/Keyboop/NeuralLayoutTypes.swift)
options=(-swift-version 5)
model_args=()
if [ "$suite" = model ] || [ "$suite" = all ]; then
    sources+=(Sources/Keyboop/RightLayoutModel.swift Tests/NeuralLayout/ModelTests.swift)
    options+=(-D MODEL_TESTS -framework CoreML)
    model_args+=("$work/LayoutClassifier.mlmodelc")
fi
if [ "$suite" = coordinator ] || [ "$suite" = all ]; then
    sources+=(Sources/Keyboop/NeuralLayoutCoordinator.swift Tests/NeuralLayout/CoordinatorTests.swift)
    options+=(-D COORDINATOR_TESTS)
fi
sources+=(Tests/NeuralLayout/main.swift)
swiftc "${options[@]}" "${sources[@]}" -o "$work/tests"
if [ "${#model_args[@]}" -gt 0 ]; then
    swift scripts/compile-rightlayout-model.swift Sources/Keyboop/Resources/RightLayout/LayoutClassifier.mlmodel "${model_args[0]}"
fi
"$work/tests" "$suite" "${model_args[@]}"
