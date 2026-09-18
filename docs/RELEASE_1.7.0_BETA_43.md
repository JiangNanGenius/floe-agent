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
checked-in Xcode project has been regenerated. Metadata checks pass. The pending
component run uses code commit `2a907841b50a19b07488f5e9fff40dc4f3b9cf1f`;
subsequent version changes do not modify those implementation files.

## Evidence and next gates

- [Notes repair and diagnostic record](qualification/build185-release/notes-followup.json).
- [Preview lifecycle](NOTES_OFFICE_PREVIEWS.md).
- [GitHub Actions recovery](IDE_GITHUB_ACTIONS.md).
- Component run [35301809882](https://github.com/JiangNanGenius/floe-agent/actions/runs/35301809882)
  failed: iPad 84/84; iPhone 83/84, with a 120-second scanned bilingual OCR timeout.
  Office and new lifecycle cases passed on both devices. This remains a failed
  component run, not full-App or physical-device acceptance.
- Complete component verification, freeze an immutable source/tag, then run the
  release pipeline with both SDK App/Notes gates. Save the recoverable device
  artifact before signing and upload.
- Verify Apple processing and intended internal-group availability separately.
  GitHub prerelease, Feather publication, documentation and cleanup remain separate
  delivery steps. No production release or public-Beta submission is implied.

[Bilingual candidate notes](RELEASE_NOTES_1.7.0_BUILD_186.md) and
[TestFlight text draft](TESTFLIGHT_1.7_WHATS_NEW_BUILD_186.json) are prepared.
Physical iPad local-model and native Office/Pencil acceptance remains user-owned;
RDP is not declared a usable App feature.

The per-case allowance follows [Apple XCTest documentation](https://developer.apple.com/documentation/xctest/xctestcase/executiontimeallowance); timing remains recorded separately from functional assertions. The next cloud run must confirm the effective allowance and actual outcome.
