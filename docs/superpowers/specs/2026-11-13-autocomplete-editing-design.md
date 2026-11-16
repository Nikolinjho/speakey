# Completion editing features

User authorized implementation first and autonomous verification afterward. Scope: CT-10/11/27/28/29/30. Domains remain excluded; terminals deferred.

Implement four features on the existing local model/helper:
- Current-word-only option: require a nonempty unfinished word; trim output at its first boundary; do not suggest a next word after whitespace.
- Mid-line insertion option: preserve right-hand text, never delete or overwrite it; constrain generation using both sides and strip repeated suffixes. Render below the line so existing text is readable. Accept-next-word and accept-all insert only the visible insertion.
- Word alternatives: request by assignable shortcut or opt-in after a configurable pause; collect up to five distinct next-word candidates with local model sampling. Keep the original candidate first. Show numbered choices, arrow navigation, Enter/Tab/number selection, Escape dismissal.
- Synonyms: request for an existing short selection (1..6 words, max120 UTF16 code units), by shortcut or opt-in after stable selection delay. Include surrounding context and use original few-shot prompts for the local base model. Show only validated short alternatives; exact replacement on explicit acceptance. No clipboard fallback.

Both new shortcuts default to unassigned. Automatic lists default off. The existing global enabled gate, per-app exclusions, secure-input checks, snippet/layout priority and no-text-in-logs rule apply. Preference UI explains each mode and timing.

All inference, snapshots, AX reads/writes and panel work occur outside event tap. In the tap, compare cached bindings, update a generation token and enqueue work. A captured target includes pid, element identity, UTF16 selection/range and both context sides. Validate the target again before showing a result and immediately before committing. Reject stale targets, large/multiline selection and unknown editable context. Failed or empty generation never edits text.

Share pure text policies (word boundary, suffix overlap, variants cleanup, keyboard decisions and context fingerprints) in a focused Foundation file. AX target handling stays separate, as does the nonactivating choice panel. Controller owns generation and request lifecycle; existing helper accepts optional sampling parameters without changing default completion behavior.

Verify parsers/policies first, then native snapshot/insertion/replacement using synthetic TextEdit-style controls, real model output on fixed Russian and English examples, native panel/settings geometry in both themes, signed build and installed live flows in TextEdit and Safari. Record model-quality limits separately from tested edit correctness. Preserve existing uncommitted work, stable signing identity and corpus data.
