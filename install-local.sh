#!/bin/bash
# Локальная DEV-сборка с резервной копией приложения и данных.
# install-local.sh [prepared.app] [installer options...]
set -euo pipefail
cd "$(dirname "$0")"

if [ "$#" -gt 0 ] && [[ "$1" != --* ]]; then
  prepared_app="$1"
  shift
else
  bash build-app.sh
  prepared_app="$PWD/Speakey.app"
fi

exec python3 scripts/install-speakey.py "$prepared_app" "$@"
