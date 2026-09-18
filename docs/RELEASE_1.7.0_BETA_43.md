# Floe 1.7.0 / Build 186 / beta.43 candidate

Status: **fixed source frozen and tagged; release qualification in progress; not uploaded, not installable**.

Tag `v1.7.0-beta.43` was created and pushed on 2026-09-18; the annotated tag resolves to the
unique source `d421fea260523d063270e2d21d623bd011acd9ea`, which is also the pushed branch head
of the release run. Full release run
[35306551280](https://github.com/JiangNanGenius/floe-agent/actions/runs/35306551280) started at
2026-09-18 04:19:57 UTC: `prepare-release` passed at 04:20:22 UTC, then the NativeNotes
development component, the SDK 27 release build/verify job and the accepted-SDK build job run
in parallel under the frozen SHA. The upload job needs all three to succeed; the
expedited/direct/recovery TestFlight entries were skipped. At the status read
(2026-09-18 04:20–04:22 UTC) all three qualification jobs were still in progress. This record
claims no upload, Apple processing or installability.

The previous release attempt, build 185 / beta.42, failed Notes UI qualification;
both SDK App regressions passed 204/204, but this did not authorize release.
Its original binary and failure evidence remain preserved.

## Candidate changes

- Office summary reads the same extension-carrying staged resource as Quick Look.
- The unavailable native Office editor retains Notes navigation.
- Shared Office resource operations begin before queueing/staging. Timeout does
  not restart an outstanding system request; late callbacks settle at most once.
- RTF unsupported-format fixture creates its scratch directory before writing.
- Scanned OCR fixtures use the same original pixels on both devices. The single
  functional OCR/search case uses the existing 180-second ceiling and records
  elapsed time, after correct output arrived at 138 seconds beyond the earlier
  120-second effective allowance. This is not a product performance-fix claim.
- The six Office cover sample tests (`b06b3082`) now import each generated
  sample through `NoteFileImporter` → `NotesStore` CAS and render through the
  real `NotesDocumentCoverService`, still asserting a real Quick Look content
  image (`quickLookWasIconFallback == false`, `quickLookTimedOut == false`).
  They have not executed yet; the first live result is this release run's
  `notes-component` job.
- Component qualification attempts both device families and preserves failures.
- App-owned GitHub build persistence and foreground recovery remain included.

App and all versioned extension targets are configured for 1.7.0 (186), and the
checked-in Xcode project has been regenerated. Metadata checks pass. The tagged
source passes the scoped compiler checks and independent review; component and
both full-App SDK qualifications now run in parallel under the release
controller. Upload depends on all three succeeding.

## Evidence and next gates

- [Notes repair and diagnostic record](qualification/build185-release/notes-followup.json).
- [Preview lifecycle](NOTES_OFFICE_PREVIEWS.md).
- [GitHub Actions recovery](IDE_GITHUB_ACTIONS.md).
- Component run [35301809882](https://github.com/JiangNanGenius/floe-agent/actions/runs/35301809882)
  failed: iPad 84/84; iPhone 83/84, with a 120-second scanned bilingual OCR timeout.
  Office and new lifecycle cases passed on both devices. This remains a failed
  component run, not full-App or physical-device acceptance.
- Follow-up component run [35304310882](https://github.com/JiangNanGenius/floe-agent/actions/runs/35304310882)
  passed OCR on both devices (9.588 s / 82.388 s) with the enforced XCTest timer
  reset from effective 120 s to 180 s proven from the exported session logs, but
  remained failed: iPad 84/84; iPhone 83/84. The single failure was the direct
  raw-staged Word request, which timed out at 45.0958 s, while the same file
  passed through the actual App cover service on attempt 1 in 3.278 s earlier
  in the same run; the iPad direct request needed a retry. The system-host stall
  cause remains unproven; no retry or timeout was added. Independent review,
  including the session-log proof, is retained at
  `Local/Private/build186-final-review/REPORT.md`. Full-App cold-cover
  reliability remains a required gate.
- Tagged source contains the real importer/CAS/cover-service rewrite of the six
  Office sample tests; the current release run is the first live execution and
  must pass them before any upload.
- Preserve a recoverable device artifact before optional tests and signing; all
  three parallel jobs (Notes component, SDK 27 build/verify, accepted-SDK build)
  must succeed before upload. Verify Apple processing and intended internal-group
  availability separately. GitHub prerelease, Feather publication, documentation
  and cleanup remain separate delivery steps. No production release or public-Beta
  submission is implied.

[Bilingual candidate notes](RELEASE_NOTES_1.7.0_BUILD_186.md) and
[TestFlight text draft](TESTFLIGHT_1.7_WHATS_NEW_BUILD_186.json) are prepared.
Physical iPad local-model and native Office/Pencil acceptance remains user-owned;
RDP is not declared a usable App feature.

The per-case allowance follows [Apple XCTest documentation](https://developer.apple.com/documentation/xctest/xctestcase/executiontimeallowance); timing remains recorded separately from functional assertions. Run 35304310882 XCTest session logs confirm the effective timer resets from 120 to 180 seconds on both devices; OCR/search passed, while the separate direct Word request still failed.
