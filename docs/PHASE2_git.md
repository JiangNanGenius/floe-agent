# Phase 2 — Git: Build 211 source-control crash repair

Status: **Git worker report with executed evidence.** Date: 2026-09-21.
Base: `fb6a8f26` (post Build211, includes the assistant worker's commit).
Branch/worktree: `codex/tinyemu-phase2-assistant`.

This page records the Build 211 source-control crash evidence, the
frame-resolution method that was disputed (and the resolved conclusion), the
bounded repair in `FloeAgent/Sources/FloeGit/LocalGitService.swift` and
`FloeAgent/FloeApp/Workspace/SourceControlCenter.swift`, the focused checks
that actually ran, and the honest limits — the device root cause is **not**
proven, and this change is an evidenced mitigation.

中文摘要见文末。

## 1. Crash evidence and frame resolution

Report `856863bd` (MetricKit `crashDiagnostics`, Build 211, pid 2519):
app 1.7.0 (211), `org.floeagent.ios`, iPad16,10, iPhone OS 27.0 (24A437),
TestFlight; `signal: 9`, `exceptionType: 6`, `exceptionCode: 1`,
`terminationReason: Namespace FOUNDATION, Code 0x1`. The matching full App
dSYM is UUID `C1017589-E84C-3133-8E62-25AB89663343`, source
`cc45d67023814b10f72a57afc562dbbe118ae224` (`v1.7.0-beta.68`).

### 1.1 Resolution method (record; this was ambiguous earlier)

MetricKit's `offsetIntoBinaryTextSegment` is the byte offset from the binary's
`__TEXT` segment, so the DWARF lookup address is
`vmaddr(__TEXT) + offsetIntoBinaryTextSegment`:

- the matching app dSYM has a single `__TEXT` segment
  (`vmaddr 0x100000000`, `vmsize 0x3D80000`, `otool -l`) and **no
  `__TEXT_EXEC`**;
- the sibling build-178 app binary (read-only head of the retained unsigned
  IPA) confirms the arm64 layout convention: `__TEXT vmaddr 0x100000000`,
  `fileoff 0`, i.e. "offset into the text segment" and "offset from the
  `__TEXT` vmaddr" are the same number;
- every Floe Agent frame satisfies
  `address − offsetIntoBinaryTextSegment = 0x102CB8000` (constant image base),
  so the slide is `0x2CB8000` (16 KiB-page aligned) and the lookup address is
  `0x100000000 + offset`.

Canonical command (one of the equivalent forms):

```sh
xcrun atos -arch arm64 -o "<Floe Agent.app.dSYM>/Contents/Resources/DWARF/Floe Agent" \
  --offset <offsetIntoBinaryTextSegment>
# equivalent: -l 0x100000000 with inputs 0x100000000+offset
```

Passing the raw offsets (or device absolute addresses) with
`-l 0x100000000` resolves nothing: those values are outside the image's DWARF
address space, whose lowest segment vmaddr is `0x100000000`.

| `offsetIntoBinaryTextSegment` | lookup (`0x100000000+off`) | symbol (`nm` entry) | line |
| --- | --- | --- | --- |
| `0x23FA704` | `0x1023FA704` | `LocalGitService.repositoryRoot(at:)` (`0x1023FA5FC`, frame +0x108) | `LocalGitService.swift:25` — the `FileManager.fileExists(atPath:)` probe in the ancestor walk |
| `0x23FA870` | `0x1023FA870` | `LocalGitService.snapshot(at:commitLimit:)` (`0x1023FA7BC`, +0xB4) | `LocalGitService.swift:37` — the `repositoryRoot(at:)` guard |
| `0xA6853C` | `0x100A6853C` | `SourceControlCenter.refreshRepository()` (`0x100A68120`; async continuation `TY1 0x100A6850C … TY2 0x100A68570`) | `SourceControlCenter.swift:206` — the `snapshot = try await git.snapshot(at: root)` suspension |
| `0x1E321` | `0x10001E321` | unnamed deduplicated thunk | — |
| `0x21DB9` | `0x100021DB9` | unnamed deduplicated thunk | — |

### 1.2 The disputed mapping (recorded)

An offset that is `+0x600` off (`0xA68B3C` instead of `0xA6853C`) lands inside
`SourceControlCenter.initializeRepository()` (`nm` entry `0x100A688F0`, `TY0`
`0x100A689F8`) and reports `SourceControlCenter.swift:223`:

```sh
xcrun atos -arch arm64 -o "<dSYM binary>" --offset 0x23FA704 0x23FA870 0xA68B3C
# LocalGitService.repositoryRoot(at:)      LocalGitService.swift:25
# LocalGitService.snapshot(at:commitLimit:) LocalGitService.swift:37
# SourceControlCenter.initializeRepository() SourceControlCenter.swift:223
```

`refreshRepository`'s continuations (`TY3 0x100A687B8`) and
`initializeRepository` (`0x100A688F0`) are adjacent in the binary, so
sub-kilobyte offset/base errors flip the caller attribution. With the base
fixed by the Mach-O `__TEXT` vmaddr, the caller is **`refreshRepository`
line 206** — the original mapping. `repositoryRoot(at:)` line 25 is identical
in every variant and is the frame the repair is about.

### 1.3 What is not proven

The reduced MetricKit payload (`framesOmitted: true`, no per-stack thread
boundaries) also carries:

- `ios_system +32624` (`0x7F70`) = `set_session_errno` entry
  (dSYM UUID `DC25F179-7E54-31FF-BE6D-E5739B6F7EDC`, `ios_system.m:197`);
- `text +138500` (`0x21D04`) = `parse_pos` (dSYM UUID
  `727C935D-DE7F-3F22-81F6-E27A7CB67BE8`, `sort.c:632`; `_sig_handler` sits
  immediately before it at `0x21CF0`);
- a `libsystem_platform` frame consistent with `_sigtramp`.

Those frames are consistent with the terminating process's installed
signal-handler path. The stack does **not** prove the walk reached `/`, does
**not** prove an independent shell thread caused the crash, and does **not**
identify what Foundation terminated on. The same FOUNDATION/signal-9 signature
also appears for Build 204 with the same `ios_system`/`text` offsets, so it is
recurring rather than a one-off.

Earlier notes (`docs/PHASE2_assistant.md` §6.3) listed this 22:10:31
FOUNDATION/ios_system event as "possibly shell-originated". The frame
resolution above supersedes that reading: the attributed Floe Agent frames are
the source-control refresh walk. That document is owned by another worker and
was deliberately not edited here.

## 2. Repair

`FloeAgent/Sources/FloeGit/LocalGitService.swift` — `repositoryRoot(at:)`

1. rejects non-file URLs before any filesystem probe;
2. stops at the *ownership boundary* — the app sandbox container
   (`NSHomeDirectory()`) on device, the user home on macOS — including the
   symlinked `/var` vs `/private/var` spelling; the boundary itself is checked
   for `.git` first, so a dotfiles home is still a repository;
3. probes `.git` with a single POSIX `stat` instead of
   `FileManager.fileExists` (the call recorded at the crashing line), keeping
   the old symlink-following semantics;
4. remains finite for roots outside the boundary (terminates at `/`);
5. deliberately has **no ancestor cap and no system-directory denylist** (the
   rejected first attempt), so a repository or `.git`-file
   worktree/submodule stays discoverable at any depth below the boundary.

The boundary stops the climb for app-container workspaces. Security-scoped
roots outside the container (cloud/external folders) still walk to the
filesystem root as before; only the probe change applies there.

`FloeAgent/FloeApp/Workspace/SourceControlCenter.swift` — `refreshRepository()`

- increments a monotonic `refreshGeneration`, captures the workspace root, and
  publishes only while it is still the newest generation for that same root;
- every call schedules its own snapshot instead of joining an in-flight task,
  so switching workspace A→B schedules B and A's late result (or error) is
  discarded.

This is a UI-state-coherence repair and is **not** claimed as the crash fix
(the actor already serialized synchronous snapshots).

## 3. Verification (commands actually run)

Environment: macOS arm64, Xcode-beta Swift 6.2 toolchain, cached
`libgit2.o` / module map / SwiftGitX checkout from the previous local build;
no SwiftPM resolution, no dependency download, no App build.

```sh
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
HARNESS_SCRATCH="Local/Scratch/git-harness" \
  bash FloeAgent/scripts/tests/ide_review/run_git_review_harness.sh \
  FloeAgent/scripts/tests/ide_review/git_repair211_main.swift git-repair211
HARNESS_SCRATCH="Local/Scratch/git-harness" \
  bash FloeAgent/scripts/tests/ide_review/run_git_review_harness.sh \
  FloeAgent/scripts/tests/ide_review/git_main.swift git-review191
python3 FloeAgent/scripts/tests/ide_review/review_invariants.py
```

| Check | Result |
| --- | --- |
| `git_repair211_main.swift` — non-file URL; repository above the boundary not found; same workspace found once the boundary is above it; repository at the boundary found; 70-level-deep repository + nested workspace; 70-level no-repo path nil; snapshot not-a-repository; `.git`-file worktree marker; ordinary init/nested discovery; `/`, `/System`, pathless file URL termination; intact snapshot | **17/17 PASS** |
| `git_main.swift` — Build191 behavior suite (fast-forward, merge, conflict resolve/abort, unstage, staged diff, staged-aware discard, path-safety refusals) | **71/71 PASS** (no regression from the discovery rewrite) |
| `review_invariants.py` — 22 pre-existing + 9 new Git-repair invariants (boundary, POSIX probe, no cap/denylist, refresh generation/latest-only/no stale join) | **31/31 PASS** |

SwiftPM `FloeGitTests` additions
(`repositoryRootOwnershipBoundary`, `repositoryRootPreservesDeepDiscovery` in
`FloeAgent/Tests/FloeGitTests/LocalGitServiceTests.swift`) were **not executed
locally** — the shared SwiftPM scratch was not used. They assert the same
contract as the harness against the same production sources and run in the
cloud App/test build.

## 4. Limits, integration and remaining work

- **Mitigation, not a proven root fix.** The Foundation-level trigger of the
  Build 211 termination is unresolved. The change removes the Foundation
  `fileExists` call recorded at the crashing frame and bounds the walk for
  app-container workspaces; external/cloud security-scoped roots still climb
  to the filesystem root (probe change only).
- No device or App/UI run here. Device confirmation depends on the expedited
  TestFlight build owned by the primary.
- The refresh-generation guard has static invariants but no executable test
  outside the app target.
- Integration dependency: the App target must compile
  `SourceControlCenter.swift` (cloud build) and the FloeGit test target must
  compile the two new test methods.
- Native-only: the repair stays in the local libgit2 service. No environment
  or guest/Linux dependency is introduced into the Git UI, so the Linux
  environment migration cannot leave source control routing to an unavailable
  guest through this change.

## 5. Commits

Git-repair commits on `codex/tinyemu-phase2-assistant` (base `fb6a8f26`
unchanged):

- `aa9aa136` — `fix(git): bound source-control discovery and refresh for
  build211 crash` (LocalGitService, SourceControlCenter, FloeGitTests,
  `git_repair211_main.swift`, `review_invariants.py`);
- this documentation commit (records the crash-frame resolution method and
  evidence above).

---

## 中文摘要

本次修复针对 Build 211 的源码管理崩溃（MetricKit 报告 `856863bd`，进程 2519，
`Namespace FOUNDATION, Code 0x1`，signal 9）。崩溃线程的应用帧按匹配 dSYM
（UUID `C1017589-…`，源码 `cc45d670`）解析为
`SourceControlCenter.refreshRepository()`（`SourceControlCenter.swift:206`）
→ `LocalGitService.snapshot(at:commitLimit:)`（`LocalGitService.swift:37`）
→ `LocalGitService.repositoryRoot(at:)`（`LocalGitService.swift:25`，即祖先
遍历中的 `FileManager.fileExists` 探测）。

符号化方法（已核实并记录）：MetricKit 的 `offsetIntoBinaryTextSegment` 是相对
二进制 `__TEXT` 段的偏移，查表地址为 `vmaddr(__TEXT) + offset`。本案 dSYM 只有
一个 `__TEXT` 段（`vmaddr 0x100000000`，无 `__TEXT_EXEC`），且所有 Floe Agent
帧满足 `address − offset = 0x102CB8000`（常量镜像基址、slide `0x2CB8000`
页对齐）。此前的歧义来自偏移计算误差：把第三个偏移多算 `0x600` 会落进紧邻的
`initializeRepository()`（`SourceControlCenter.swift:223`）；正确基址下调用者
是 `refreshRepository`。`repositoryRoot` 在两种映射下都相同。ios_system/text
帧（`set_session_errno` 入口、`sort.c` 中紧邻 `_sig_handler` 的 `parse_pos`）
属于进程终止信号处理路径，不能证明"走到 /"或"shell 线程污染"，本次不宣称
已知根因。

修复：`repositoryRoot(at:)` 拒绝非文件 URL；以真实沙箱归属边界
（设备为 App 容器、macOS 为用户主目录，兼容 `/var` 与 `/private/var` 两种写法）
限制向上遍历，边界本身仍先检查 `.git`；把 `FileManager.fileExists` 换成单次
POSIX `stat`；**不设任意祖先上限、不设系统目录黑名单**，任意深度的仓库与
`.git` 文件型 worktree 仍可发现。`refreshRepository()` 改为每次调用递增代际并
捕获工作区根，只允许最新代际发布，切换 A→B 时 A 的迟到结果会被丢弃。

验证（真实执行）：`git_repair211_main.swift` 17/17 通过（边界之上不发现、
边界处于仓库之上可发现、70 层深仓库、70 层无仓库终止、worktree 标记、
路径终止等）；Build191 行为回归 `git_main.swift` 71/71 通过；
`review_invariants.py` 31/31 通过（含 9 项本次新增静态不变量）。
SwiftPM `FloeGitTests` 新增用例未在本地执行（未占用共享 scratch），
与 harness 断言同一契约，交由云端构建运行。

限制：这是有证据的缓解而非已证根因修复；外部/云盘安全作用域工作区仍会走到
文件系统根；真机效果需由主流程的加急 TestFlight 构建确认。
