# Completion editing implementation plan

Execute in existing feat/autocomplete worktree. Authorized scope and verification: see matching editing design. No approval checkpoints requested by user.

- [x] 1. Add failing pure tests for current-word boundaries, right suffix preservation/overlap, short synonyms/candidate deduplication, UTF16 fingerprints and numbered keyboard navigation. Implement CompletionEditing.swift. Verify scripts/test-completion-editing.sh.
- [x] 2. Build snapshot/guarded commit abstraction for the focused AX element and native fixture tests that preserve adjacent text and reject changed selection/field. Keep it off the event tap.
- [x] 3. Add choice panel, new bindings/settings and helper sampling parameters. Keep existing defaults and add conflict checks through the existing HotkeyGuard registry.
- [x] 4. Integrate only-current-word, midline insertion, alternatives and selected-text synonyms into the controller. Cancel stale requests, preserve snippet priority, and support optional delay-driven invocation.
- [x] 5. Review implementation, run pure/native/model tests, fix findings, then freeze sources for signed compilation and native regression checks.
- [x] 6. Install with clone-backed backup; independently exercise TextEdit and Safari flows with test text, restore test settings, verify signature/binary, update feature matrix and evidence.
