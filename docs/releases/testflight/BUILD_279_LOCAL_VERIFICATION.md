# Build 279 — local qualification and delivery boundary

Version 1.7.38 (279), frozen App source `a614cf493fdfd26c6ad8ef7ad10baf4a969a77c6`. Release-copy commits are recorded separately and do not change the App source or its tag.

Local Xcode 27.0 (27A266a), iphoneos27.0/arm64 archive succeeded. The first private wrapper then incorrectly expected four embedded bundles; the actual project embeds exactly `org.floeagent.ios` and `org.floeagent.ios.screenshare`, matching the prior delivered package. The original failure is retained. Packaging resumed from the same successful archive, without rebuilding, and explicitly verified both identifiers and their version/build.

- Music source/full App qualification: `1b92696e`; 42 service/preferences and three actual Apple audio backend tests passed, zero skips. See [music qualification](../repairs/FLOE_PIP_MEDITATION_AUDIO_20261019.md).
- Strict actual UIKit centered-title pinch and toolbar tests passed at `07cbf3cc`; five live-ink/placement/save/cover cases passed separately. See [Office gesture evidence](../repairs/FLOE_OFFICE_REAL_PINCH_20261019.md). These are separate checks, not a combined physical-Pencil acceptance claim.
- New device component bootstrap verified 4,785 files and 178 directories from the pinned exact ZIP; no remote App rebuild is required.
- Exact local package, raw App and matching App/native symbols saved before signing. Office embedding and runtime-free archive checks passed. Both saved ZIPs passed independent CRC and digest checks.
- Raw App SHA-256: `2ff2bbc59aa5704fb3fb427188af3217c1218eeb6ba1c048388919a1c22589e6`.
- Transport SHA-256: `b83f2fb006abaaa12ea5ed708c60a3d15e51061abecb785a6cfd8079f1ce283e`.
- App/dSYM UUID: `CD9BEE2D-C6BB-3443-A7C3-C180504E90C1`; native/dSYM UUID: `4CB339DD-34E7-3818-A36C-46157E46BF44`.

Local distribution identity is unavailable, so the configured remote route is limited to signing, upload and Apple/group verification of the saved local bytes. At this checkpoint no Build 279 upload or installability is claimed. Internal Floe QA only; no external review, public App/GitHub Release, Feather publication or formal App Store submission is authorized by this record. Build 278 remains unchanged.

Physical Pencil feel, musical preference and long background/lock behavior remain device acceptance items. Stationary ink dots and some Notes preview recovery messages remain under investigation.
