# Autocomplete controls: proposed continuation

Status: authorized by user for autonomous execution. Date: 2026-11-13 MSK.

## Scope and alternatives

Recommended: deliver CT-06/07 and CT-14 through CT-19 as one coherent controls slice.
Alternative: app/domain policy and corpus management first, with broader AX integration.
Alternative: word alternatives/synonyms first, requiring a new picker and generation flow.

## Behavior

- Independent trailing-space and trailing-punctuation switches for next-word acceptance. Accept-all inserts the entire remaining suggestion verbatim. Preserve current behavior by default: punctuation included, no added trailing space. Avoid duplicate spaces when accepting repeated words. Punctuation excluded from acceptance remains visible/available rather than silently discarded.
- Esc modes: brief pause (3 seconds), pause until app switch, or pass through. A visible suggestion is dismissed in the first two modes; a second Esc passes through. Pass-through mode never consumes Esc. App-switch pause survives clicks/Return inside that app, and clears on an actual app switch.
- Manual request uses the same secure-field, hard-exclusion, snippet/layout-priority, generation and focused-field checks as automatic requests. It may clear temporary suppression, but does not silently enable globally disabled autocomplete or hard-excluded applications.
- Temporary current-app toggle lasts 5 minutes, or ends on explicit resume; independent of permanent per-app preferences. Other applications remain enabled.
- Global toggle uses the existing controller setEnabled path, including helper lifecycle.
- Shortcut recording for next word, accept all, manual request, current-app toggle, global toggle. Store physical key code and normalized modifiers. Reject duplicate assignments with an inline explanation. Clearing a binding is supported. Preserve legacy acceptAllKeyCode during migration. No new shortcut is assigned silently to existing installations.
- Tab acceptance can be disabled globally and overridden per app, with inheritance. Option+Tab bypass remains available when the applicable next-word binding is plain Tab.
- Existing settings layout and RU/EN localization patterns apply. No model/OCR/AX calls in the event tap callback.

## Architecture

Keep text acceptance rules pure in CompletionText (or a small adjacent policy type).
Keep Codable shortcut and suppression policy separate from AX/UI and inject monotonic time into policy tests.
AutocompleteController executes policy decisions and schedules asynchronous work.
AutocompletePrefs/AutocompleteAppStore persist settings; transient suppression is not persisted.
The recorder lives in AppKit settings and does not trigger global completion actions while recording.

## Verification

- Harness tests: punctuation/space combinations, apostrophes/hyphens, Unicode, repeated acceptance, no duplicate spaces.
- Policy tests: first/second Esc, timeout, click/Return vs app switch, manual resumption, independent app pauses, binding migration/conflicts, global/per-app Tab inheritance.
- Integration: no binding steals snippets, layout correction, dictation or secure input; stale responses after suppression do not appear.
- Native settings checks in both themes using the existing signed build harness.
- Live TextEdit and Safari scenarios using actual key events; record expected vs observed results and identify unverified paths explicitly.
- Update replica/features.csv only to the level demonstrated by evidence.

## Work checklist

- [x] Load Memora and existing audited inventory.
- [x] Inspect controller, preferences, text logic, settings and tests.
- [x] Prepare replica recon and all 82 feature rows.
- [x] User authorized autonomous execution of scope and behavior.
- [x] Write implementation plan and execute tests/implementation.
- [x] Verify native behavior and update feature evidence with explicit remaining live-test gaps.
