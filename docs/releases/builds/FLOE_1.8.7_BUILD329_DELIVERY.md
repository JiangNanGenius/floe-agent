# Floe 1.8.7 (329) — delivery, 2026-11-11 Sydney

Frozen App source: `1f7fa8889a8e7bac26e4484ae2aafac5c54c51c0`; immutable tag `v1.8.7`, annotated tag object `c3eb412ee37a65122a209379386439d036f72d37`. The App was archived locally with Xcode 27.2 (`27B52`) and iPhoneOS SDK 27.2. Delivery evidence was added after freezing; the tag and saved App bytes were preserved. Later mainline changes are outside this artifact.

## Qualification and scope

The local device archive and normal packaging passed. The raw App and all 19 dSYMs were saved before distribution. Actual signed-IPA readback verified the saved App UUID, current Wi-Fi entitlement, production push capability and unexpired App Store profile.

Accepted affected App UI evidence was reused for unchanged music layouts and panels, Word create/edit/save/reopen, compact file-diff previews and provider setup. Full Swift 6 App object/link compilation, focused resource-consumer checks and actual native LaTeX article/math/PDF save/reopen/cancellation passed. The real generated PDF was visually inspected and its date verified. A fresh Linux pip installation/import/calculation also passed; native TeX has its own resource and PDF execution path.

Native LaTeX requests package/font resources from the current document's actual compiler needs and reuses its cache. The current editor has no minimal/full resource-bundle selection. XeLaTeX/BibTeX are covered; this record does not qualify every TeX engine, package, physical device or external paid provider.

This is an integration beta with focused checks. The original advanced EDA/CAE, research and physical-acceptance plans are not all complete. Native USB serial remains deferred pending the additional Apple authorization, as directed by the user. See the [frozen bilingual release notes](../notes/RELEASE_NOTES_1.8.7_BUILD_329.md) for this artifact's feature scope.

## Distribution readback

- **Internal TestFlight:** Apple reports `VALID`, unexpired, with the existing Floe QA group `IN_BETA_TESTING`. The [independent frozen GET workflow](https://github.com/JiangNanGenius/floe-agent/actions/runs/42822579064) succeeded after actual internal preparation; the internal build is available for installation.
- **GitHub and Feather:** the [normal unsigned producer and awaited reusable Feather workflow](https://github.com/JiangNanGenius/floe-agent/actions/runs/42821938101) succeeded. Independent strict readback verified stable/latest status, the immutable source/tag, canonical asset pair, digest and real arm64 iPhoneOS payload. Live Feather matched the exact version, source, SHA-256, size and download URL.
- **Public TestFlight:** the [normal submission](https://github.com/JiangNanGenius/floe-agent/actions/runs/42823187105) succeeded once for existing publictest1. The group is attached, with one `pending_review` submission and `WAITING_FOR_BETA_REVIEW`. A separate [GET inspection](https://github.com/JiangNanGenius/floe-agent/actions/runs/42823462331) confirmed the same state. This records submission awaiting Apple review; it does not claim public installability.

Canonical unsigned package: [Floe-Agent-1.8.7-build329-unsigned.ipa](https://github.com/JiangNanGenius/floe-agent/releases/download/v1.8.7/Floe-Agent-1.8.7-build329-unsigned.ipa), **908,120,405 bytes**. SHA-256:

```text
94c3ec33d1aa7aec5effed26309eb8414ee79401daa3d2966bc9bcdcabc47b0f
```

The unsigned package requires the user's signing. The verified [Feather feed](https://raw.githubusercontent.com/JiangNanGenius/floe-agent/main/feather.json) uses this exact download.

## Preserved processing delay and recovery

The original [signing/upload run](https://github.com/JiangNanGenius/floe-agent/actions/runs/42814577799) signed, validated and uploaded successfully, then exceeded its 20-minute Apple availability wait. An [independent read](https://github.com/JiangNanGenius/floe-agent/actions/runs/42819428706) found the same upload still `PROCESSING`, without errors or warnings. Its original failed wait and logs were preserved.

Apple later returned `COMPLETE` and the actual build `VALID`. The unchanged frozen internal-preparation helper populated the existing Floe QA group and bilingual beta notes, followed by the separate successful GET above. No App rebuild or second Apple upload was needed. GitHub/Feather used the independently qualified original artifact through the normal attested local-publish route; no Apple-success receipt was invented for the expired wait.

The unshipped 327 packaging failure and cancelled 328 attempt retain their original tags, artifacts and outcomes; see the [release version authority](../../RELEASE_VERSION_AUTHORITY.zh-CN.md). Build 315's formal App Store submission and automatic-release choice were unchanged.

## Recovery and cleanup

The exact raw App, all 19 dSYMs, original provenance, signed IPA and verified public unsigned package remain retained. Four consumed 328/329 archive and normalization stage directories were retired after full file/mode/symlink/ZIP recovery mapping. The exact ZIP-only AppleDouble metadata was verified and saved; the original stopping assertion was retained. The shared build cache assigned to the GPU owner, source, SDK, SwiftPM cache and independent work were preserved. Directory totals describe shared APFS data and are not claimed as reclaimed physical space.

After all source consumers finished, the consumed 329 private transport draft and its temporary ref were independently confirmed absent by 404 and release-inventory readbacks. The original processing-timeout result was checked alongside the later real Apple recovery and successful unsigned/Feather/public-submission receipts. The cancelled 328 private draft was also retired separately. The public source tags and exact recovery bytes remain retained.
