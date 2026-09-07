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

### Release-gate fixes / 发布门补充修复

- CI `34124355789` passed 106 app regressions but the VNC wire test process
  crashed with an array-bounds trap. Inspection found concurrent producer,
  sender and handshake-clear access to upstream RoyalVNCKit's unsynchronized
  queue. A standalone concurrent reproducer crashes the original queue;
  the synchronized queue passes the same 40,000-operation workload under
  Thread Sanitizer. All 17 VNC contract/queue/wire tests pass locally.
- The pinned ~1 MiB RoyalVNCKit library slice and MIT license live under
  `FloeAgent/ThirdParty/RoyalVNCKit`; this replaces, not duplicates, the remote
  library dependency. Other package revisions are unchanged.
- CI `34126920690` caught generated Python framework ordering drift before
  building the app. Generation now sorts module names independently of
  shell locale; this gate is retained, not bypassed.
- The App Store SDK compatibility job exposed an unintended generic Simulator
  x86_64 link, while the native PDF/libarchive/pandas artifacts support arm64.
  The project explicitly targets arm64 devices and Apple Silicon Simulator;
  Intel Simulator support is not claimed. Both SDK gates retain real linking.

## Verified release candidate / 已验证发布候选（2026-09-08）

- Immutable app tag: `v1.4.98`, Build `129`, source
  `4d2f455cff17970a123ea2641b3d78e80d886b3e`.
- [CI 34128210921](https://github.com/JiangNanGenius/floe-agent/actions/runs/34128210921)
  passed all required jobs: 107 app tests (zero failures/skips), 990 SwiftPM
  tests, Linux build, and the stable App Store SDK Release link gate. Source
  secret scanning, SBOM and license inventory also passed. The inventory
  retains the pre-existing libgit2 license-classification warning.
- The official catalog on GitHub `main` matches the verified local catalog.
- Release workflow maintenance commit `868686c` adds the missing native Python
  suite to the stable SDK test selection; it does not change tagged app code.
  The initial release run was cancelled before uploading. The replacement
  workflow checks out the immutable app tag and applies the full test gate.
- [Main CI 34132482805](https://github.com/JiangNanGenius/floe-agent/actions/runs/34132482805)
  also passed all required jobs after this workflow-only correction.
- [Release 34132482577](https://github.com/JiangNanGenius/floe-agent/actions/runs/34132482577)
  attempt 1 was stopped by one browser fixture's five-second load-wait timeout;
  its subsequent screenshot/coordinate/input assertions passed. All PDF, RAR,
  skill and native Python cases passed. The same runner logged exceptionally
  slow WebKit startup (142 seconds for the tab lifecycle case), followed by a
  simulator diagnostic collection timeout. This is evidence of the failure,
  not proof of a production browser defect or a resolved simulator root cause.
- The unchanged six-case browser suite passed five separate local invocations
  (30 executed tests); no assertion or timeout was relaxed. Attempt 2 uses a
  fresh cloud runner and repeats the complete release gates. No app source or
  immutable tag was changed to retry this failure.
- Attempt 2's `build-verify-release` job passed 990 SwiftPM tests and all 107
  app regressions (zero failures/skips), including the unchanged browser case.
  Device packaging, artifact verification, provenance and source/built-app
  secret scans passed. The accepted-SDK device build also passed, but its app
  suite caught a real PDF serialization regression: the final saved text was
  `中⽂` (U+2F42 radical) instead of `中文` (U+6587). The intermediate document
  had passed verification; PDFKit's subsequent serialization changed it.
  106/107 stable-SDK tests passed. Upload and GitHub publication were blocked.
- Candidate `v1.4.98` remains immutable and was never uploaded to TestFlight.
  The replacement candidate is `v1.4.99` / Build `130`. Native PDF operations
  now retain verified output bytes until an actual PDFKit mutation, and verify
  saved/reopened page text at serialization boundaries. Whitespace may differ;
  Unicode radicals are never compatibility-normalized into a false pass. The
  original Chinese assertion remains, with chained-operation and lost-text
  regression checks. Mixed workflows that cannot preserve text fail explicitly.
- Upload receipt, Apple VALID and internal-group visibility for the replacement
  remain unverified until their explicit evidence is recorded.

## Physical iPad acceptance / 实体 iPad 验收清单

These are pending manual checks, not simulator-derived passes. Test on the
internal TestFlight build; retain the original input documents and record the
build number, device/iPadOS version and diagnostic export for failures.

这些项目尚未通过真机验收。请使用内部 TestFlight 构建，保留原始文件；出现
问题时记录版本号、设备/iPadOS 版本，并导出诊断日志。

- [ ] PDF: replace searchable text, copy/search the replacement and confirm
      removed text is absent; check Chinese region layout, images, rotated
      pages and nonstandard page bounds. Unsupported geometry must fail
      explicitly instead of producing a misleading success.
- [ ] PDF: annotate/fill forms/save/reopen; inspect bookmarks and metadata;
      scan OCR/search/copy; verify redacted exports contain no recoverable
      source text or attachments. Check signed/encrypted documents follow
      the displayed confirmation/credential boundaries.
- [ ] Python: cold-launch offline and run pandas CSV/groupby/merge/timezone
      operations; confirm the manifest reports native execution and no
      browser/remote fallback is silently invoked.
- [ ] Archives: list/extract representative RAR4/RAR5 files; confirm damaged,
      encrypted and multipart inputs produce explicit refusals and no partial
      destination. Verify directory/file output selection is unambiguous.
- [ ] Skills: fresh install, signed owner-repository update preview/apply,
      rollback, offline use and an already-running task retaining its version;
      custom imports must not replace the three reserved official skills.
- [ ] VNC: real server click/drag produces a fresh image or bounded structured
      observation; verify framebuffer coordinates, cancellation/button release,
      reconnect and task continuation. Loopback tests do not accept real-server
      input behavior.
- [ ] Stability: prolonged large-document/Python work, background/foreground
      transitions, memory pressure and diagnostic capture. Confirm existing PiP
      behavior remains unchanged. Do not open external Beta until accepted.
