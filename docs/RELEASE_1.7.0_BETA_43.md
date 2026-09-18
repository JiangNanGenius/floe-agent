# Floe 1.7.0 / Build 186 / beta.43 preparation

Status: **draft; no tag, signed package or upload yet**.

The last release attempt, build 185 / beta.42, failed Notes UI qualification;
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
- Component qualification attempts both device families and preserves failures.
- App-owned GitHub build persistence and foreground recovery remain included.

App and all versioned extension targets are configured for 1.7.0 (186), and the
checked-in Xcode project has been regenerated. Metadata checks pass. Source will be frozen after scoped compiler checks and
independent review; component and both full-App SDK qualifications then run in
parallel under the release controller. Upload depends on all three succeeding.

## Evidence and next gates

- [Notes repair and diagnostic record](qualification/build185-release/notes-followup.json).
- [Preview lifecycle](NOTES_OFFICE_PREVIEWS.md).
- [GitHub Actions recovery](IDE_GITHUB_ACTIONS.md).
- Component run [35301809882](https://github.com/JiangNanGenius/floe-agent/actions/runs/35301809882)
  failed: iPad 84/84; iPhone 83/84, with a 120-second scanned bilingual OCR timeout.
  Office and new lifecycle cases passed on both devices. This remains a failed
  component run, not full-App or physical-device acceptance.
- Follow-up component run [35304310882](https://github.com/JiangNanGenius/floe-agent/actions/runs/35304310882)
  passed OCR on both devices (9.588 s / 82.388 s), but remained failed: iPad
  84/84; iPhone 83/84. A direct raw-staged Word request timed out while the same
  file passed through the actual App cover service. Six sample checks now use
  the importer/CAS/shared cover service and still require actual Quick Look
  images. The system-host stall cause remains unproven; no retry or timeout was
  added. Full-App cold-cover reliability remains a required gate.
- Freeze an immutable source/tag and run component plus both SDK App/Notes gates
  in parallel. Preserve a recoverable device artifact before optional tests and
  signing; all three jobs must succeed before upload.
- Verify Apple processing and intended internal-group availability separately.
  GitHub prerelease, Feather publication, documentation and cleanup remain separate
  delivery steps. No production release or public-Beta submission is implied.

[Bilingual candidate notes](RELEASE_NOTES_1.7.0_BUILD_186.md) and
[TestFlight text draft](TESTFLIGHT_1.7_WHATS_NEW_BUILD_186.json) are prepared.
Physical iPad local-model and native Office/Pencil acceptance remains user-owned;
RDP is not declared a usable App feature.

The per-case allowance follows [Apple XCTest documentation](https://developer.apple.com/documentation/xctest/xctestcase/executiontimeallowance); timing remains recorded separately from functional assertions. Run 35304310882 XCTest session logs confirm the effective timer resets from 120 to 180 seconds on both devices; OCR/search passed, while the separate direct Word request still failed.
