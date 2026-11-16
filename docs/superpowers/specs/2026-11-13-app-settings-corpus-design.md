# App settings and personal corpus

Authorized scope: continue existing plans autonomously, with domain-specific settings explicitly excluded by the user. Native macOS, current feat/autocomplete worktree.

App settings use tri-state values: inherit / enabled / disabled. Inherit respects built-in defaults (code editors off, terminals/password managers always excluded). Global autocomplete enabled and global recording mode remain master gates. An app's recording override can deny collection but cannot turn collection on when global recording is off. Tab inheritance is retained. Instructions remain additive to the global instruction. Adding an app registers its identity without freezing inherited defaults. Provide search by app name/bundle ID and show effective inherited values.

Show each application's completion, recording and Tab settings as separate rows rather than a crowded horizontal control group. Include a corpus count and an action to inspect that application's stored texts.

Open the corpus in a dedicated window on explicit action. Load/decrypt on a serial background queue. List date, source application and text preview, with a read-only detail view and a source filter. Empty corpus, no selection, loading, storage unavailable and write failure have explicit states. Delete selected record, delete records from the selected application, or delete all; destructive actions require the app's confirmation sheet. The test harness uses an isolated encrypted corpus with synthetic text. No actual personal text is used in test captures.

Corpus records gain stable IDs while decoding legacy entries without IDs. Reading undecryptable/corrupt storage must never turn it into an empty writable corpus. Mutations return success/failure and only replace in-memory state after persistence succeeds. If a key cannot be read/created, no replacement key or encrypted file is persisted. A failed deletion does not report success or erase records from the list.

Recording policy is checked again on the corpus write queue. A revision token invalidates pending writes after policy changes or explicit deletion, preventing deleted records from reappearing from an already queued field session. Direct corpus access and UI deletion remain serialized by the corpus lock.

Verification: extend real encrypted corpus harness for legacy IDs, source filtering/counts, selective deletion, reload, wrong/unavailable key, corrupt data and write failure. Extend settings harness for tri-state round-trip and global recording gate. Run existing autocomplete tests, isolated native view tests in both themes, signed build and standard settings checks. Review before the full build and freeze sources during compilation. Install using the existing backup-producing installer only after checks pass.
