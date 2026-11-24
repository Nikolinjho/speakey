#!/bin/bash
# Проверка типов всего приложения без линковки и подписи: SwiftPM в этой CLT сломан, а
# build-app.sh пересобирает бандл. Флаги те же, что у swiftc в build-app.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
task_tmp=$(mktemp -d "${TMPDIR:-/tmp}/speakey-typecheck.XXXXXX")
trap 'rm -rf "$task_tmp"' EXIT
WHISPER="vendor/whisper.cpp"
FA="vendor/fluidaudio-prebuilt"
swiftc -typecheck Sources/Speakey/*.swift \
  -swift-version 5 -target arm64-apple-macos14.0 -module-cache-path "$task_tmp/module-cache" \
  -import-objc-header Sources/Speakey/whisper-bridging.h \
  -I "$WHISPER/include" -I "$WHISPER/ggml/include" \
  -I "$FA/Modules" -I "$FA/include/FastClusterWrapper" -I "$FA/include/MachTaskSelfWrapper" \
  2>&1 | grep -E "error:" && exit 1
echo "PASS: typecheck"
