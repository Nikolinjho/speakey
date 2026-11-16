# Retrospective: midline preview, 16 November 2026

## Friction signals

- The initial report covered both the middle and the end of existing text. Assuming that the disabled midline setting explained both would have been incorrect.
- A live replay showed the middle was rejected by the disabled setting, while the end read the correct caret and field range. After enabling the setting, the user confirmed that the end worked and identified a separate presentation problem in the middle.
- The user supplied Cotypist screenshots showing the intended rounded preview and dark typed prefix. These references resolved the presentation choice.
- AppKit tests inside the sandbox lacked screen/NSWorkspace access. The same tests outside the sandbox passed. A synthetic model probe also required the normal local-socket environment.
- Earlier responses acknowledged the desired result without implementing it. The final implementation must include installation and concrete verification evidence.

## Findings

The existing autonomy and verification rules cover these issues. No additional agent instruction is proposed. For this task, use the live replay to distinguish trigger, model response and presentation. Record sandbox limitations as test environment constraints rather than product failures.

## Outcome

A focused AppKit regression reproduced five presentation failures. The revised panel passed 14 presentation checks, with synthetic light/dark previews. Related autocomplete, controls, editing and recording checks passed. The scoped independent review reported no actionable findings.
