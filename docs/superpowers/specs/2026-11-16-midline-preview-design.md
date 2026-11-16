# Midline completion preview

Reference: user-provided Cotypist screenshots, 16 November 2026.

At the end of a field, keep the gray inline continuation. When existing text follows the caret, show a compact rounded pill below the insertion point, with an opaque adaptive background, a subtle border and shadow. Keep the original field untouched until acceptance. The pill remains anchored at the start of the suggestion while its already typed or accepted prefix turns dark and the remaining suggestion stays gray. Clear the prefix on cancellation or a new suggestion.

Approaches: transparent text on the following line mixes with the document. Overlaying the current line obscures existing text. The user supplied the pill as the desired reference, so use that presentation.

Constrain the pill to the visible screen and place it above the caret if there is insufficient room below. Preserve the existing acceptance shortcuts and freshness checks. No model, corpus or dictation changes.
