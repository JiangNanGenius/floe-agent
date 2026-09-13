# Build 156 feedback repair — in progress

This branch implements the September 14 feedback plan. It is not a release or a completed acceptance report.

## Changes under qualification

- Remove the app-level 100-tool-call cap; preserve runtime no-progress, per-call timeout and output protections.
- Preserve nonzero tool exit codes as failed tool and background-job results.
- Reconcile text/vision capabilities with persisted auxiliary-use flags without requiring a re-save.
- Fold prior timeline groups on the next group; reserve two lines for reasoning previews.
- Show “等待模型响应” before response content, without a redundant thinking row beside reasoning.
- Notes library grid and document full-screen route; eliminate simultaneous Office preview/editor hosts and await Notes commit before dismissing.
- Move one-shot native shell blocking work off the Swift cooperative executor; pass Node CLI options to the persistent host.
- Application-owned Whisper installation and verified-file reuse after interruption.
- Source-add UI and environment-bound source key verification; preserve disabled source serialization.
- Pin certifi and configure embedded Python certificate paths at initialization.
- Remove per-frame PiP logging that displaced task diagnostics.

## Evidence

- Both user JSONL exports inspected including final turns. Shell receipts contradict the self-report claim that Node is absent: a file printed v18.20.4. Timeout receipts were marked ok by the outer executor.
- Official-service read API verified using existing local credentials, without printing credentials. Latest report is version 1.7.0 build 156; 1,024 of 1,268 lines are PiP records and the relevant task run IDs are absent.
- Existing Node host regression: 4 tests passed locally. This does not establish iOS bridge or App integration success.
- Changed Swift files passed parser checks; type checking and full App acceptance remain pending.
- Local package test attempt cancelled when SwiftPM planned an 11,129-step rebuild; heavy checks belong in cloud CI. Its incidental Package.resolved changes were reverted.

## Remaining gates

Background URLSession/resume and actual transfer progress; source edit/disable/removal and official production source; Python/npm management and package isolation; native Shell/Node integration and stdin; configuration hydration audit; stable-prefix/context replay; complete library previews and writing controls; full App iPad/iPhone tests and screenshots; documentation reconciliation; signed TestFlight upload and availability; main merge and merged-branch cleanup.

Do not equate this checkpoint, CI dispatch, source parsing or component tests with the finished plan.
