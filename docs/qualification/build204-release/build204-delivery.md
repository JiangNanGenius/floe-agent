# Build 204 lean release — internal TestFlight delivery evidence

Date: 2026-09-20 (UTC). Source: `1f654c3e59ba18856006ea0c778986bf37072feb` on
`codex/build202-device-feedback`, immutable tag `v1.7.0-beta.61` (created by the
run at the dispatched commit). Replacement attempt for the failed build 203
(`v1.7.0-beta.60`, frozen at `9e64d2a3`); build 202 (`v1.7.0-beta.59`, `0450b2ae`)
also stays frozen.

## Cloud App build and publication

[Run 35478308349](https://github.com/JiangNanGenius/floe-agent/actions/runs/35478308349)
(`release-unsigned-ipa.yml`, lean route: `lean_release=true`, `publish=true`,
`direct_testflight=false`, `github_prerelease=false`) completed all three jobs:
`lean-source` (tag bound and pushed), `lean-build` (single accepted-SDK App build,
Xcode 26.6 / 17F113, retained unsigned IPA before signing, private symbols captured,
`altool --validate-app` + `--upload-app` accepted) and `lean-publish`
(verify-download of the retained artifact, provenance attestation, normal
non-prerelease Latest GitHub release, Feather dispatch). Exactly one cloud App build
ran for this source; no unchanged-source retry exists.

Retained/verified artifacts (run `35478308349`):

- `expedited-unsigned-ipa-1.7.0-build204` — unsigned IPA
  `Floe-Agent-1.7.0-build204-unsigned.ipa`, sha256
  `b093af32d0e34d7ee31350877af2f6e0713cabce1ce83999f1d827cf1e9a7af5`,
  811,588,405 B, app UUID `20DD1CBB-D91B-3834-8356-5FBE35A28575`.
- `release-symbols-1.7.0-build204` — private symbols (artifact `10595515982`).
- `testflight-1.7.0-build204` — `UPLOAD-RECEIPT.txt` ("No errors uploading
  archive"), `TESTFLIGHT-SUMMARY.txt`.
- `lean-release-1.7.0-build204` — `LEAN-RELEASE-EVIDENCE.txt`,
  `DirectArtifact/verification.json` (`testflightAccepted: true`,
  `sourceCommit: 1f654c3e…`).

## GitHub release (normal Latest, non-prerelease)

`v1.7.0-beta.61` published by `lean-publish`: `draft=false`, `isPrerelease=false`,
repository **Latest** (`releases/latest` → `v1.7.0-beta.61`), tag object → commit
`1f654c3e59ba18856006ea0c778986bf37072feb`. Asset set is unsigned-only and
attested: `Floe-Agent-1.7.0-build204-unsigned.ipa` (+ `.sha256`),
`DIRECT-PROVENANCE.json` (`signedPayloadPublished: false`,
`signedIpaPublished: false`), `TEST-SUMMARY.txt`, `PUBLIC-ASSETS.json`,
`bundle-normalization.json`, `pdfium-linkage.json`. Local re-verification:
`gh attestation verify … --source-digest 1f654c3e… --signer-workflow
JiangNanGenius/floe-agent/.github/workflows/release-unsigned-ipa.yml` exit 0;
re-downloaded asset digest matches `b093af32…`; release download URL live (HTTP 302).

## Feather

[Run 35480212487](https://github.com/JiangNanGenius/floe-agent/actions/runs/35480212487)
(`publish-feather-source.yml`) verified the published unsigned IPA checksum and
provenance, generated and committed `feather.json` to `main`. Feather
`sourceURL` `https://raw.githubusercontent.com/JiangNanGenius/floe-agent/main/feather.json`;
top version `1.7.0 (204)`, `downloadURL`
`https://github.com/JiangNanGenius/floe-agent/releases/download/v1.7.0-beta.61/Floe-Agent-1.7.0-build204-unsigned.ipa`,
`size` 811,588,405, `sha256` `b093af32d0e34d7ee31350877af2f6e0713cabce1ce83999f1d827cf1e9a7af5`,
`sourceCommit` `1f654c3e59ba18856006ea0c778986bf37072feb` — exact unsigned artifact.

## TestFlight (Apple processing + internal group)

ASC build ID `5bbc54a5-a0af-4a16-933f-0be0aa790d74`, version `1.7.0 (204)`,
uploaded 2026-09-19 18:08:57 -07:00, `processingState=VALID`, `expired=false`,
`buildAudienceType=APP_STORE_ELIGIBLE`.

- [discover 35480637333](https://github.com/JiangNanGenius/floe-agent/actions/runs/35480637333),
  [discover 35481083116](https://github.com/JiangNanGenius/floe-agent/actions/runs/35481083116),
  [discover 35481554699](https://github.com/JiangNanGenius/floe-agent/actions/runs/35481554699) — upload `5bbc54a5-…` state `PROCESSING` → `COMPLETE`.
- [prepare 35481609531](https://github.com/JiangNanGenius/floe-agent/actions/runs/35481609531) —
  `prepare_testflight.py` returned `{"buildID": "5bbc54a5-…", "version": "1.7.0",
  "build": "204", "processing": "VALID", "group": "Floe QA", "betaNotesVerified":
  ["en-US", "zh-Hans"]}` from `docs/TESTFLIGHT_1.7_WHATS_NEW_BUILD_204.json`.
- [verify 35481660694](https://github.com/JiangNanGenius/floe-agent/actions/runs/35481660694)
  at 2026-09-20 01:32:54 UTC — `beta-group-count=1`, `floe-qa-internal-group-count=1`,
  `unexpected-beta-group-count=0`, group `Floe QA` (`c09d3f5c-f5b3-485f-9ddb-98c61fa80ad1`,
  internal, no public link, feedback enabled), `internal-beta-state=IN_BETA_TESTING`.

## Boundary

Simulator/UI qualification was skipped by explicit user request (lean route); this is
internal device testing, not full acceptance. Device acceptance remains with the
user; the CodeBlitz error-95 toast still needs on-device verification. No public
Beta review and no App Store production submission were performed.
