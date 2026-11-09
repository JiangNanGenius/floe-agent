# Floe 1.8.6 (326) — delivery, 2026-11-09

Frozen App source: `9bbe87ca91acc4c7ca7c57555be584df07c6866a`; immutable tag `v1.8.6` (annotated tag object `e40db7007e4deba312f55b7814290a1a369c0cbc`). Built locally with Xcode 27.2 (`27B52`), iPhoneOS SDK 27.2 (`24B8118`). Delivery evidence was added after freezing; the tag and saved App bytes were preserved. Later mainline changes are outside this App artifact.

## Qualification and scope

The full arm64 Simulator App object/link build and image seal passed. Two affected hosted App Linux ownership/default-transition tests passed with no skips. Limited execution-settings and restore-warning/cancel UI checks passed on the reused iPad Simulator. Accepted unchanged PCB, modal/thermal, LaTeX/PDF and App/guest scientific evidence was reused at its recorded boundaries. The local device archive succeeded and its raw App and symbols were saved before distribution.

This is an expedited integration beta: **general stability was waived**, with focused changed-boundary and UI checks retained. The original 20 feature families and PCB01–23 / C01–67 / N01–38 plans are **not all complete**. Advanced EDA/CAE, physical-device/provider checks and several historical Office capability claims remain open. This delivery does not establish a new physical-device acceptance or complete original-plan closure.

## Distribution readback

- **Internal TestFlight:** Apple reports `VALID`, unexpired, with the existing Floe QA group `IN_BETA_TESTING`. [Signing/upload](https://github.com/JiangNanGenius/floe-agent/actions/runs/42571315744) and an [independent GET](https://github.com/JiangNanGenius/floe-agent/actions/runs/42574368256) succeeded; the internal build is available for installation.
- **GitHub and Feather:** the [normal attested local producer and awaited reusable Feather workflow](https://github.com/JiangNanGenius/floe-agent/actions/runs/42574910887) succeeded. Independent strict readback verified the stable/latest release, immutable source/tag, canonical asset pair, digest and arm64 iPhoneOS payload. Live Feather matched the exact version, source, SHA-256, size and download URL.
- **Public TestFlight:** the [normal submission](https://github.com/JiangNanGenius/floe-agent/actions/runs/42579411230) succeeded once. The existing publictest1 group is attached, with one `pending_review` submission and `WAITING_FOR_BETA_REVIEW`. The review notes match the prepared text. A later [independent inspection](https://github.com/JiangNanGenius/floe-agent/actions/runs/42582453235) retained the same pending state. This snapshot records submission awaiting Apple review; it does **not** claim public installability.

Canonical unsigned package: [Floe-Agent-1.8.6-build326-unsigned.ipa](https://github.com/JiangNanGenius/floe-agent/releases/download/v1.8.6/Floe-Agent-1.8.6-build326-unsigned.ipa), **879,340,265 bytes**. SHA-256:

```text
7e934de5f97f3523a81aba521725cda157df2b6b881aaef8d591962d04bd3e2a
```

## Preserved failures and recovery

Initial packaging stopped at an unregistered embedded framework. The original device build was reused with a [separately committed, exact-framework privacy packaging policy](https://github.com/JiangNanGenius/floe-agent/commit/a2497fa41e2edef6fe747f01dc7d1437496bd18c). The controlled local overlay retained the frozen normalization algorithms and executable-byte checks. It did not change the App source/tag; cloud provenance continued to bind the complete transport and frozen App source rather than independently reviewing the local policy.

The [first public submission attempt](https://github.com/JiangNanGenius/floe-agent/actions/runs/42574703205) stopped at a review-notes PATCH with HTTP 403, before group attachment or review submission. Corrected administrative API authorization was functionally verified by the successful normal end-to-end submission above. The original failure is retained. A separate local publication-checker false failure included skipped Feather jobs from other routes; a narrowly scoped adapter selected the actual awaited job and retained all strict checks. No republication was required.

The consumed private transport draft and its private ref were removed with independent 404 and release-inventory readbacks. Raw App/symbols and exact distribution/recovery bytes remain retained; redundant local archive/cache outputs were retired only after verified recovery mapping. Build 315's formal App Store submission and automatic-release choice were unchanged.
