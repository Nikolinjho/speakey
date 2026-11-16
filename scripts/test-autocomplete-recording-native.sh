#!/bin/bash
set -euo pipefail
app="${1:-/private/tmp/Speakey_recording_check.app}"
SPEAKEY_RECORDING_CHECK=1 "$app/Contents/MacOS/Speakey"
