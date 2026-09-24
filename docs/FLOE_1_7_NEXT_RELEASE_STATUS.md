# Floe 1.7 next release — implementation status and verification boundaries

This is the 2026-09-23 work-package snapshot, based on `main` `ef70a208`.
Build 225 (`v1.7.0-beta.82`) was the last delivered internal build at that
point. The current Build 226 candidate and its newer component evidence are
tracked in [Build 226 candidate notes](RELEASE_NOTES_1.7.0_BUILD_226.md).
This snapshot distinguishes what was **implemented and verified** from what
was **designed but not yet verified**; its in-flight table is historical and
must not be read as the current task queue or release status.

Nothing in this snapshot claims a Build 226 IPA, upload, TestFlight
availability, or device acceptance.

## 1. Native-first capability routing (work package J) — implemented and verified

Heavy image/video/audio/PDF/OCR work must not be silently routed into the
TinyEMU Linux interpreter, while interpreter/CLI/package/server work and
explicitly scripted requests keep their normal route. Linux is not banned; the
guest is the fallback when no offered native tool covers the operation.

Implementation (all in the declared scopes):

- `Sources/FloeTools/ToolCapabilityGroups.swift` — `ToolRoutingPolicy`:
  workload classification reuses `CapabilityExecutionRouter` (native Apple
  frameworks or the app's configured model route vs. the Linux guest), so a
  tool is never "native" in discovery and "guest" at execution time. Intent
  detection (`nativeMedia` / `scripted` / `general`) handles English and
  Chinese wording with ASCII word boundaries (`remove` does not match `mov`).
- `Sources/FloeAgentRuntime/ToolDiscovery.swift` — the automatic group
  expansion for a media task subtracts interpreter groups **only when an
  offered native tool actually matches the requested operation** (subject and
  operation components must both match). An unrelated native tool (for example
  OCR) never suppresses the fallback, and a media task without a match keeps
  the primary guest entry points (`exec.shell`, `shell.open`,
  `exec.localPython`, `exec.localService`) discoverable, ranked after native
  candidates. Exact tool names and aliases always win. Discovery guidance is
  emitted only for tools this run actually offers and describes native tools
  as "on-device Apple frameworks or the app's configured model route", never
  as an on-device GPU promise.
- `Sources/FloeAgentRuntime/AgentPromptComposer.swift` — a
  `# Capability routing` layer for ordinary runs and an equivalent sentence in
  the compact on-device contract, stating the rule once without naming tools
  the request does not offer.

Verified:

- Focused tests `Tests/FloeAgentRuntimeTests/NativeMediaRoutingTests.swift`
  (17 tests, 1 suite) pass in an isolated clone of HEAD plus only these
  changes: operation coverage vs. unrelated native tools, explicit exact
  interpreter, explicit script request, missing capability fallback, mixed
  media + PDF task, disabled/unoffered tools, guidance naming only offered
  tools, and the prompt layer. Command:
  `DEVELOPER_DIR=<Xcode-beta> swift test --filter NativeMediaRoutingTests`.
- Regression parity in the same clone: `HarnessPlanningTests`,
  `ConversationToolsTests`, `ToolLoopHardeningTests` show the identical
  12 pre-existing issues with and without the change.
- Evidence: `Local/Private/active/next-release/test-logs/j-native-routing-tests-17-pass.txt`.

Not yet verified (do not claim): no device or model has been observed choosing
a native tool over the guest; the App-target compile and cloud gates remain
separate. Discovery still restores recently used groups (owned by
`AgentRuntime`), so an interpreter schema loaded for a previous task can stay
on the wire; the routing guidance prefers native tools but does not remove
already-loaded schemas.

## 2. Single third-party license entry (work package J) — implemented, content preserved

Settings now has exactly one legal entry
(**Settings → Diagnostics & About → Third-Party Licenses /
第三方开源许可**). It opens `FloeApp/Settings/TinyEMULicensesView.swift`
(`ThirdPartyLicensesView`), which:

- keeps the complete TinyEMU/slirp notices first, read from the bundled
  `TinyEMU-LICENSES.txt` (MIT core plus the BSD-2-Clause and BSD-3-Clause
  slirp texts, and the downloadable Linux guest terms), with in-place copy;
- lists every other bundled notice (PDFium, libarchive, document conversion,
  engineering viewers, OCCT, Whisper, IDE/CodeBlitz/Monaco/Oniguruma/Codicons,
  ZLImageEditor, RoyalVNCKit, each bundled CJK font family) and reports a
  missing file as unavailable instead of hiding it;
- adds a component summary with version, license identifier and source for the
  engines, Swift packages, Python runtimes and conversion/IDE components,
  mirroring the repository inventory;
- links the repository `LICENSE` and `LICENSES-THIRD-PARTY.md` as the
  authoritative generated record.

The previous second row (a TinyEMU-only screen) and the dead file link to a
repository path are removed; `DiagnosticsAboutView` now has one navigation row.
The Xcode project was regenerated with XcodeGen and the committed `pbxproj`
diff is exactly the four lines adding the new source file.

Verified: `swiftc -typecheck` for `arm64-apple-ios26.0` against the real
`FloeTheme` passes with no diagnostics; syntax parse passes for the modified
settings view. The App-target compile and UI appearance remain cloud/device
gates.

Resource-scope gap to report (not changed here): `LICENSES-THIRD-PARTY.md` is
not copied into the app bundle, and the committed file is stale relative to
`scripts/license_inventory.sh` — it has no TinyEMU/slirp/Linux guest rows, and
`libgit2`/`whisperkit` are still `UNKNOWN`. Regenerating the table (and
optionally bundling it) needs a scope that includes `scripts/` and the
repository root inventory; the in-app screen covers those components explicitly
in the meantime.

## 3. AltStore / Feather buttons and endpoints (J) — checked read-only, no website change required

- The README badges and the website download chooser point at the official
  HTTPS quick-add endpoints, not at a homepage:
  `https://www.floe-agent.com/add/feather` →
  `feather://source/https://raw.githubusercontent.com/JiangNanGenius/floe-agent/main/feather.json`
  and `https://www.floe-agent.com/add/altstore` →
  `altstore://source?url=<percent-encoded source>`.
- Live re-check on 2026-09-23 (read-only GETs): both endpoints answer HTTP 200
  with `cache-control: no-store`, a nonce-bound CSP, the exact deep link and a
  readable manual fallback (source URL, open-app and download links).
- GitHub does not support custom schemes: the GitHub Markdown API strips both
  `<a href="feather://…">` and `[text](altstore://…)` to plain text (re-verified
  2026-09-23). The bilingual READMEs therefore keep pointing at the HTTPS
  endpoints, which perform the intermediate redirect/deep-link launch and
  always render a fallback.
- No website source or deployment was modified by this work package.

## 4. Work packages in flight — design recorded, **not acceptance**

Statuses are as observed on 2026-09-23 and intentionally do not claim
completion. Gates follow `Local/Private/active/next-release/release-gates.md`
(not published).

| Package | Design | Verification gate |
| --- | --- | --- |
| A — SMP | Dual-hart RISC-V engine, shared RAM atomics/LRSC/IPI/timers, join before disk close | Real 2-hart boot and repeated performance baseline; single-core rollback retained |
| B — resources | vCPU/RAM/VM pool with real device headroom, explicit downgrade, cancellable queue | Actual boot receives allocated CPU/RAM across 4×1, 1×2+2×1 and 2×2 layouts |
| B2 — arbitration | Atomic Linux-start reservation vs. MLX entry, real idle unload before admission, no self-deadlock on tool continuation | Stop-confirm and release/reacquire sequence on device |
| C — templates | Immutable installed views plus private delta, APFS clone, pinned base, migration/GC reference checks | Real clone/disk measurement and recovery reference |
| D — packages | Cloud-built image recipes with real package versions/imports and a safe shared cache | Package inventory and cache behaviour from the guest, not a static list |
| E — archives | Native create/list/extract with progress, cancellation and path safety; optional negotiated guest bridge | Linux interoperability and no dependency deadlock |
| F — MLX | Load/benchmark/multiturn coordination, staged desensitized diagnostics, engine lease | Cloud macOS host load + multi-chunk generation passed for one frozen snapshot (run 35810169983, source `8be254c0`); the Build 225 iPad load root cause is still unresolved without a failure log |
| G / G2 — PPT | First-paint edit gate, generation/save guards, stale-preview rejection | New pinned host artifact in the IPA and a real paint/edit/save/reopen round trip |
| H — states | Shared runtime snapshot, PiP rotation, valid CPU sampling, terminal names, cold-launch notification routing | Device snapshots and notification cold routing |
| I / I2 — composer | Multi-line composer, per-instance editor state, per-conversation drafts | 100k input, IME, wrap, draft isolation and iPad/iPhone visuals on device |
| K — cloud | New SMP firmware/kernel consumed by the image build; template qualification | Exact source/hash of the actual image, built in cloud |
| Release | Immutable source, saved IPA with hash/bundle/toolchain before signing | Apple `VALID`/unexpired/Floe QA installability, reported separately |
| Mirrors | GitHub primary, Gitee one-way mirror with identical refs/assets/hashes | Verified mirror state; never substitute stale artifacts |

No component test, static parser, success string or timeout-only change counts
as iPad/device acceptance for these packages.

## 5. Documentation chapters to refresh when integration completes

Refresh, at minimum, when the packages above are integrated and verified:

1. `README.md` / `README.zh-CN.md` — “Python execution”, “Native Office
   documents”, the model paragraph (dual core / memory pool / package
   templates), and the current-candidate sentence in the documentation table.
2. `docs/USER_GUIDE.md` / `docs/USER_GUIDE.zh-CN.md` — §12 (local Python /
   guest behaviour), §13 (Office/PPT edit chain), §17 (data management and
   license entry), plus the media workbench and PiP sections.
3. `docs/ARCHITECTURE_OVERVIEW.md` — the `FloeTools`/`CapabilityExecutionRouter`
   paragraph (add the task-level `ToolRoutingPolicy`), environment layering and
   the Mermaid capability map.
4. `docs/FLOE_1_7_IMPLEMENTATION_STATUS.md`, `docs/FLOE_1_7_COMPATIBILITY.md`,
   `docs/FLOE_1_7_QUALIFICATION_MATRIX.md` — per-item verified/pending state.
5. `docs/FLOE_1_7_BUILD_AND_ACCEPTANCE.md` and `docs/README.md` — build number,
   workflow run, artifact and delivery records once a build exists.
6. `docs/FLOE_SHELL_TOOL_ROUTES.md` / `docs/FLOE_LINUX_GUEST_BACKEND.md` — guest
   resource policy and routing once A/B/B2 land.
7. `docs/RELEASE_NOTES_<version>.md` and TestFlight descriptions — only after a
   real build, upload and Apple processing exist.

## 6. Observed blockers and review items (2026-09-23)

- The shared checkout could not build the full test product in place: another
  active work package's `Sources/FloeExecution/ResourcePolicy/GuestResourceQuota.swift`
  lacks `import FloeCore` (`cannot find 'RuntimeMemoryBudget'`). Verification
  therefore ran in an isolated clone (`Local/Scratch`, since removed).
- `FloeAgent/Package.resolved` is auto-rewritten by local SwiftPM 6.4 builds;
  those rewrites are **not** approved pin changes and were not committed.
- `FloeAgent/LICENSES-THIRD-PARTY.md` is stale relative to
  `scripts/license_inventory.sh` (missing engine/guest rows, two `UNKNOWN`
  licenses) and is not bundled into the app.
- The Build 225 iPad MLX load failure root cause remains unproven; only the
  cloud macOS host run is verified. Do not describe device loading as fixed.
- Pre-existing runtime test failures at HEAD (unchanged by this work):
  four `HarnessPlanning` compaction tests, five `ConversationTools` long-item
  tests and one `ToolLoopHardening` skill-read test — 12 issues in total.

## 7. 简体中文摘要

基线为 `main` `ef70a208`，Build 225（`v1.7.0-beta.82`）是最近一次内部交付。
本文件只记录状态，不预留构建号，也不宣称任何云端构建、上传、TestFlight 或真机结果。

**已实现并验证（J）**：设置中只保留一个第三方开源许可入口，完整保留
TinyEMU/slirp 全文与其他随包声明；原生媒体（图像/视频/音频/PDF/OCR）优先路由，
只有当前任务确实提供且与该操作匹配的原生工具才会抑制解释器自动展开；用户明确要求
脚本或能力不足时仍可使用 Linux 客体。17 项定向测试通过，回归对比显示既有失败集合
不因本改动变化。

**已设计、未验收**：SMP 双核、资源池、Linux/MLX 仲裁、模板、包、归档、MLX、
PPT、PiP、长输入、云端流水线等按第 4 节矩阵记录，均不得标记为已通过。MLX 仅有
云端 macOS 主机证据，iPad Build 225 加载根因仍未证实。

**待最终刷新章节**：见第 5 节（README、用户指南第 12/13/17 节、架构总览、
实施状态与资格矩阵、构建验收与文档索引、发布说明）。
