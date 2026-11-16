# App settings and corpus implementation plan

Goal: CT-39, CT-42, CT-46, CT-47 and CT-50 for applications. Domain-specific portions are excluded.
Architecture: extend AutocompleteAppStore and PersonalCorpus, add a focused corpus viewer and app-settings view using existing AppKit primitives. Execute sequentially in the existing worktree. User authorized all implementation stages without further approval.

- [x] 1. Write failing settings tests: enabled/record overrides restore inheritance, registration preserves nil, record policy is gated by global mode, policy revisions invalidate queued collection. Implement in AutocompleteSettings.swift. Verify bash scripts/test-autocomplete-controls.sh.
- [x] 2. Write failing corpus tests for records/source counts, stable legacy IDs, selected deletion and disk failure/unavailable-key safety. Implement transactional persistence and snapshots in PersonalCorpus.swift. Verify bash scripts/test-autocomplete-corpus.sh.
- [x] 3. Build app settings view with search and explicit inheritance/effective values. Add corpus list/detail/filter and confirmed deletion. Inject stores for native synthetic-data checks. Modify AutocompleteSettingsView.swift, L10n.swift, DS tokens; add AutocompleteAppsView.swift and PersonalCorpusWindow.swift.
- [x] 4. Connect recording policy and queue revision checks in AutocompleteController.swift. Invalidate pending captured text on policy edits or corpus deletion. Run existing text/prompt and controls/corpus tests.
- [x] 5. Add native checks using isolated UserDefaults and a temporary encrypted corpus. Check inheritance controls, filtering, details, source/selected deletion, empty/error states and geometry in both themes. Review before compiling the final signed app; freeze sources during build.
- [x] 6. Run signed native checks, install with backup, compare binary/signature, update replica matrix and verification evidence. Preserve unrelated dirty changes and user data.
