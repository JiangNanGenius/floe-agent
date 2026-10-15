<!-- docs-updated: 2026-10-16 -->
# Floe 1.7.33 (274) — local verification and delivery record

Exact-source local archive, minimum cloud signing/upload and the independent Apple readback for the 1.7.33 (274) round. Internal availability and external review are separate states; this page records the observed states and their verification runs.

## Source and toolchain

- Frozen source tag `v1.7.33` (annotated `69ac89f6…`) at commit `0de810f08639315ba38ff82607e2da1fcf596f26`. A separate docs-only commit `05ef099d` corrected the prepared review-notes text and advanced `main`; the App source in it is byte-identical (`git diff 0de810f0 05ef099d -- FloeAgent` empty), so the archive and the tag stay exact.
- Local Xcode 27.0 (27A266a), `iphoneos27.0`, Release, arm64, six compiler jobs, `CODE_SIGNING_ALLOWED=NO`. `release_preflight.sh v1.7.33` passed locally (localization catalog, native-runtime-free audit, immutable application pins, Office pin, release-copy documents). `gen_project.sh` verified the generated project matches `project.yml`, including all four targets at 1.7.33 (274).
- Local identities: one Apple Development, no distribution identity, so the cloud step signs/uploads only.

## Retained exact-source artifact (before signing)

- `Local/Artifacts/build274/FloeAgent.xcarchive` + `dSYMs/` (10 dSYMs), `raw-device-app.zip` sha256 `a56e28db…`, transport `local-device.zip` sha256 `751f12b1…` (876,190,284 B), `provenance.json`, `PRESERVATION-MANIFEST.txt`.
- App binary sha256 `b8af90b9…`, app/dSYM UUID `BD614D6C-8F26-3AF4-AB8D-898F0B2B5443`, extension `org.floeagent.ios.screenshare` UUID `431DDAE6…`. FloeTinyEMU Release response file ends `-DXcode -fno-modules -O2` (retained, sha256 `e667c032…`).
- The private draft transport release `v1.7.33` retains the eight verified transport parts (each server digest matched; `chunk-upload-verified-274.json`); it is not published.

## Cloud signing and upload (no App rebuild)

- [Run 38805969523](https://github.com/JiangNanGenius/floe-agent/actions/runs/38805969523) verified provenance/tag/source, installed the existing distribution certificate and profiles, re-signed the supplied App, re-created the IPA and uploaded it: `No errors uploading archive` at 21:04:06Z. `app_rebuilt=False`.
- Retained workflow artifacts: `testflight-1.7.33-build274` (753,109,427 B), `local-v1.7.33-provenance-symbols`, `local-v1.7.33-apple-internal`.
- Downloaded signed IPA verified locally: 756,363,682 B, sha256 `2d54b5ad9a6d1b1b1f44d3b67bd8a612850e04b7c2a20c2861a19a474efa68f7`; `org.floeagent.ios` 1.7.33 (274), SDK iphoneos27.0, DTXcodeBuild 27A266a, binary UUID matches provenance, `codesign --verify --deep --strict` valid and satisfying its Designated Requirement, `beta-reports-active=true`, `get-task-allow=false`, and distribution entitlements checked.

## Apple state (read back independently)

- Build `320f0efa-d12b-404d-9fec-10a4b09a7d6a`: processing `VALID`, `expired=false`, audience `APP_STORE_ELIGIBLE`, uploaded 2026-10-15T14:06:33-07:00.
- Internal: attached to exactly the existing Floe QA group (internal group count 1, unexpected count 0), `internalBuildState=IN_BETA_TESTING` — internal installation available.
- Independent GET-only confirmation: [run 38808283515](https://github.com/JiangNanGenius/floe-agent/actions/runs/38808283515) at 2026-10-15T21:14:28Z (the workflow's own processing check and `APPLE-INTERNAL.json` agree).
- External group `publictest1` (public link `https://testflight.apple.com/join/nz6qeT2J`) was not attached at the time of the internal readback; the submission that followed is recorded in the next section.

## External review submission

- The submission was completed once through the existing App Store Connect web session (the API key cannot write app-level review metadata): Build 274 was added to the existing `publictest1` group (group build count 10 → 11) and **Submit for Review** was clicked once; the page shows 1.7.33 (274) 正在等待审核. The external group public link is `https://testflight.apple.com/join/nz6qeT2J`.
- Independent GET-only readback ([run 38810115700](https://github.com/JiangNanGenius/floe-agent/actions/runs/38810115700), 21:28Z): `ok=true`, issues empty, build `VALID` and unexpired, internal `IN_BETA_TESTING`, external `WAITING_FOR_BETA_REVIEW`, `publictest1` attached (`attachedToBuild=true`, public link enabled, not an internal group), exactly one submission in state `pending_review`. External approval is a later, separate state and is not claimed.
- One fail-closed API submission attempt ([run 38809209420](https://github.com/JiangNanGenius/floe-agent/actions/runs/38809209420), 21:21Z) stopped before any group/submission write at `PATCH /v1/betaAppReviewDetails/6801209053` with Apple `HTTP 403 FORBIDDEN_ERROR`; the post-failure GET-only inspect confirmed no partial writes. The same key restriction was recorded for Build 241 (twice) and Build 270 (once).
- Root cause of the unnecessary write attempt (release-helper bug, fixed in a separate packaging commit `ba3f5c71`, App source and tag unchanged): the prepared-file loader canonicalized the notes (LF newlines, outer whitespace stripped) while the existing-notes comparison used the raw API value, so a web save that differed only by a trailing newline still looked different. The comparison now canonicalizes both sides; a substantive text difference still counts as a mismatch and keeps the fail-closed write path. Focused tests cover a whitespace-only difference (no PATCH, `currentNotesMatchPrepared=true`) and a real text difference (still pending/writes and read back exactly).
- For future web handoffs: save the prepared review-notes text in its canonical form (LF newlines, no outer/trailing whitespace) or any equivalent form — after `ba3f5c71` the helper treats outer-whitespace/CRLF-only differences as already matching and never writes metadata for them.

## Qualification scope and limits

- Round verification (all previously accepted in the round ledger): full App build; App-host suites covers+reader 51 Swift Testing + 11 XCTest; S/S2 lifecycle Continue/active steer and the two fixed Stop/Delete fixtures 4/4; storage snapshot 19 tests/3 suites; bulk task management 19; K3 App extent probe; real configured AI through the Simulator App for Word/Excel/PPT edits and `notes.cover`; live auxiliary automatic reasoning effort with the production 2s deadline; actual AI output render gate 46.224s. Original failures stay recorded (Word test reader scope, PPT append-order assumption, engine table-count false negative, blank first AI-output captures, early provider 404s, retention of the retained test-process Office teardown defect).
- Component, Simulator and host results do not replace physical-device acceptance: real iPad storage numbers, long background behavior, performance and Office device capability gates still belong to the user's device.
- The full cloud CI matrix was not a waiting gate for this round; the supplementary CI runs remain historical evidence only.

## Cleanup (measured)

- Removed after exports: implementation scratch caches (`task-lifecycle-B` 6,137,340 KB, `923b1e48` 560,892 KB, finalized App-test DerivedData 6,487,544 KB; internal free +12,032 MiB), duplicate obsolete archives for 269/270/271/272 with their recovery paths retained (external free +7,020 MiB), and after signing the local `release-274` cache + temporary signed-IPA extraction (internal +5,655 MiB) and `Local/Scratch/build274-transfer` (external +2,592 MiB).
- Retained: `Local/Artifacts/build274` (current deliverable), `build273` (necessary rollback), `build272` xcarchive symbols + signed IPA, `build271` xcarchive crash symbols, `build269` dSYM evidence + provenance, `build270` provenance, `qualification273`, and `task-lifecycle-app/SourcePackages` (pinned graph for the identified next use). FloeMiniCheck was shut down after the primary's second lease return; other tasks' simulators were not touched.

## Repository closure

- The delivery, documentation and release-helper changes are merged and pushed to `main`. The task branch was removed after verifying it was merged and no other worktree occupied it. Unrelated worktrees and untracked user files were preserved.
- The release tag still resolves to `0de810f08639315ba38ff82607e2da1fcf596f26`; follow-up documentation and release-helper commits do not change the shipped App or require another upload. No scheduled follow-up was restored. External approval remains pending Apple.
