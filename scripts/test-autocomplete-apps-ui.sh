#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_tmp=$(mktemp -d "${TMPDIR:-/tmp}/speakey-apps-ui.XXXXXX")
trap 'rm -rf "$task_tmp"' EXIT
swiftc -swift-version 5 -module-cache-path "$task_tmp/module-cache" \
  Sources/Speakey/SettingsDesign.swift Sources/Speakey/L10n.swift \
  Sources/Speakey/AutocompleteControls.swift Sources/Speakey/AutocompleteSettings.swift \
  Sources/Speakey/CompletionText.swift Sources/Speakey/PersonalWritingIndex.swift Sources/Speakey/PersonalCorpus.swift \
  Sources/Speakey/AutocompleteAppsView.swift Sources/Speakey/PersonalCorpusWindow.swift \
  Tests/AutocompleteAppsUI/Dependencies.swift Tests/AutocompleteAppsUI/main.swift \
  -o "$task_tmp/apps-ui-tests"
for theme in dark light; do
  "$task_tmp/apps-ui-tests" "$theme" "${1:-/private/tmp/speakey-apps-ui-artifacts}"
done
