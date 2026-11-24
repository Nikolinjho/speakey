#!/bin/bash
# Проверка типов всего приложения без линковки и подписи: SwiftPM в этой CLT сломан, а
# build-app.sh пересобирает бандл. Флаги те же, что у swiftc в build-app.sh.
set -uo pipefail
cd "$(dirname "$0")/.."
task_tmp=$(mktemp -d "${TMPDIR:-/tmp}/speakey-typecheck.XXXXXX")
trap 'rm -rf "$task_tmp"' EXIT
WHISPER="vendor/whisper.cpp"
FA="vendor/fluidaudio-prebuilt"
if ! swiftc -typecheck Sources/Speakey/*.swift \
  -swift-version 5 -target arm64-apple-macos14.0 -module-cache-path "$task_tmp/module-cache" \
  -import-objc-header Sources/Speakey/whisper-bridging.h \
  -I "$WHISPER/include" -I "$WHISPER/ggml/include" \
  -I "$FA/Modules" -I "$FA/include/FastClusterWrapper" -I "$FA/include/MachTaskSelfWrapper" \
  > "$task_tmp/log" 2>&1; then
  grep -E "error:" "$task_tmp/log" | head -20
  echo "FAIL: typecheck"
  exit 1
fi
echo "PASS: typecheck"
