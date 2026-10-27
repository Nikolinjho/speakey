#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:-gate}" in
  gate)
    work="$(mktemp -d "${TMPDIR:-/tmp}/keyboop-transport.XXXXXX")"
    trap 'rm -rf "$work"' EXIT
    swiftc -parse-as-library Sources/Keyboop/NeuralTransportEventGate.swift \
      Tests/NeuralLayout/TransportGateTests.swift -o "$work/gate"
    "$work/gate"
    ;;
  --os)
    # Разрешён только отдельный временный bundle. Настройки установленного приложения не читаются.
    app=/private/tmp/Keyboop_transport.app
    bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")"
    [ "$bundle_id" = ru.keyboop.app.transport ] || { echo 'FAIL: isolated bundle ID required' >&2; exit 2; }
    codesign --verify --deep --strict "$app"
    rg -a -q -F KEYBOOP_NEURAL_TRANSPORT_CHECK "$app/Contents/MacOS/Keyboop" || { echo 'FAIL: transport entry point required' >&2; exit 2; }
    python3 - "$app/Contents/MacOS/Keyboop" <<'PY'
import os
import subprocess
import sys

environment = dict(os.environ, KEYBOOP_NEURAL_TRANSPORT_CHECK="1")
try:
    result = subprocess.run([sys.argv[1]], env=environment, timeout=12)
except subprocess.TimeoutExpired:
    print("FAIL: isolated process exceeded 12 seconds", file=sys.stderr)
    raise SystemExit(1)
if result.returncode < 0:
    print(f"FAIL: isolated process terminated by signal {-result.returncode}", file=sys.stderr)
raise SystemExit(result.returncode if result.returncode >= 0 else 128 - result.returncode)
PY
    ;;
  *) echo 'Usage: test-neural-transport.sh [gate|--os]' >&2; exit 2 ;;
esac
