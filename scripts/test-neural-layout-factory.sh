#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work="$(mktemp -d "${TMPDIR:-/tmp}/keyboop-factory-check.XXXXXX")"
trap 'rm -rf "$work"' EXIT
app="$work/FactoryCheck.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/RightLayout"
sources=()
for name in NeuralLayoutTypes NeuralLayoutCoordinator NeuralLayoutRuntime NeuralLayoutPresentation NeuralLayoutEvidence RightLayoutModel RightLayoutRuntimeFactory LayoutJournalStore LayoutObservation; do
    sources+=("Sources/Keyboop/$name.swift")
done
swiftc -O -swift-version 5 -framework CoreML "${sources[@]}" Tools/NeuralLayoutFactoryCheck/main.swift -o "$app/Contents/MacOS/FactoryCheck"
python3 - "$app" <<'PY'
import plistlib,sys
from pathlib import Path
app=Path(sys.argv[1])
(app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'test.keyboop.factory.isolated','CFBundleExecutable':'FactoryCheck','CFBundlePackageType':'APPL'}))
PY
resources="$app/Contents/Resources/RightLayout"
cp Sources/Keyboop/Resources/RightLayout/model.json Sources/Keyboop/Resources/RightLayout/profile.json "$resources/"
swift scripts/compile-rightlayout-model.swift Sources/Keyboop/Resources/RightLayout/LayoutClassifier.mlmodel "$resources/LayoutClassifier.mlmodelc"
"$app/Contents/MacOS/FactoryCheck" disabled-profile
python3 - "$resources/model.json" <<'PY'
import json,sys
from pathlib import Path
path=Path(sys.argv[1]); value=json.loads(path.read_text()); value['inputLength']=19; path.write_text(json.dumps(value))
PY
"$app/Contents/MacOS/FactoryCheck" invalid-manifest
printf '{broken' > "$resources/model.json"
"$app/Contents/MacOS/FactoryCheck" invalid-json
rm "$resources/model.json"
"$app/Contents/MacOS/FactoryCheck" missing-resource
echo '4 проверки factory, 0 ошибок'
