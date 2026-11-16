# Personal writing retrieval

Approved direction: the user said «делай улучшения» after the comparison and recommended first stage.

Goal: improve local autocomplete personalization using the existing encrypted writing corpus. Prioritize appropriate examples, preserve names, and retrieve habitual continuations in Russian and English. Keep recording opt-in and preserve current settings.

Approaches: keep lexical retrieval unchanged (cheap, weak context), enrich retrieval with an indexed profile (selected), or change token decoding / train LoRA (deferred until retrieval is measured). This stage changes context selection, not model weights or token probabilities.

Build one immutable index from corpus records. Cache tokenization, language, original spelling, document frequency, app frequencies and token occurrences. Query by lexical relevance, app and language, with deterministic recency tie-breaking. Locate repeated continuations after a matching tail of at least two words / ten characters. Support Unicode case matching, partial final words and sentence boundaries. Count support across distinct records. Insert a short matched example into existing author examples, within the existing prompt budget.

Rebuild in a utility queue after successful corpus mutations. Generation checks prevent old builds from overwriting newer state. Invalidate immediately on deletion. Existing synchronous corpus APIs remain compatible and can build the current index on a cold cache, outside the keyboard event callback.

Tests cover Russian/English, names, app/language prioritization, ambiguity, record boundaries, deletion, failed persistence, cold reload and held-out continuations. Compare actual local-model output against the saved previous implementation on synthetic held-out cases. Measure warm query latency without logging personal text.
