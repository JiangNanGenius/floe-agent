# PDF and official Skill Hub / PDF 与官方技能中心

Accepted implementation scope (2026-09-07). Baseline: v1.4.97 / 128.
Python and Executor remain independent substrates. Native code ships only in
the signed app. Only PDF, Office and Network are public official skills.

## Gates / 验收门

- [ ] Official `skill-hub/` sources, reproducible ZIPs, signed immutable catalog.
- [ ] Client official-source lock, signature/ZIP validation, compatibility,
      reviewed atomic installation, rollback and running snapshot retention.
- [ ] Hidden remote guide, real-catalog dependency validation, bounded subgroup
      discovery; Executor task IDs remain separate from Terminal session IDs.
- [ ] Native PDFium integration, text/image operations and region layout.
- [ ] PDF page, annotation, form, bookmark, metadata, OCR and export workflows.
- [ ] Explicit raster-rebuild redaction with structural verification; signed
      PDF warnings (no claim of PKI signature validation).
- [ ] RAR/RAR5 via libarchive; unambiguous destinationDir/destinationFile.
- [ ] Native CPython 3.13 pandas build, signing and offline device verification.
- [ ] Contract, recovery, security, simulator and physical iPad tests.
- [ ] Cloud CI, bilingual release, upload receipt, Apple VALID, Floe QA visibility.

No public beta. Do not mark any gate complete based only on a descriptor,
documentation, or successful compilation. Partial work is not a release.
Preserve existing PiP behavior and unrelated working-tree files.

## Checkpoint / 实施检查点（2026-09-07）

- Official catalog/ZIP signing was exercised in GitHub run `34119781836`;
  signature, ZIP and update-proof tests pass. PDF 1.2.0 signed publication
  completed in run `34124265988`; no unsigned fallback is permitted.
- Hidden remote subgroup guide and Harness planning regressions: 31 passed.
- Native PDF/RAR and existing skill lifecycle: 15 simulator tests passed;
  bundled CPython baseline: 1 passed. Inspection-selection and single-input
  snapshot hardening also passed the complete 16-test rerun.
- Native PDF supports actual object replacement, region reflow, images,
  pages, annotations, forms, bookmarks, metadata, OCR, consented raster
  redaction, reference-based unlock/encryption and text/JSON/PNG/JPEG export.
  Not claimed: arbitrary PDF-to-Word fidelity, PKI signature validation,
  preservation of signatures after editing, or vector-preserving redaction.
- RAR4/RAR5 compressed fixtures, bad/truncated/encrypted/multipart/link
  rejection and atomic cleanup have simulator evidence. RAR creation and
  encrypted/multipart decoding remain explicitly unsupported.
- pandas device/simulator wheels and native upstream testbed passed in
  `34123915397`; immutable runtime assets are pinned by SHA256. Actual Floe
  CPython pandas 3.0.5 CSV/filter/groupby/merge/missing/timezone/JSON tests
  passed on iPad Simulator, together with the stdlib smoke test (2 tests).
  This exposed and fixed missing `_contextvars`/other stdlib extensions and
  Simulator sysconfig files. App signing and physical offline verification
  remain separate open gates.
- App Store Connect discovery `34123583872` reports 1.4.97 / 128 VALID.
  Proposed next app version is 1.4.98 / 129; no upload has occurred this round.

These are automated observations, not physical iPad acceptance or a release.
