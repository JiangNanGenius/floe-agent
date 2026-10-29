# Floe 1.7.64 (305) delivery

Recorded 2026-10-30 (Australia/Sydney). This delivery covers the provider and
CAD/material/presentation changes in the [release notes](../notes/RELEASE_NOTES_1.7.64_BUILD_305.md).
Build 304 and its immutable tag/artifacts remain unchanged.

| Item | Verified result |
| --- | --- |
| Immutable App source | `c5a4262c448824ee6127fa5a6cd186163871ae50`, annotated tag `v1.7.64` |
| Local build | Xcode 27.1 (27A9275), iPhoneOS 27.1 Release archive; Swift 6 App and test object compilation passed |
| Current-source checks | 201 unit tests, three provider UI tests covering six channel/purpose combinations, and one compact-layout test passed without skips |
| CAD checks | Three unchanged CAD UI tests passed at `d60683d4`; current-source native PNG/GLB outputs and visual evidence were inspected |
| Internal TestFlight | Apple `VALID`, unexpired, existing Floe QA group, `IN_BETA_TESTING` |
| External TestFlight | Existing `publictest1` attached; exactly one submission, `pending_review` |
| GitHub | Stable, latest, independently downloaded unsigned IPA and matching checksum/provenance |
| Feather | Awaited downstream job succeeded; live URL, version, build, source and digest match |

The final product change after the retained CAD UI witness affects only the
provider picker. Its actual earlier source remains recorded; it was not
relabeled as a current-source test. Original failed checks and the focused
verification decision are retained privately. The reused canonical iPad
Simulator was shut down; no user physical device was tested. Simulator evidence
does not establish physical-device rendering performance.

Live Volcengine Agent Plan chat and a downloaded, decoded 1024×1024 generated
image succeeded. Alibaba Token Plan chat/image calls returned quota errors;
there was no pay-as-you-go fallback or repeated paid submission. Successful
live Alibaba image/video generation is not claimed by this record.

The [original signing/upload run](https://github.com/JiangNanGenius/floe-agent/actions/runs/40943635345)
uploaded successfully, then exceeded its bounded wait for Apple processing.
The existing upload was recovered without rebuilding or uploading again.
[Preparation](https://github.com/JiangNanGenius/floe-agent/actions/runs/40948647234)
and [independent internal verification](https://github.com/JiangNanGenius/floe-agent/actions/runs/40948777680)
confirmed the expected version/build, bilingual notes and internal availability.

The public-test API returned HTTP 403 while attaching the external group,
before creating a review submission. The authenticated website completed that
association and one review submission. A separate
[GET-only inspection](https://github.com/JiangNanGenius/floe-agent/actions/runs/40949321445)
confirmed the immutable source, exact prepared review notes, bilingual testing
notes, group association and one pending review. Pending review does not mean
Build 305 is publicly installable. No production App Store release occurred.

The [GitHub release](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.7.64)
was published by [run 40948524711](https://github.com/JiangNanGenius/floe-agent/actions/runs/40948524711),
including its awaited Feather job. Independent verification checked the tag
object/source binding, stable/latest status, remote digest and a real arm64
iPhoneOS executable:

```text
Floe-Agent-1.7.64-build305-unsigned.ipa
817541018 bytes
SHA-256 5af74a809b3ef4a5b3be27dce4c73a7f43796aaaba3080d35b88f43f16bf75ba
```

Finished task-owned build caches, the raw archive, duplicate App/symbol copies
and transfer staging were removed after preserving the exact recovery package,
14 matching symbol bundles, canonical IPA/checksum and original evidence.
Separate cleanup measurements total approximately 13.7 GiB of net free-space
increase; APFS clone accounting means logical/allocated copy sizes differ from
space reclaimed. Shared pinned dependencies remain for reproducibility;
simulator data, user files, unrelated work and the Build 304 rollback remain.
