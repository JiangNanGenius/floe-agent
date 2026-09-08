# Floe 1.5.2 / Build 133 — release verification

Source: `5acdb0fee97a3459d70a1ac03f1b9c6ab0c47233`; immutable tag `v1.5.2`.

## Verified before dispatch

- Version/build match all app and extension targets; project regeneration is clean; release preflight passed.
- Targeted iPhone 17 Pro / iOS 27 Simulator runs passed model catalog and provider request contracts, document conversions and asset/path rejection cases. The final PDF rerun passed after the Unicode font correction.
- Long conversion: 48,122 source characters, 42 PDF pages, all 200 paragraph markers and final marker preserved. Distinct CJK/radical/full-width code points remain distinct; source bytes are unchanged.
- Actual converted PDF rendered for inspection: [conversion result](images/workflow-upgrade/document-conversion-pdf.png). Earlier UI screenshots remain in [workflow evidence](WORKFLOW_UPGRADE.md).
- Staged secret scan passed; 152 dependencies inventoried. Modified Noto Sans SC export font ships with OFL license and reproducible build provenance.
- Signed Skill Hub validation passed for main and release tag: [tag verification](https://github.com/JiangNanGenius/floe-agent/actions/runs/34231451553).

## Cloud release gates

- [Full CI](https://github.com/JiangNanGenius/floe-agent/actions/runs/34231451506): cancelled after the release test failure and superseded by 1.5.3; its Linux job passed.
- [Release build, SDK checks, signing and upload](https://github.com/JiangNanGenius/floe-agent/actions/runs/34231451543): failed.
- Apple processing: not reached; build stopped before upload.
- Floe QA internal tester visibility: unavailable for this build.

Full SwiftPM tests rejected a signed catalog whose `releaseNotes` was a string instead of the localized dictionary expected by the app. The signature-only verification did not detect that schema mismatch. Version 1.5.2 was not uploaded; version 1.5.3 corrects the source metadata and validates it before signing. The v1.5.2 tag remains immutable.

## Remaining acceptance boundaries

The release does not enable the complete native Office editing engine. [Native engine qualification](https://github.com/JiangNanGenius/floe-agent/actions/runs/34212234638) stopped at its disk reserve before integration. Markdown/DOCX/HTML/RTF/PDF conversions are semantic conversions with the limits described in the tool and Skill guides; they are not an exact Office page-layout round trip. Live provider account/region permissions, actual generated media and physical-device long-session UX still require device testing.
