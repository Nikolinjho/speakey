# Personal writing retrieval implementation plan

> Implement this approved plan inline with TDD and verification before completion.

**Goal:** Improve writing-history retrieval without changing model weights or enabling recording.
**Architecture:** Immutable derived index, corpus generation cache, existing prompt examples.
**Tech Stack:** Swift, Foundation/NaturalLanguage, CryptoKit, llama-server.
**Spec:** ../specs/2026-11-16-personal-writing-design.md

## Global constraints

Continue in existing feat/autocomplete worktree and retain pre-existing changes. Keep personal data in the existing encrypted corpus. Derive indexes in memory. Preserve settings, model, recording policy and deletion controls. Exclude domains and terminals as already decided. No commit or publishing is requested.

## Review focus

Unicode casing and partial words; cross-app/language contamination; stale cached results after deletion; repeated tokens within one record; prompt/latency limits.

### Task 1: Indexed personal writing retrieval

```json:metadata
{"modelTier":"standard","files":["Sources/Speakey/PersonalWritingIndex.swift","Sources/Speakey/PersonalCorpus.swift","Tests/PersonalWriting/main.swift","scripts/test-personal-writing.sh"]}
```
- [x] Add behavior tests first and demonstrate expected failures against existing corpus retrieval.
- [x] Implement PersonalWritingIndex(records:) with examples(before:bundleID:limit:), terms(bundleID:limit:), continuation(after:bundleID:maxWords:minimumSupport:).
- [x] Use Unicode-folded keys and original text ranges, bounded matching tails, distinct-record support and deterministic ranking.
- [x] Cache and rebuild after persisted changes with revision checks. Reuse unchanged tokenized records when possible.
- [x] Verify `bash scripts/test-personal-writing.sh` and `bash scripts/test-autocomplete-corpus.sh`.

### Task 2: Production context integration

```json:metadata
{"modelTier":"standard","files":["Sources/Speakey/ContextHub.swift","Sources/Speakey/PersonalCorpus.swift","scripts/test-autocomplete-corpus.sh","scripts/test-autocomplete-apps-ui.sh"]}
```
- [x] Add corpus.personalization(before:bundleID:strength:) returning indexed examples, terms and qualified continuation.
- [x] Keep strength 0 empty. Existing levels cap examples at 1/3/5 and terms at 10/20/30. Prioritize compact examples of repeated phrase continuations inside the same limits.
- [x] Route ContextHub through this profile and update source lists in isolated test scripts.
- [x] Verify deletion/reload/write-failure behavior and relevant existing test suites.

### Task 3: Quality and delivery

```json:metadata
{"modelTier":"standard","files":["Tests/PersonalWritingEvaluation/main.swift","scripts/probe-personal-writing.sh"]}
```
- [x] Define held-out synthetic cases before tuning retrieval.
- [x] Run paired local-model generations using previous and new retrieval. Report target hits and latency without claiming daily-use accuracy.
- [x] Measure warm queries on a large synthetic corpus.
- [x] Build a temporary signed app, verify, install through install-local.sh with backup, confirm installed hash/signature and enabled settings.

## Verification outcome

384 checks passed. Independent read-only review findings fixed and rechecked. Synthetic paired generations: before 1/12, after 9/12; fresh subset 0/4 versus 3/4. Two unrelated controls produced no unrelated personal term in either arm. This is not a daily-use accuracy estimate. On 5000 synthetic records: full build 4615.9 ms, incremental rebuild45.4 ms, warm median15.48 ms/p95 15.76 ms. Installed via install-local.sh with backup. Strict signature passed, installed/prepared executable SHA-256 identical, captured settings unchanged. Writing recording remains off. No commits or publications. Evidence: /private/tmp/speakey-personal-writing-verification.json and /private/tmp/speakey-personal-writing-evaluation-final.json.
