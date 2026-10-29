#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work="$(mktemp -d "${TMPDIR:-/tmp}/speakey-offline.XXXXXX")"
trap 'rm -rf "$work"' EXIT
fa=vendor/fluidaudio-prebuilt
swiftc -parse-as-library -swift-version 5 -target arm64-apple-macos14.0 \
    -I "$fa/Modules" -I "$fa/include/FastClusterWrapper" -I "$fa/include/MachTaskSelfWrapper" \
    -L "$fa" -lFluidAudio -lc++ -framework CoreML -framework Accelerate -framework AVFoundation \
    Tests/LayoutDiagnostics/TestSupport.swift Tests/FluidAudioOffline/main.swift -o "$work/tests"
"$work/tests"
