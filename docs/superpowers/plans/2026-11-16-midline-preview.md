# Midline completion preview implementation plan

**Goal:** Match the user-provided Cotypist reference for suggestions within existing text.

**Architecture:** Extend GhostSuggestionPanel to render a rounded, opaque midline preview. AutocompleteController keeps the preview anchor and typed prefix while preserving target verification.

**Tech Stack:** Swift 5, AppKit.

**Spec:** docs/superpowers/specs/2026-11-16-midline-preview-design.md

**Global constraints:** No focus changes. Preserve end-of-field rendering, shortcuts, corpus and dictation. Continue within the existing feat/autocomplete worktree with its prior changes. No commit or publication.

**User decisions:** End-of-field inline gray text, midline pill matching the Cotypist screenshots, with a dark typed prefix.

**Review focus:** Screen edges, prefix reset, stale target, partial acceptance, returning to inline mode.

## Task 1: Midline preview and prefix

**Goal:** Render a readable midline pill and retain its anchor while the user types or accepts its prefix.

**Files:** Sources/Speakey/GhostSuggestionPanel.swift, Sources/Speakey/AutocompleteController.swift, Tests/GhostSuggestionPanel/main.swift, scripts/test-ghost-suggestion-panel.sh.

**Acceptance Criteria:** Rounded opaque midline background, dark prefix and gray remainder, bounded screen position, above-caret fallback, unchanged transparent inline rendering, nonactivating panel, verified target on acceptance.

**Verify:** bash scripts/test-ghost-suggestion-panel.sh, existing autocomplete/controls/editing/caret checks, signed full build and local installation.

- [x] Add failing presentation regressions against the real AppKit panel.
- [x] Implement pill geometry, colors, typed-prefix display and controller tracking.
- [x] Run presentation and related checks, inspect a synthetic rendered preview.
- [x] Build a signed bundle, install with install-local.sh, verify signature and installed binary.

```json:metadata
{"modelTier":"standard","files":["Sources/Speakey/GhostSuggestionPanel.swift","Sources/Speakey/AutocompleteController.swift","Tests/GhostSuggestionPanel/main.swift","scripts/test-ghost-suggestion-panel.sh"]}
```

## Task 2: Inline text alignment

**Goal:** Align the ordinary continuation with the source editor's baseline and insertion point, matching the supplied reference.

**Files:** Sources/Speakey/GhostSuggestionPanel.swift, Sources/Speakey/CaretLocator.swift, Sources/Speakey/CompletionTarget.swift, Sources/Speakey/AutocompleteController.swift, Tests/GhostSuggestionPanel/main.swift, Tests/CaretLocator/main.swift.

**Acceptance Criteria:** Use AX font metadata where available, retain fallback where unavailable, remove the NSTextField alignment inset from the insertion point, align the baseline using native font metrics, preserve midline pill geometry and successful Tab transport.

**Verify:** Real AppKit source-font/baseline/insertion-point regressions, AX typography metadata cases, full signed build, local installation, strict signature and matching hash.

- [x] Observe baseline/font/insertion-point regression failures.
- [x] Read bounded typography metadata outside the event tap and preserve it with the captured target.
- [x] Align the ordinary preview and its typed advancement using that typography.
- [x] Verify and install the signed bundle with autocomplete enabled.

```json:metadata
{"modelTier":"standard","files":["Sources/Speakey/GhostSuggestionPanel.swift","Sources/Speakey/CaretLocator.swift","Sources/Speakey/CompletionTarget.swift","Sources/Speakey/AutocompleteController.swift"]}
```

## Task 3: Trailing whitespace at end of line

**Goal:** Keep ordinary inline preview when the current line has only invisible whitespace after the caret.

**Files:** Sources/Speakey/CompletionEditing.swift, Sources/Speakey/ContextHub.swift, Sources/Speakey/CompletionVariantsController.swift, Tests/CompletionEditing/main.swift.

**Acceptance Criteria:** Empty suffix, spaces, tabs, NBSP and whitespace before LF/CRLF use inline mode. Visible text, punctuation and embedded objects on the current line still require the pill. Next paragraphs do not affect the current line. Use one classifier across automatic completions and variants.

**Verify:** bash scripts/test-completion-editing.sh, bash scripts/test-autocomplete.sh, signed full build and installation.

- [x] Reproduce the old classifier's four whitespace failures with regression tests.
- [x] Centralize and fix current-line classification.
- [x] Verify and install with autocomplete enabled.

```json:metadata
{"modelTier":"mechanical","files":["Sources/Speakey/CompletionEditing.swift","Sources/Speakey/ContextHub.swift","Sources/Speakey/CompletionVariantsController.swift","Tests/CompletionEditing/main.swift"]}
```
