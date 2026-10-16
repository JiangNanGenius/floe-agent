<!-- docs-updated: 2026-10-16 -->
# Floe 1.7.34 (275) — local verification and delivery record

Exact-source local archive, minimum cloud signing/upload and the independent Apple readback for the 1.7.34 (275) round. Internal availability is an internal-Floe-QA state; no external group, App Review submission or public release was performed.

## Source and toolchain

- Frozen source tag `v1.7.34` at commit `084ef9087fe50752a4ae2212a097a409cca02fdf` (App/targets/project). Follow-up commit `8bd61901` (workflow + release copy) and the later docs/test-evidence commit corrected the TestFlight copy and this record; `git diff v1.7.34 <follow-up> -- FloeAgent/FloeApp FloeAgent/Sources FloeAgent/project.yml FloeAgent/FloeAgent.xcodeproj` is empty, so the archive and the tag stay exact.
- Local Xcode 27.0 (27A266a), `iphoneos27.0`, Release, arm64, six compiler jobs, `CODE_SIGNING_ALLOWED=NO`; `** ARCHIVE SUCCEEDED **` (log sha256 `82e03966…`). `release_preflight.sh v1.7.34` passed locally and again inside the cloud sign job.
- Local identities remain development-only (no distribution certificate); the cloud step signs and uploads only.

## Retained exact-source artifact (before signing)

- `Local/Artifacts/build275`: `raw-device-app.zip` sha256 `a746041ac7db7065e5666e9476b3decee962cf0283b771e2d1a47b49a839e7c4` (755,171,948 B), transport `local-device.zip` sha256 `ac5cae98b494d2a8031239da2cbd4f7f2b42d8fa0a14b6228f8d1ed97a3db2d1` (876,718,075 B), `provenance.json`.
- App/dSYM UUID `92CB8D64-859A-3AD3-B06E-AF7606DE09DF`; 10 dSYMs retained, including the rebuilt shell/text dSYMs (UUIDs `68693E63-E38F-3DB1-9B2D-2FA782E1EB3C` / `BD1169FD-7FB2-3F84-B5E0-F4492A32340D`) that match the substituted binaries — the pinned dSYMs are not paired with the rebuilt binaries.
- Normalization used the reviewed rebuilds (`shell` `4094ec43863c354bb6c0cc103bbdad94895f9ce4f20c93ff7a3b800216a615dd`, `text` `fa9170efb87039e81794539cbe28fca9764b85f3cd2814d63f527a971e53e82b`), ensured the 16 framework manifests plus the app/appex manifests, and a second normalization of the already-substituted bundle (without the private rebuild path) proved idempotence: no rebuilt substitution, no executable byte change, all 16 manifests byte-equal to the controlled sources.
- The private draft transport release `v1.7.34` retains the eight verified parts (each server digest matched; `chunk-upload-verified-275.json`); it is not published.

## Cloud signing and upload (no App rebuild)

- [Run 38848176447](https://github.com/JiangNanGenius/floe-agent/actions/runs/38848176447) success. The runner confirmed the tag source, downloaded the draft transport, verified provenance (`source_sha` = tag commit), installed the existing distribution certificate and profiles, re-signed the supplied App, re-created and validated the IPA and uploaded it: `No errors uploading archive` at 04:04:53Z. `app_rebuilt=False`; every App-rebuild / GitHub release / Feather job was skipped.
- The job log also records `Release copy from dispatch ref: 8bd61901…` for the What's New JSON and release notes: the concise product copy from `main` was used for the beta localizations, validated by the release-copy preflight before upload.
- Downloaded signed IPA: 756,377,699 B, sha256 `f817b0f6aab8036e4888acca2055a394a003b1ba8f4ad3ffbb5905c9b4f6553e`. Verified locally: `org.floeagent.ios` 1.7.34 (275), `iphoneos27.0`, `DTXcodeBuild 27A266a`, app UUID matches provenance, `codesign --verify --deep --strict` valid and satisfying its Designated Requirement, `beta-reports-active=true`, `get-task-allow=false`, `QYL72C43K6.org.floeagent.ios`; embedded shell/text UUIDs match the rebuilt binaries, neither imports statfs, and the app, appex and all 16 reviewed frameworks carry their manifests.
- Artifacts retained under `Local/Artifacts/build275/signed-run-38848176447/` (`testflight-1.7.34-build275`, `local-v1.7.34-provenance-symbols`, `APPLE-INTERNAL.json`).

## Apple state (read back independently)

- Build `a75934ba-3599-4664-93e1-ca6a5708b05c`: processing `VALID`, `expired=false`, audience `APP_STORE_ELIGIBLE`, uploaded 2026-10-15T21:06:59-07:00.
- Internal: attached to exactly the existing private Floe QA group (internal group count 1, unexpected count 0), `internalBuildState=IN_BETA_TESTING` — internal installation available. Independent GET-only confirmation: [run 38849845297](https://github.com/JiangNanGenius/floe-agent/actions/runs/38849845297); the workflow's own `APPLE-INTERNAL.json` agrees.
- TestFlight copy: the beta localizations were updated to the concise bilingual copy (language/region switching; feedback screenshots; storage checks) and read back by the upload workflow (`betaNotesVerified: en-US, zh-Hans`). The detailed command limitations and the baseline tail-cancellation limitation stay in the engineering record here, not in tester-facing copy.
- Not done (boundaries): no `publictest1` attachment, no App Review submission, no GitHub release, no Feather/website/content publication, no scheduled follow-up, no ASC API metadata writes.

## Qualification scope and limits

- Packaging/privacy tests: `python3 FloeAgent/scripts/tests/test_app_store_bundle.py` 20/20.
- iOS Simulator, App host (FloeMiniCheck, then shut down): locale + storage suites 31 tests in 4 suites pass (`FloeCore.FloeL10n` 11, `Storage extent accounting`, `FloeApp.StorageExtentAppProbe`) and the crash/feedback regression suite 57 tests pass, including the multipart `screenshots` field case; retained under `Local/Private/app-store-274-20261016/test-evidence/`.
- Rebuilt shell/text simulator-slice smoke against the same reviewed patch (component host, not App UI): normal `find` lists fixtures; `find -fstype` fails closed with `find: -fstype is not supported in this build`, returns exit 1 as an independent invocation, and the host stays alive (following commands run); `wc` byte/line/word counts are exact for ASCII, Chinese UTF-8, a 320000-byte file and pipelines; `tail -n 1` reads the last line; `tail -f` sees an appended line through the polling fallback. `tail -f` cancellation does **not** stop the worker within 25 s on either the pinned or the patched binaries (pre-existing engine limitation; the shared gate then stays held), so no full smoke pass or closed-loop tail cancellation is claimed.
- No UI interaction acceptance was performed; component-host and Simulator results do not replace physical-device acceptance (user's devices). Full paid-model business matrix and the complete cloud CI matrix were not waiting gates for this round.

## Cleanup (measured)

- Removed after exports: this round's archive cache and DerivedData (`release-275` 6,789,264 KB), App-host test DerivedData (`release-275-tests` 7,379,540 KB, after exporting both `.xcresult` bundles and logs), smoke host build (`shell-smoke-275` 302,596 KB), simulator rebuild DerivedData (`privacy-sim-275` 160,016 KB), the failed SwiftPM scratch (`377bf8f51ccd47bb` 1,470,748 KB, log retained as the environment blocker record), and the packaging stages (`build275-transfer` 2,653,884 KB, `build275-normalization-check` 1,307,240 KB). Internal volume free space rose from 142,811,956 KB to 154,721,684 KB (`df` delta +11.9 GB / +11.36 GiB; `du` totals 20.06 GB before deletion, the difference is shared/overlapping cache data).
- Retained: `Local/Artifacts/build275` (current deliverable + signed run + symbols), `Local/Artifacts/build274` (rollback), `Local/Private/app-store-274-20261016/` (manifest-final, sim-smoke, release logs, test evidence), the rebuild source cache `~/Library/Caches/FloePrivacyRebuild/ios_system-v3.0.2` (60 MB rebuild input), the private draft transport parts, and the shared pinned `task-lifecycle-app/SourcePackages` graph for identified next use. Untracked user files (`articles/`, `output/`, `docs/MEDIA_CANVAS_NEXT_DESIGN.zh-CN.md`) were not touched, committed or removed.
- FloeMiniCheck was shut down after the round; no other device was touched and no original simulator data was deleted or reset.

## Remaining for the coordinator

- External review/approval, ASC web pages (unsaved drafts/legal/contact) and the Developer Program agreement actions stay with the primary/user; this round performed no ASC web or API writes beyond the upload workflow's existing beta-localization update and Floe QA attachment.
- Physical-device acceptance (real iPad storage/performance, Office device gates) remains the user's acceptance step.
