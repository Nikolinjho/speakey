#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
output="docs/development/artifacts/rightlayout/14-opportunity.json"
oracle_only=0
self_test=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --output) output="$2"; shift 2 ;;
        --oracle-only) oracle_only=1; shift ;;
        --self-test) self_test=(--self-test); shift ;;
        *) echo "Неизвестный аргумент: $1" >&2; exit 2 ;;
    esac
done
work="$(mktemp -d "${TMPDIR:-/tmp}/keyboop-opportunity.XXXXXX")"
trap 'rm -rf "$work"' EXIT
sources=()
for name in NeuralLayoutTypes NeuralLayoutPolicy Keymap DynamicKeymap LayoutData ExtraWords ExceptionStore LayoutDetector; do
    sources+=("Sources/Keyboop/$name.swift")
done
printf 'func kbLog(_ message: String) {}\n' > "$work/log.swift"
swiftc -O -swift-version 5 -framework Carbon "${sources[@]}" "$work/log.swift" Tools/NeuralLayoutOpportunity/main.swift -o "$work/oracle"
KEYBOOP_DATA_DIR="$PWD/Sources/Keyboop/Resources" "$work/oracle" "${self_test[@]}" --output "$output"
if [ "$oracle_only" = 1 ]; then exit 0; fi
if ! python3 - "$output" <<'PY'
import json, sys
report = json.load(open(sys.argv[1]))
sys.exit(0 if report['earlierTimingOpportunities'] + report['additionalRecallOpportunities'] else 1)
PY
then
    echo "CoreML пропущен: оракул не обнаружил возможностей раньше baseline или дополнительного recall."
    exit 0
fi
swiftc -O -swift-version 5 -D MODEL_ENABLED -framework Carbon -framework CoreML "${sources[@]}" Sources/Keyboop/RightLayoutModel.swift "$work/log.swift" Tools/NeuralLayoutOpportunity/main.swift -o "$work/model"
swift scripts/compile-rightlayout-model.swift Sources/Keyboop/Resources/RightLayout/LayoutClassifier.mlmodel "$work/LayoutClassifier.mlmodelc"
KEYBOOP_DATA_DIR="$PWD/Sources/Keyboop/Resources" "$work/model" "${self_test[@]}" --model "$work/LayoutClassifier.mlmodelc" --output "$output"
