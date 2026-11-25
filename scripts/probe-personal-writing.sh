#!/bin/bash
# Парный замер прежнего и нового подбора истории на синтетических отложенных фразах.
set -euo pipefail
cd "$(dirname "$0")/.."
baseline_source="${1:?Укажи сохранённый прежний PersonalCorpus.swift}"
output="${2:-/private/tmp/speakey-personal-writing-evaluation.json}"
task_tmp=$(mktemp -d /private/tmp/speakey-writing-eval.XXXXXX)
trap 'rm -rf "$task_tmp"' EXIT
python3 - "$baseline_source" "$task_tmp/BaselinePersonalCorpus.swift" <<'PY'
from pathlib import Path
import sys
Path(sys.argv[2]).write_text(Path(sys.argv[1]).read_text().replace('PersonalCorpus', 'BaselinePersonalCorpus'))
PY
swiftc -O -swift-version 5 -module-cache-path "$task_tmp/module-cache" \
  Sources/Speakey/CompletionEngine.swift Sources/Speakey/CompletionModels.swift \
  Sources/Speakey/CompletionText.swift Sources/Speakey/CompletionPrompt.swift \
  Sources/Speakey/LayoutData.swift Sources/Speakey/ExtraWords.swift \
  Sources/Speakey/PersonalWritingIndex.swift Sources/Speakey/PersonalCorpus.swift \
  "$task_tmp/BaselinePersonalCorpus.swift" Tests/PersonalWritingEvaluation/main.swift \
  -o "$task_tmp/evaluate"
SPEAKEY_WRITING_EVAL_DIR="$task_tmp/corpus" SPEAKEY_COMPLETE_TEST_DIR="$task_tmp/runtime" \
  SPEAKEY_DATA_DIR="$PWD/Sources/Speakey/Resources" \
  SPEAKEY_COMPLETE_BIN="${SPEAKEY_COMPLETE_BIN:-$PWD/vendor/llama.cpp/build-speakey/bin/llama-server}" \
  "$task_tmp/evaluate" "$output"
