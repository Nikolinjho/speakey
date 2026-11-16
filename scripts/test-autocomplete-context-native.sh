#!/bin/bash
set -euo pipefail
app="${1:-/private/tmp/Speakey_context_check.app}"
SPEAKEY_CONTEXT_CHECK=1 "$app/Contents/MacOS/Speakey"
