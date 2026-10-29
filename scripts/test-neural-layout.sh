#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
suite="${1:-model}"
case "$suite" in
    model|coordinator|policy|integration|quality|assistance|settings|all) ;;
    *) echo "Неизвестный набор: $suite" >&2; exit 2 ;;
esac
work="$(mktemp -d "${TMPDIR:-/tmp}/speakey-neural-layout.XXXXXX")"
trap 'rm -rf "$work"' EXIT
sources=(Tests/LayoutDiagnostics/TestSupport.swift Sources/Speakey/NeuralLayoutTypes.swift)
options=(-swift-version 5)
model_args=()
if [ "$suite" = model ] || [ "$suite" = all ]; then
    sources+=(Sources/Speakey/RightLayoutModel.swift Tests/NeuralLayout/ModelTests.swift)
    options+=(-D MODEL_TESTS -framework CoreML)
    model_args+=("$work/LayoutClassifier.mlmodelc")
fi
if [ "$suite" = coordinator ] || [ "$suite" = all ]; then
    sources+=(Sources/Speakey/NeuralLayoutCoordinator.swift Tests/NeuralLayout/CoordinatorTests.swift)
    options+=(-D COORDINATOR_TESTS)
fi
if [ "$suite" = policy ] || [ "$suite" = all ]; then
    sources+=(Sources/Speakey/NeuralLayoutPolicy.swift Tests/NeuralLayout/PolicyTests.swift)
    options+=(-D POLICY_TESTS)
fi
if [ "$suite" = integration ] || [ "$suite" = all ]; then
    for name in NeuralLayoutCoordinator NeuralLayoutRuntime NeuralLayoutPresentation NeuralLayoutPolicy NeuralFocusMonitor NeuralOccurrenceFence KeystrokeBuffer KeyboardLayoutCache NeuralLayoutModeSettings NeuralLayoutEvidence NeuralLayoutEvidenceBuffer LayoutJournalPresenter LayoutDiagnosticsController LayoutFeedbackTracker LayoutJournalStore LayoutObservation Keymap DynamicKeymap LayoutData ExtraWords ExceptionStore LayoutDetector; do
        file="Sources/Speakey/$name.swift"
        if [[ " ${sources[*]} " != *" $file "* ]]; then sources+=("$file"); fi
    done
    sources+=(Tests/NeuralLayout/ObservationIntegrationTests.swift)
    options+=(-D INTEGRATION_TESTS -framework Carbon)
fi
if [ "$suite" = quality ] || [ "$suite" = all ]; then
    sources+=(Tools/NeuralLayoutEvaluation/Quality.swift Tests/NeuralLayout/QualityTests.swift)
    options+=(-D QUALITY_TESTS)
fi
if [ "$suite" = assistance ] || [ "$suite" = all ]; then
    if [ "$suite" = assistance ]; then sources+=(Sources/Speakey/NeuralLayoutPolicy.swift); fi
    sources+=(Sources/Speakey/NeuralLayoutMarkerCodec.swift Sources/Speakey/InputLatency.swift Sources/Speakey/NeuralLayoutAssistance.swift Tests/NeuralLayout/MarkerTests.swift Tests/NeuralLayout/AssistanceTests.swift)
    options+=(-D ASSISTANCE_TESTS -framework CoreGraphics)
fi
if [ "$suite" = settings ] || [ "$suite" = all ]; then
    for name in NeuralLayoutCoordinator NeuralLayoutRuntime NeuralLayoutPresentation NeuralLayoutPolicy NeuralLayoutEvidence NeuralLayoutModeSettings LayoutObservation LayoutJournalStore; do
        file="Sources/Speakey/$name.swift"
        if [[ " ${sources[*]} " != *" $file "* ]]; then sources+=("$file"); fi
    done
    sources+=(Tests/NeuralLayout/SettingsTests.swift)
    options+=(-D SETTINGS_TESTS)
fi
sources+=(Tests/NeuralLayout/main.swift)
swiftc "${options[@]}" "${sources[@]}" -o "$work/tests"
if [ "${#model_args[@]}" -gt 0 ]; then
    swift scripts/compile-rightlayout-model.swift Sources/Speakey/Resources/RightLayout/LayoutClassifier.mlmodel "${model_args[0]}"
fi
SPEAKEY_DATA_DIR="$PWD/Sources/Speakey/Resources" "$work/tests" "$suite" "${model_args[@]}"

if [ "$suite" = model ] || [ "$suite" = all ]; then
    bash scripts/test-neural-layout-factory.sh
fi
