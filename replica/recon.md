# Cotypist functionality in Speakey

Snapshot: 2026-11-13, Europe/Moscow. Personal native macOS application.

## Evidence

The authoritative detailed inventory is ../docs/development/cotypist-functional-inventory.md
(CT-01 through CT-82). It records observations of Cotypist 2026.5.2 build 84,
public documentation, and the distinction between implemented and live-tested Speakey behavior.

Sources:
- https://cotypist.app/help/shortcuts
- https://cotypist.app/help/troubleshooting
- https://cotypist.app/help/personalization
- https://cotypist.app/help/privacy
- https://cotypist.app/help/tips
- https://cotypist.app/compatibility
- https://cotypist.app/pricing
- https://cotypist.app/help/sync

## Native surfaces

| ID | Surface | Access | Relevant states |
| --- | --- | --- | --- |
| S01 | Inline suggestion | Type in supported focused field | idle, loading, visible, stale, dismissed, blocked |
| S02 | Autocomplete settings | Speakey settings | enabled, disabled, model missing/downloading/ready/error |
| S03 | App-specific settings | Autocomplete settings | inherited, overridden, excluded |
| S04 | Personal corpus | Autocomplete settings | disabled, empty, encrypted records, unavailable key |
| S05 | Menu controls | Speakey menu bar | global enabled/disabled, current app paused |

## Flows

- F01: type -> pause -> see continuation -> accept next word or all -> continue typing.
- F02: dismiss -> keep typing -> resume under the selected Esc policy.
- F03: manually request -> safely snapshot current field -> show fresh completion.
- F04: pause current app -> switch apps -> retain independent temporary app state -> resume.
- F05: configure shortcut -> validate conflict -> save -> perform action in another app.
- F06: configure app -> see effective policy -> type under that policy.
- F07: opt into personalization -> accept suggestions -> inspect/delete encrypted records.

## Components and entities

Existing native AppKit components and settings conventions remain authoritative:
../docs/development/settings-ui.md. Extend the app rather than create a second shell.
Entities: completion, focused-field snapshot, global preferences, app override,
shortcut binding, temporary suppression, corpus record, local model.
Current architecture: AutocompleteController, CompletionText, AutocompletePrefs,
AutocompleteAppStore, ContextHub, PersonalCorpus, separate llama.cpp helper.

## Scope

Implement behavior with original Swift code and original RU/EN labels.
No original binaries, source, network traffic, assets, or personal text are copied.
Terminal support remains deferred. Cloud sync, billing and Cotypist telemetry are excluded.
Only explicitly live-tested features receive clone=yes. Code alone remains partial.
Priority values in features.csv are planning recommendations, not user approval.

## Scope update: 2026-11-13 MSK

User explicitly excluded per-domain settings. All browser policies in this project operate per application only. CT-44 is skip; app portions of CT-42/46/50 remain in scope.
