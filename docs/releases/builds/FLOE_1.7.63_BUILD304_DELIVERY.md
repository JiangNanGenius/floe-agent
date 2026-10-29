# Floe 1.7.63 (304) delivery

Recorded 2026-10-30 (Australia/Sydney). This record describes Build 304 only;
subsequent provider and CAD changes use a later release identity.

| Item | Verified result |
| --- | --- |
| Immutable source | `b1fadfce38ee8f121944e07d13a7805b236ac733`, annotated tag `v1.7.63` |
| Device archive | Local Xcode 27.1 Release archive; App and extensions are 1.7.63 / 304; recovery artifact and symbols retained |
| App checks | 271 passing checks at `e98eb559`; retained source-binding evidence establishes unchanged product code for the 304 archive; 167 release-policy checks passed |
| Internal TestFlight | Apple `VALID`, unexpired, existing Floe QA group, `IN_BETA_TESTING` |
| External TestFlight | Existing `publictest1` attached; exactly one submission, `pending_review` |
| GitHub | Stable, latest, verified unsigned IPA, checksum and public provenance |
| Feather | Exact published download URL, version, source and digest read back |

The external review was submitted through the authenticated App Store Connect
website after the API rejected its review-notes PATCH with HTTP 403. The saved
notes were read back against the committed text. Independent GET-only
[inspection run 40907711955](https://github.com/JiangNanGenius/floe-agent/actions/runs/40907711955)
confirmed the source, bilingual test notes, matching review notes, attached
external group and one pending review. Earlier API failures were retained;
the App was not rebuilt or uploaded again to resolve metadata access.

The [GitHub publication](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.7.63)
was delivered by [run 40899091751](https://github.com/JiangNanGenius/floe-agent/actions/runs/40899091751),
including its awaited Feather job. Independent download verification checked
the immutable source/tag, real arm64 iPhoneOS executable, latest pointer and
remote digest:

```text
Floe-Agent-1.7.63-build304-unsigned.ipa
816885637 bytes
SHA-256 37bb405454585a9d6eac3765b900cbeddd8d1e3c1c26f319826cc8d760a89101
```

Public TestFlight approval and installation are not established by a pending
review. No production App Store release was performed. Physical-device
acceptance was not repeated for this delivery.

Source was merged and pushed to main (`38f5bf64`); a subsequent metadata-helper
repair (`a74ad4ff`) adds bounded GET-only retries without changing the frozen
App artifact. The merged, unoccupied task branch and private transport draft
were removed. Necessary recovery files, symbols, release checksums and original
failure evidence remain private. Identified obsolete build and duplicate
artifact cleanup reclaimed 11,806,265,344 bytes (about 11.0 GiB); user data,
simulator data and the immutable release artifacts were preserved. All
task-started simulators are shut down.
