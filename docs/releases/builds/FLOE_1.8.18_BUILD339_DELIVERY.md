# Floe 1.8.18 (339) delivery

2026-11-13 (Sydney). Frozen source `b1c062d75ffe07603a698e048109776a2d4707ba`, immutable annotated tag `v1.8.18`, tag object `f5d15c5a845c23a118d53a48ac1855ce33b98694`.

| Channel | Verified result |
| --- | --- |
| Internal TestFlight | Apple `VALID`, unexpired; existing **Floe QA** group `IN_BETA_TESTING`. Independent Apple GET passed at 03:33 UTC. |
| GitHub | Normal **stable/latest** publication passed strict source, attestation and actual unsigned-IPA download readback. |
| Feather | The actual awaited publication job passed; independent live-feed readback matched the exact source, version, digest, size and download URL at 03:41 UTC. |
| Public TestFlight / App Store | Neither submitted. Existing Build315 formal and withdrawn Build331 public arrangements remain unchanged. |

[Release and installer](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.8.18) · [Signing and upload](https://github.com/JiangNanGenius/floe-agent/actions/runs/43355750827) · [Independent Apple GET](https://github.com/JiangNanGenius/floe-agent/actions/runs/43359648620) · [Normal publication](https://github.com/JiangNanGenius/floe-agent/actions/runs/43359937203) · [Awaited Feather job](https://github.com/JiangNanGenius/floe-agent/actions/runs/43359937203/job/131672364842).

## Changes and actual qualification

This narrow repair corrects native file-shortcut parsing, physical `/var` and `/private/var` root-alias matching, domain-scoped reference stability, and reuse of fully completed optimization receipts under fresh native authority. It preserves active/unknown ownership, metadata, hash, generation and recovery safeguards. See the [frozen bilingual release notes](../notes/RELEASE_NOTES_1.8.18_BUILD_339.md).

Actual App/test object compilation and linking passed in 196.889 seconds. **14 distinct selected native test methods passed, 0 failed and 0 skipped:** five file-receipt/parser methods and nine recovery/reference methods. No synthetic file-descriptor override was used. Unchanged 338 evidence, including its five failure-notification lifecycle tests, was reused explicitly rather than rerun or counted as new tests. The original optional-root-ID compile failure is preserved.

The first device archive reached its 900-second driver limit while compilation remained active. Its original failure and resource evidence remain preserved. The same source, tag and warm caches completed a subsequent 1,000.417-second archive under an explicit 1,800-second bound. Xcode 27.2 (27B52), iPhoneOS 27.2 and the actual fresh device C compile were verified. The original App and all **19 dSYM bundles** were retained before packaging. Signing/upload and publication reused that exact artifact; no rebuild was performed for distribution.

## Physical M4 iPad observation

The supplied M4 iPad updated through TestFlight; an independent single-App lookup confirmed **1.8.18 / 339**. The existing reproduction conversation now shows only its two real TXT/HTML file shortcuts, without the erroneous internal diff-metadata paths. Both open in the native reader with complete **2/2 and 8/8 lines**, Chinese/emoji and UTF-8. Real inline `+2/-0` and `+8/-0` differences remain visible. This check did not run Linux or inference again.

Actual installation also changed the App data-container path. Read-only enumeration found the prior optimization intent and completed journals under their old path-derived authority key, with a new empty directory under the new key. Thus the `/var` alias fix does **not** complete recovery across a changed container UUID. No fresh optimization job was started to bypass that history. This separate defect continues as the next narrow repair; remaining capacity recovery is **not accepted complete**.

The earlier 338 physical-volume increase of **124,848,209,920 bytes** remains the measured reclaimed amount. No additional reclaim is attributed to 339. Existing data, installed software and all 13 recovery disks were retained. Live microphone/cloud speaker quality was not retested while device screen control could interfere. GPU and other new engine integration remain outside this stable candidate.

The App's first-launch developer notice and independent Apple GET both matched the frozen bilingual 339 testing notes. TestFlight's initially stale 337 detail text did not require a server metadata write.

## Artifact identity

| Artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| Transport ZIP | 1188244143 | `d88fa6eebd77aff63d48f979faeacc035cb22cd74acd3c01a870ab414b4cdf34` |
| Signed TestFlight IPA | 918104667 | `03d48ecaf3eeec5fe9dc45f64c26058d0e7eee92a99032ef535919cd77041b33` |
| Public unsigned IPA | 917936385 | `aa4b2081d80a3d5caa21c26ec6248b17434cfd7afa4a6483ab1613612e2c6d0e` |

Later delivery or device evidence is appended independently; the frozen source, tag and saved packages remain unchanged.
