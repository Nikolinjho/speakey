# Midline completion preview

16 November 2026. Local feat/autocomplete worktree.

## Behavior

The user-provided Cotypist screenshots define the reference. At the end of the field the gray continuation stays on the caret line. In the middle the preview is a rounded opaque pill below the initial insertion point, with a border and shadow. Its typed or accepted prefix is dark and its remaining continuation is gray. The pill stays within the visible screen and moves above the caret near the bottom edge.

Matching physical input updates both expected targets. Verified partial acceptance appends to the visible prefix. A new suggestion or cancellation clears the anchor and prefix. Freshness checks still precede insertion. The user's ac.inlineCompletion setting is enabled. The temporary ac.debugSkips setting was removed after diagnosis.

## Evidence

- Before the change: real AppKit panel regression, 10 checks, 5 failures (background, rounding, separation, screen bounds, bottom-edge placement).
- After the change: bash scripts/test-ghost-suggestion-panel.sh, 14 checks, 0 failures.
- bash scripts/test-autocomplete.sh: 167 checks OK.
- bash scripts/test-autocomplete-controls.sh: 76 checks, 0 failures.
- bash scripts/test-completion-editing.sh: 30 checks, 0 failures.
- bash scripts/test-autocomplete-recording.sh: 22 checks, 0 failures.
- bash scripts/test-caret-locator.sh outside sandbox: 10 checks, 0 failures.
- git diff --check: exit 0.
- Scoped independent review: no actionable findings.

Synthetic rendered previews: /private/tmp/speakey-midline-preview/midline-light.png and midline-dark.png. Temporary files may disappear. These verify presentation, not a new physical Slack acceptance scenario.

## Delivery

SPEAKEY_BUILD_APP=/private/tmp/Speakey_midline_checked.app bash build-app.sh: exit 0. Existing compiler warnings remain.

bash install-local.sh /private/tmp/Speakey_midline_checked.app: exit 0, Installed and verified: /Applications/Speakey.app. Backup: /Applications/.Speakey-backup-20261116-141213-32b6477d.

codesign --verify --deep --strict /Applications/Speakey.app: exit 0. Prepared and installed executable SHA-256 both equal b54b4d2c11da6ec5a424bdd82ec7d4079a1d67b49a784750665397021d6010f0.

Launch at 14:12:31 MSK confirmed engine STARTED ok, AX=true, InputMon=true. Settings after installation: ac.inlineCompletion=1, ac.enabled=0, ac.recordMode=accepted. The main autocomplete switch is currently off, so physical validation of the new preview in Slack remains for when the user enables it. The backup confirms that ac.enabled was already off before installation.

No commit, merge or publication was performed.


## Follow-up: Tab and reference appearance

The user reported visible suggestions without working Tab acceptance, plus a visual mismatch. Cotypist was running concurrently and was stopped gracefully for isolation. A read-only Slack AX probe reported AXSelectedText settable=true; that flag does not establish that replacement is implemented.

Chromium upstream evidence: AXPlatformNodeCocoa.setAccessibilitySelectedText sends kReplaceSelectedText, while RenderAccessibilityImpl does not handle that web-renderer action. See https://chromium.googlesource.com/chromium/src/+/c863525085fc84c3c712fbd24ebc197ff394a712/content/renderer/accessibility/render_accessibility_impl.cc . This is a mechanism consistent with the failure, not an observed return code from the installed Slack version.

CompletionTarget now selects the verified Unicode path for Electron before any AX write, as for Safari. It detects the framework directly outside the event tap, without using Engine's unsynchronized cache. There is no fallback after an ambiguous write. Each cumulative batch is verified by re-reading the same target and both sides of the caret.

Transport regression: Safari-only policy produced 35 checks with 2 failures for Slack and another Electron application. Updated policy: 35 checks, 0 failures. Existing autocomplete: 167 checks OK. Real AppKit preview: 14 checks, 0 failures. Scoped independent review: no actionable findings.

Reference adjustments: midline font ratio 0.8, 8x3 point content insets, 0.5 point border, 3 point caret gap, rounded shadow invalidation. Light background sampled from the supplied screenshot: approximately sRGB 0.975, 0.975, 0.972. Synthetic previews use the measured Slack caret height of 18 points. Final preview: /private/tmp/speakey-midline-preview-final/midline-light.png.

The diagnostics-only build was not installed. Corrected build /private/tmp/Speakey_tab_fixed.app passed build/signing and was installed by install-local.sh, exit 0. Backup: /Applications/.Speakey-backup-20261116-143123-d447790c.

Installed and prepared executable SHA-256 match: 19fb05a311bfb02cfd179bd5db47e37110c3d39ece571d322137b4150cd30cd4. Strict installed signature check: exit 0. At 14:31:40 MSK the application logged autocomplete enabled and engine STARTED ok (AX=true, InputMon=true); at 14:31:41 MSK the completion model was ready. ac.enabled=1.

Live Slack Tab acceptance and the user's assessment of the revised appearance remain pending. Metadata-only logs now distinguish receiving the acceptance key, transport selection and verified field changes.


## Inline alignment follow-up

Live Slack logs confirmed two successive physical acceptance-key operations at 15:05:32 and 15:05:33 MSK. Both used Unicode and logged a verified insertion result. The previously pending Tab delivery check is therefore complete.

The user additionally requested the reference's alignment for ordinary gray inline text. The old panel added its own horizontal padding on top of NSTextField's 2-point alignment inset, and selected its font by caret height rather than reading the editor's typography.

CaretLocator now reads one UTF16 unit of AX attributed text after the field safety check. It preserves a native NSFont or resolves AXFont metadata. Slack's metadata may provide only the point size, in which case a system font of that exact size is used. Unavailable or invalid metadata retains the existing fallback. No field text is logged.

CompletionTarget retains that font across expected insertions. The controller uses it both for presentation and typed advancement. The inline label compensates its native alignment inset and aligns its baseline using the source font's AppKit metrics. Fractional label placement compensates NSWindow's integral-point frame rounding, on the screen's backing pixel grid. Midline pill typography stays unchanged.

A real NSTextView fixture in Times New Roman at 17.5 points reproduced all three old failures: font, baseline, and horizontal start. After the change: 17 panel checks, 0 failures; baseline reference 580.743408203125 points, preview 580.5 points on a 2x display, within half a physical pixel. AX caret/font checks: 16 passes. Editing/transport: 35 checks, 0 failures. Scoped independent review found no actionable issue.

Aligned build /private/tmp/Speakey_inline_aligned.app completed with exit 0 and passed signing. install-local.sh completed with exit 0 and reported Installed and verified: /Applications/Speakey.app. Backup: /Applications/.Speakey-backup-20261116-151950-9ffdfaf4.

Prepared and installed executable SHA-256 match: 4b6fa4d13a7178d712f44e1fd15aca0e0747bf4a57de5f4826f470010a43db48. codesign --verify --deep --strict /Applications/Speakey.app: exit 0.

At 15:20:08 MSK autocomplete was enabled and engine STARTED ok with AX=true and InputMon=true; at 15:20:09 MSK the completion model was ready. ac.enabled=1 and ac.inlineCompletion=1. The installed inline alignment is validated by the real AppKit regression; a new user visual assessment in Slack has not yet been recorded.

## End-of-line mode follow-up

The user reported a pill with the caret at the visible end of a Slack draft. The old rule treated any first non-newline character on the right as current-line text, including an otherwise invisible trailing space. A read-only probe of the original draft was inconclusive because the field was no longer available, so the exact hidden suffix in that screenshot is not claimed as observed.

CompletionEditing.hasTextOnCurrentLine now checks the current line for scalars that are neither whitespace nor default-ignorable Unicode code points. Empty text, trailing spaces/tabs/NBSP, FEFF, zero-width spaces and standalone joiners do not select the pill. Actual letters, punctuation, embedded objects and emoji containing joiners still do. The same classifier is used by ContextHub and all completion-variant branches. The target-unavailable one-character fallback remains conservative.

Evidence: old first-character rule failed four whitespace cases in 44 checks. Whitespace-only handling then failed two zero-width sentinel cases in 47 checks. A further review regression caught the visible Arabic number sign U+0600, which belongs to format but is not default-ignorable. The broad format-category filter was replaced with isDefaultIgnorableCodePoint. Final policy: 50 checks, 0 failures. Existing autocomplete: 167 checks OK. An independent read-only review found no semantic or safety regression in the current-line policy.

Quill's official cursor implementation uses U+FEFF as its hidden cursor sentinel: https://raw.githubusercontent.com/slab/quill/main/packages/quill/src/blots/cursor.ts . This informs coverage of format characters and does not establish the installed Slack version's exact suffix.

The intermediate whitespace-only and broad-format bundles were not installed. Final build /private/tmp/Speakey_line_end_checked.app completed with exit 0 and was installed by install-local.sh, exit 0. Backup: /Applications/.Speakey-backup-20261116-161431-a5e8d2b4.

Prepared and installed executable SHA-256 match: bbe74265b6e41706bd52ecf429d98cf0ddfd4f87023b743c3e80c4eff1790870. Strict installed signature verification: exit 0. ac.enabled=1. At 16:14:48 MSK autocomplete was enabled and engine STARTED ok (AX=true, InputMon=true); at 16:14:52 MSK the model was ready. A new live replay of the screenshot's exact draft has not been captured. First-show diagnostics now include the selected preview mode without field text.


## Slack range-coordinate follow-up, 16 November 2026

Read-only inspection of the user-prepared Slack composer confirmed AXNumberOfCharacters=106 and AXValue UTF16 length=106, while the selected range was 104,0. AXStringForRange(0,104) returned 104 UTF16 units without generated paragraph separators; (104,1) was unavailable. The old fallback sliced AXValue at 104 and produced a false visible letter plus space. No draft content was changed or included in this evidence.

CompletionFieldText now keeps each requested range in its source coordinate system. An overstated right-side range is shortened with bounded binary search after validating the empty start position through the same API. Only an explicitly unsupported range API permits AXValue fallback. Other failures and partial successful reads reject the snapshot. Selection freshness checks remain intact. Chromium source independently shows separate sources for accessibilityNumberOfCharacters and accessibilityStringForRange: https://raw.githubusercontent.com/chromium/chromium/main/ui/accessibility/platform/browser_accessibility_cocoa.mm .

Evidence: extracted old reader failed 7 of 10 regression checks. bash scripts/test-completion-field-text.sh: 10 checks, 0 failures. Existing completion-editing: 50 checks, 0 failures. Autocomplete: 167 checks OK. Controls: 76 checks, 0 failures. Recording: 22 checks, 0 failures. Ghost panel: 17 checks, 0 failures. Completion engine ownership: PASS, with an existing deprecation warning. Independent scoped review: no actionable findings. A read-only native probe of the new reader verified six actual Slack field boundaries. Slack returns AX noValue (-25212) past the range boundary.

SPEAKEY_BUILD_APP=/private/tmp/Speakey_slack_range_fixed.app bash build-app.sh: exit 0, existing compiler warnings. bash install-local.sh /private/tmp/Speakey_slack_range_fixed.app: exit 0, Installed and verified: /Applications/Speakey.app. Backup: /Applications/.Speakey-backup-20261116-174511-a65fb666. Installed and prepared executable SHA256: 7538194385433eec368664f543fcb8895c1d2d61669e57bb9774a025235e0bad. codesign --verify --deep --strict outside sandbox: exit 0. Sandbox-only verification could not see local certificate trust.

Launch at 17:45:27 MSK: autocomplete enabled, engine STARTED ok, AX=true, InputMon=true. Model ready at 17:45:29 MSK. No commit, merge or publication. The original composer had already been cleared by the user before installation; its exact post-install visual replay remains unverified.
