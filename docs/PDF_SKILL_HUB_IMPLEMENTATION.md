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
