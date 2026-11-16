#!/bin/bash
set -euo pipefail
app="${1:-/private/tmp/Speakey_editing_check.app}"
SPEAKEY_EDITING_CHECK=1 "$app/Contents/MacOS/Speakey"
