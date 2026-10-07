# Build 263 — local verification

- App source: `0a847da5cf14fe5ee259056f0ac994b9dd9b9f4e`, immutable `v1.7.22`, version 1.7.22 (263).
- Toolchain: Xcode 27.0 (27A266a), iphoneos27.0 / iOS Simulator27.0. Local builds used six compiler jobs.
- Full device Release build succeeded after freezing source. Raw App and a normalized distribution bundle were saved before signing, together with matching dSYMs and provenance.
- App/dSYM UUID: `F2164FBE-A8A2-38D4-B16D-C7198528D6C5`.
- Transport SHA-256: `3f183bfd6e9d9b36ee159f42efb9d37c1091d61311ecb6fcce5f2c9fb58faeb9`.
- Packaging-policy commit `74122274` supplies the missing bilingual TestFlight metadata without changing App source or moving its tag. The same release-copy preflight passed; the signing workflow validates the immutable source and artifact separately from this text.

## Targeted checks

| Check | Result |
| --- | --- |
| Services qualification | 38 XCTest cases and 19 Swift Testing cases passed: Linux lifecycle/dispatch, port rules, pending-input recovery |
| App-hosted iPad checks | 45 cases passed: browser protocol, handoff retry/ended task, ports, terminal byte parsing/scrollback, timeline/pagination |
| Final handoff recovery | 11 browser cases passed after isolating preview persistence; closing a standalone preview preserves the task outbox |
| iPad actual interaction | URL editing/navigation, full-screen browser and return, saved handoff/Continue entry, full-screen terminal and missing-Linux prompt |
| iPhone actual interaction | Compact browser controls, URL editing/navigation and full-screen page |
| Website | Bilingual HTML and downloadable Markdown match the published source byte-for-byte; health check passed |

Original failures were retained. The first terminal check revealed SwiftTerm's exported NUL continuation cells after wide glyphs; clipboard text now excludes those cell markers while the UTF-8, ANSI, byte-cursor and visible-content assertions remain. A subsequent check verified output does not move a scrolled-back viewport.

## Performance scope

Synthetic 1,000 and 10,000 message fixtures contain long Markdown. The first page remains 20 messages; the next page reaches 50 unique messages without losing the earlier page. On the same iPad Simulator run, model load was approximately 30/21 ms. Cached projection over 100 accesses was approximately 0.43/0.42 ms, versus 1.07/1.06 ms uncached.

These are model/projection measurements, not end-to-end rendered first-screen measurements against the prior release. The requested 40% first-screen improvement is **not established**. Sampled App footprints were approximately160/221 MB after constructing the fixtures; there is no historical peak-memory nonregression result. Aggregate load diagnostics record sampled footprint and main-actor scheduling delay without conversation contents, identifiers or credentials.

## Limitations and delivery

The full cloud qualification matrix was not used for this user-authorized local release route. The simulator lacked an installed Linux image, so real local-service network reachability and live SSH interaction were not verified there. Physical-device responsiveness, background suspension, long-running VM behavior and network reachability remain separate beta acceptance items.

Build success is not upload, Apple processing or installation availability. See [current state](../../CURRENT_STATUS.md) for independent TestFlight and external-review results.

Task-owned completed test/device caches, transfer staging and superseded validation copies reclaimed17,784,254,464 allocated bytes. Current App/transport/symbols, prior-build rollback and success/failure evidence remain. Both task simulators were shut down; no booted device remained. No scheduled monitor was restarted.

## TestFlight delivery (2026-10-07)

Signing/upload run [37575259173](https://github.com/JiangNanGenius/floe-agent/actions/runs/37575259173) succeeded without rebuilding the App. Its Apple readback confirms VALID, unexpired, existing Floe QA and internal IN_BETA_TESTING, with both beta-note localizations verified. The final signed artifact was downloaded and its server SHA-256 and ZIP integrity verified. Signed IPA SHA-256: `083d06304eab1b15708c07caeb79bd6b2090be939c4b8f8f3f87474f6324bd19`.

Existing publictest1 received Build263 and review submission through App Store Connect at05:36UTC. The page shows waiting for review. Review notes were saved and read back exactly before submission; automatic tester notification remains enabled. External approval is pending. No scheduled monitor was resumed.

Independent readback [37577098938](https://github.com/JiangNanGenius/floe-agent/actions/runs/37577098938) at05:36UTC confirmed VALID, unexpired, internal IN_BETA_TESTING, publictest1 attachment and WAITING_FOR_BETA_REVIEW, with no reported issues. The completed temporary draft transport was removed after final signed-artifact retention; the immutable Git tag remains.

Final metadata readback [37577274266](https://github.com/JiangNanGenius/floe-agent/actions/runs/37577274266) at05:38UTC confirms the prepared review notes match exactly after trimming the text file trailing newline; submission remains WAITING_FOR_BETA_REVIEW.
