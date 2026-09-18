# Build 191 cleanup: retirement of superseded 179-190 archive copies

Date: 2026-09-18 (UTC). Task: second-pass lifecycle cleanup `job-f05afad7ffdf452e`,
predecessor first pass `job-0f56a3e5474c4813`. User explicitly authorized retiring
obsolete 179-190 failed-version recovery archive copies after the build 191 delivery;
historical release-note retention statements are not perpetual requirements.

This record exists so history stays accurate: the executable archive copies listed below
were intentionally retired, while their qualification records, failure evidence and
provenance remain.

## Basis for the decision

* Build 191 is the current internal delivery and is verified complete: signed IPA
  `74b4f3ea…`, Apple `VALID`, internal beta `IN_BETA_TESTING`, Floe QA installable
  ([delivery record](../build191-release/testflight-delivery.json), [README](../build191-release/README.md)).
* Builds 179-190 never uploaded a signed build (179's accepted-SDK step timed out;
  181-190 stopped at qualification gates). Their recovery archives are unsigned and not
  installable, and each build is superseded by 191.
* One usable rollback remains: the build 178 unsigned IPA plus checksum and test summary
  under `Local/Artifacts/Release-1.7.0-build178/`.
* No current feedback worker, local build, workflow or script reads the retired paths;
  `lsof` showed no open handles at retirement time. All origin source commits and beta tags
  are present in the repository, and every retired file's sha256 was recomputed and matched
  its download-time sidecar before deletion.

## Retired artifacts (exact list)

| Build | Artifact | Bytes | SHA-256 | Origin (run / artifact) | Remaining copy |
| --- | --- | --- | --- | --- | --- |
| 179 | `Local/Artifacts/build179-release/Floe-Agent-1.7.0-build179-unsigned.ipa` | 809,398,720 | `d0b8b8b8…2fa8e` | run 35228451173 / 10503238901 (v1.7.0-beta.36) | CI artifact, expires 2026-12-16 |
| 184 | `Local/Artifacts/build184-device-recovery/accepted-sdk-device-recovery.zip` | 811,440,631 | `7e3f2ba1…43a8a` | run 35287358993 / 10525204023 | CI artifact, expires 2026-12-16 |
| 185 | `Local/Artifacts/build185-device-recovery/accepted-sdk-device-recovery.zip` | 811,449,698 | `9009a3ea…68ee2` | run 35292395886 / 10527600618 | CI artifact, expires 2026-12-17 |
| 186 | `Local/Artifacts/build186-release/accepted-sdk-device-recovery-1.7.0-build186/accepted-sdk-device-recovery.zip` | 811,474,118 | `903e4be6…ae93f` | run 35306551280 / 10532236731 | CI artifact, expires 2026-12-17 |
| 187 | `Local/Artifacts/build187-release/accepted-sdk-device-recovery-1.7.0-build187/accepted-sdk-device-recovery.zip` | 811,479,694 | `25409199…395899` | run 35312393708 / 10534840255 | CI artifact, expires 2026-12-17 |
| 188 | `Local/Artifacts/build188-release/accepted-sdk-device-recovery-1.7.0-build188/accepted-sdk-device-recovery.zip` | 811,487,825 | `85678a17…13c6e6` | run 35317532109 / 10536687918 | CI artifact, expires 2026-12-17 |
| 189 | `Local/Artifacts/build189-release/accepted-sdk-device-recovery-1.7.0-build189/accepted-sdk-device-recovery.zip` | 811,490,419 | `00855524…19e9a4` | run 35322816608 / 10538753104 | CI artifact, expires 2026-12-17 |
| 190 | `Local/Artifacts/build190-release/accepted-sdk-device-recovery-1.7.0-build190/accepted-sdk-device-recovery.zip` | 811,490,471 | `87acd3e5…e6de3` | run 35329733708 / 10541981245 | CI artifact, expires 2026-12-17 |

Totals: 8 files, 6,489,711,576 bytes (`du` 6,337,624 KB). Regeneration for any of them is
`git checkout <origin source SHA>` plus the corresponding accepted-SDK / release CI run; the
remote copies above permit a direct re-download until their expiry.

## Measured space

* `df` available on the volume: 9,980,108 KB before (2026-09-18T16:30:51Z) → 16,313,904 KB
  after (16:31:29Z); delta 6,333,796 KB.
* `du` of the exact retired files: 6,337,624 KB. The small difference is concurrent writer
  activity during the 38-second window; `du` is the direct figure for the retired set.
* `Local/Artifacts` total after retirement: 5,167,380 KB.

## Preserved (not retired)

* Current 191 deliverables: unsigned developer IPA, signed TestFlight IPA, accepted-SDK
  device recovery zip, and their provenance.
* One usable 178 rollback IPA with checksum and test summary.
* Failure evidence for 179-190: Notes-UI xcresults, screenshots, recordings and per-attempt
  logs; native Notes xcresults; build 186 iPhone timeout spindump; app-regression
  diagnostics; dependency-transport records; qualification JSON under
  `docs/qualification/build179-release` … `build190-release`.
* Small provenance/manifests and checksum sidecars next to every retired archive
  (`*.sha256`, `verified-provenance.json`, `provenance.json`, `device-recovery.json`).
* `Local/Artifacts/build179-test-host/` — the reference compiled test host for the current
  IDE host-recovery feature described in [IDE test host recovery](../../IDE_TEST_HOST_RECOVERY.md).
  It is a live verification input, not a failed-version recovery copy, so it was kept; note
  its GitHub artifact (10497993199) expires 2026-09-24, after which the local copy is the
  durable reference.
* RDP libraries/toolchains, LuaWASI, Handoff, public-beta assets and all other
  `Local/Artifacts` content.

## Supersession note

Historical statements that 179-190 recovery packages are "retained"
(`docs/TESTFLIGHT_1.7.0_BETA.md:24-25`, `docs/RELEASE_1.7.0_BETA_43.md:44`) describe the
state before this lifecycle review. This record intentionally retires the executable archive
copies only; the failure/qualification records those notes reference remain in place and are
unchanged.

## Integrity

No main code, tracked historical document, workflow, version or branch was modified; no
build, CI or deployment ran. All changes are inside the Git-ignored `Local/` tree plus this
new qualification record (`git HEAD` unchanged at `c0369f96`). Private measurements and
per-file hashes: `Local/Private/build191-feedback/cleanup-retirement/`.

中文摘要：191 内部交付已核验完成后，二次清理仅退役 179-190 的 8 个失败版本归档副本
（1 个 unsigned IPA + 7 个 unsigned device-recovery ZIP，合计 6,489,711,576 字节，实测
可用空间增加约 6,333,796 KB），保留 191 全部交付物、178 回滚、所有失败证据与来源/校验
清单，以及当前 IDE 宿主恢复功能的参考宿主。历史记录未改动，本次退役记录即为其准确补充。
