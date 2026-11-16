# Autocomplete controls implementation plan

Goal: CT-06/07 and CT-14..19 as a verified native controls slice.
Architecture: pure controls policy and text acceptance rules, cached preferences in the tap, AppKit recorder using existing HotkeyRecorderPanel. Existing linked worktree feat/autocomplete is reused.
Execution: sequential in this session. User authorized autonomous execution of stages.

- [x] Task 1: Add failing harness tests for space/punctuation acceptance, shortcut matching/conflicts, timed and app-switch suppression. Files: Tests/AutocompleteControls/main.swift, scripts/test-autocomplete-controls.sh, CompletionText.swift, AutocompleteControls.swift. Verify: bash scripts/test-autocomplete-controls.sh. Expected: all checks OK.
- [x] Task 2: Persist controls and bindings, migrate legacy accept-all, add global/per-app Tab inheritance. Files: AutocompleteSettings.swift. Verify preferences harness against an isolated UserDefaults suite; legacy and overrides round-trip.
- [x] Task 3: Wire actions to controller before enabled guard, keep AX/helper work outside tap, cancel stale work on toggles, preserve secure input and hard exclusions. Files: AutocompleteController.swift, Engine.swift. Verify controls and existing autocomplete/corpus harnesses and signed compilation.
- [x] Task 4: Extend native settings with switches, Esc mode and shortcut recording/clear with conflict messages. Reuse current setting rows and recorder panel; preserve pre-existing spacing fixes. Files: AutocompleteSettingsView.swift, AutocompleteShortcutRecorder.swift, L10n.swift. Verify native settings in both themes.
- [x] Task 5: Review diff, run checks, inspect rendered settings, update replica feature evidence and build log. Only live-tested paths become yes; code/harness-only paths remain partial.

Task order is sequential. Tests are written and observed failing before implementation.
