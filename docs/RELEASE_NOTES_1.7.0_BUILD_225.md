# Floe 1.7.0 (225) — 修复 Build 224 验收 SDK 编译失败（Linux 镜像下载类型化抛错）/ Build 224 accepted-SDK compile repair (typed throws in the Linux image downloader)

Status: source candidate. This document describes the Build 225 source candidate.
All four shipping targets declare build 225 in `FloeAgent/project.yml` and the
regenerated `FloeAgent.xcodeproj` matches. Cloud App build, saved IPA, signed
upload, Apple processing, Floe QA availability, TestFlight availability,
GitHub prerelease publication and physical-device acceptance are recorded only
after each result is obtained; none is claimed here. The immutable Build 224
tag `v1.7.0-beta.81` (source `c36b7b24`) and its failed accepted-SDK run
[35767875337](https://github.com/JiangNanGenius/floe-agent/actions/runs/35767875337)
are retained unchanged; no release was dispatched for Build 225 in this
preparation.

## 简体中文

Build 225 的产品功能面与 Build 224 候选完全一致（Runtime v2 启动/迁移修复、
本地模型驻留修复、PPT 编辑入口修复、GitHub 优先的 Gitee 分片回退与
GitHub→Gitee 单向镜像）；Build 224 从未编译成功，因此 Build 225 只修复阻断
云端验收 SDK 构建的那一个编译缺陷，不改变任何已发布行为。

**Build 224 编译失败。** 验收 SDK（Xcode 26.6，iPhoneOS 26.5 SDK，Swift 6
语言模式）在 App 目标唯一报错：

```
FloeApp/Execution/LinuxGuestImageDownloader.swift:101:9: error: thrown
expression type 'any Error' cannot be converted to error type
'LinuxGuestImageTransferError'
```

`session.bytes(for:)` 是无类型抛错（`throws(any Error)`）的 Foundation 接缝，
而下载函数是 `throws(LinuxGuestImageTransferError)`；原来的 `do/catch` 只有
一个 `catch let urlError as URLError`，在类型化抛错下不是穷尽分支，编译器把
隐式继续传播的 `any Error` 判为无法转换到固定错误类型。本地此前只有包级
SwiftPM macOS 编译，不编译 `#if canImport(SwiftUI) && canImport(UIKit)` 守卫
内的 App 下载器，所以该错误只在云端设备 App 构建中暴露。

**修复方式（不弱化 fail-closed 与取消语义）。**

* `session.bytes` 的 `do/catch` 现在穷尽处理：`URLError` 仍按原表分类；任何
  非 `URLError` 的未知错误明确归类为 `.responseInvalid`（fail closed，绝不
  触发镜像切换），而不是逃逸成无法分类的 `any Error`。
* 流式写入循环的 catch 链保持原序：`CancellationError` → 已分类的
  `LinuxGuestImageTransferError` → `URLError` 分类 → `LinuxGuestImageInstallError`
  （超限/本地拒绝）→ 兜底 `.responseInvalid`；只允许
  `.networkFailure`/`.serverUnavailable` 切源的判定未改动。
* 取消语义更精确：`URLError.cancelled`（任务取消时 URLSession 会在字节流中
  抛出）只有在外层任务确已取消（`Task.isCancelled`）时才归类为
  `.cancelled`（不回退、不重试镜像）；非取消上下文中的意外取消仍 fail closed
  为 `.responseInvalid`，不会被误当作网络可用性失败而切换到 Gitee。
* HTTPS 方案限定、有界重定向（最多 8 次、只允许 HTTPS→HTTPS）、硬大小上限、
  落盘前可用空间检查、空响应拒绝与主源优先顺序均未改动。

**失败的 Build 224 记录保留。** `v1.7.0-beta.81` 指向
`c36b7b24377827de55e8546dfd0de7fb2f20125d`，保持不可变；run 35767875337 的
作业“Build once with the accepted upload SDK…”以 exit code 65 失败，无 IPA、
无上传、无 Apple 处理，其后续发布作业全部 skipped。该标签与运行记录不移动、
不删除、不替换证据。Build 225 计划使用下一个不可变标签 `v1.7.0-beta.82`；
本次准备不创建标签、不触发工作流、不发布任何交付物。

**源码验证（与云端/真机证据严格区分）。**

* 23 项定向 Linux 镜像测试在本机 Xcode 27.0 工具链（Swift 6.2）macOS 宿主
  上全部通过：镜像契约 11 项（GitHub 优先顺序、仅可用性失败切源、4xx/无效/
  本地拒绝/取消 fail closed、分片清单校验、摘要不符 fail closed）、分片暂存
  6 项（取消保留已验证分片、内容失败清除、续传复用、稳定暂存目录、陈旧项
  清理）、下载合并 4 项、安装状态 2 项。
* 针对受影响的**真实 App 源文件**做 Swift 6 类型化抛错契约编译：以仅含公共
  ABI 面的 FloeExecution 桩模块，用 iOS 26.0 Simulator SDK、
  `-swift-version 6 -enable-experimental-feature StrictConcurrency` 把修复后的
  `LinuxGuestImageDownloader.swift` 编译到对象码（SIL/代码生成，非
  `-typecheck`），零错误。同一契约下编译 Build 224 标签的原文件，精确复现
  `:100/:101 thrown expression type 'any Error' cannot be converted…`，证明该
  检查对目标缺陷有检出力。
* 这是本机源码/契约证据，不是云端验收 SDK（Xcode 26.6 + iPhoneOS 26.5）
  App 构建、签名上传、Apple 处理、TestFlight 可用性或真机行为的证据；这些
  仍需在发布流水线中单独取得。FloeExecutionTests 全量在 macOS 宿主另有 5
  项环境相关失败（客体 Python venv、客体控制台、节点管理器、后台作业
  workspace 门、WASM 目录发现），与本修复无关，在本候选中不改变其结论。

## English

Build 225 is functionally identical to the Build 224 candidate (Runtime v2
startup/migration repairs, local-model residency fix, PPT edit-entry repair,
GitHub-primary Gitee sharded fallback, and the one-way GitHub→Gitee mirror).
Build 224 never compiled, so Build 225 changes only the single defect that
blocked the cloud accepted-SDK build; no shipped behavior changes.

**The Build 224 compile failure.** The accepted SDK (Xcode 26.6, iPhoneOS 26.5
SDK, Swift 6 language mode) emitted one error in the App target:

```
FloeApp/Execution/LinuxGuestImageDownloader.swift:101:9: error: thrown
expression type 'any Error' cannot be converted to error type
'LinuxGuestImageTransferError'
```

`session.bytes(for:)` is an untyped-throws Foundation seam
(`throws(any Error)`), while the downloader function is
`throws(LinuxGuestImageTransferError)`. The old `do/catch` had only one
`catch let urlError as URLError` pattern, which is non-exhaustive under typed
throws, so the implicit propagation of a generic error was rejected as not
convertible to the fixed error type. Local package-only SwiftPM builds compile
for macOS and never build the App downloader inside its
`#if canImport(SwiftUI) && canImport(UIKit)` guard, so the error surfaced only
in the cloud device App build.

**The repair (fail-closed and cancellation semantics preserved).**

* The `session.bytes` catch is now exhaustive: `URLError` keeps the existing
  classification table; every non-`URLError` unknown failure is explicitly
  classified `.responseInvalid` (fail closed — it never switches mirrors)
  instead of escaping as an unclassifiable `any Error`.
* The streaming catch chain keeps its order: `CancellationError`, then an
  already-classified `LinuxGuestImageTransferError`, then `URLError`
  classification, then `LinuxGuestImageInstallError` (size cap/local
  rejection), then the `.responseInvalid` fallback. The rule that only
  `.networkFailure`/`.serverUnavailable` may activate the next source is
  unchanged.
* Cancellation is more precise: `URLError.cancelled` (which URLSession throws
  on the byte sequence when the task is cancelled) maps to `.cancelled` only
  while the surrounding task is actually cancelled (`Task.isCancelled`); an
  unexpected cancellation in a non-cancelled context stays fail-closed as
  `.responseInvalid` and can never masquerade as an availability failure that
  switches to Gitee.
* HTTPS-only schemes, bounded redirects (at most 8, HTTPS→HTTPS only), the
  hard byte cap, the pre-write free-space check, empty-response rejection and
  primary-first ordering are unchanged.

**The failed Build 224 is retained as evidence.** `v1.7.0-beta.81` binds
`c36b7b24377827de55e8546dfd0de7fb2f20125d` and stays immutable; run
35767875337's accepted-SDK build job failed with exit code 65, produced no IPA
and no upload, never reached Apple processing, and all downstream publish jobs
were skipped. The tag and run are not moved, deleted or re-evidenced. Build 225
is planned for the next immutable tag, `v1.7.0-beta.82`; this preparation does
not create that tag, trigger a workflow or publish any deliverable.

**Source validation (kept distinct from cloud/device evidence).**

* 23 focused Linux image tests pass locally with the Xcode 27.0 toolchain
  (Swift 6.2) on the macOS host: 11 mirror-contract tests (GitHub-first
  ordering, availability-only switching, fail-closed 4xx/invalid/local/
  cancellation, manifest validation, digest-mismatch closure), 6 shard-staging
  tests (cancellation keeps verified pieces, content-failure purge, verified
  resume, stable staging directory, stale-entry cleanup), 4 download-
  coalescing tests and 2 install-state tests.
* The **actual affected App source** was checked under a Swift 6 typed-throws
  contract: using a FloeExecution stub exposing only the public ABI surface,
  the repaired `LinuxGuestImageDownloader.swift` compiles to object code (SIL/
  codegen, not `-typecheck`) with the iOS 26.0 Simulator SDK under
  `-swift-version 6 -enable-experimental-feature StrictConcurrency`, with
  zero diagnostics. Compiling the Build 224 tagged file under the same
  contract reproduces exactly the `:100/:101 thrown expression type 'any
  Error' cannot be converted…` error, demonstrating the check catches the
  target defect.
* This is local source/contract evidence only. It is not a cloud accepted-SDK
  (Xcode 26.6 + iPhoneOS 26.5) App build, signed upload, Apple processing,
  TestFlight availability or physical-device evidence; those remain separate
  release-pipeline gates. Five other environmental failures in the full
  FloeExecutionTests macOS-host run (guest Python venv, guest console, node
  manager, background-job workspace gate, WASM catalog discovery) are
  unrelated to this repair and their conclusions are unchanged in this
  candidate.

## Build 224 failure record (immutable)

| Item | Value |
| --- | --- |
| Tag | `v1.7.0-beta.81` (retained, not moved) |
| Source | `c36b7b24377827de55e8546dfd0de7fb2f20125d` |
| Workflow run | [35767875337](https://github.com/JiangNanGenius/floe-agent/actions/runs/35767875337) (`testflight-direct.yml`, 2026-09-22, `lean_release`; tag bound by a separate successful bind job) |
| Failed job | "Build once with the accepted upload SDK or reuse the retained unsigned IPA / upload" (job 106881974925), exit code 65 |
| Diagnostic | `FloeApp/Execution/LinuxGuestImageDownloader.swift:101:9: error: thrown expression type 'any Error' cannot be converted to error type 'LinuxGuestImageTransferError'` (Xcode 26.6, iPhoneOS 26.5 SDK, Swift 6) |
| Artifacts | None: no IPA, no upload, no Apple processing; publish jobs skipped |
| Disposition | Tag/run retained as the immutable Build 224 failure record; repaired source is Build 225 (this candidate) |

## Build 223 recovery note

Build 223 remains the current delivered internal baseline, pinned by
`v1.7.0-beta.80` at source `e933305d`. Release run 35725410528 completed the
accepted-SDK build, preserved the unsigned IPA, signed and uploaded the App,
and published the GitHub prerelease. Apple build
`19f9bebc-88f0-437c-8863-b25d76e6b9be` was verified `VALID`, unexpired and
`IN_BETA_TESTING` in the sole private Floe QA group by run 35732736716 at
2026-09-22T13:19:54Z. Build 225 supersedes its source with the startup,
residency, PPT and Gitee repairs described in the Build 224 notes plus this
compile repair; physical-device behavior remains user acceptance, and the
immutable Build 223/224 tags, notes and diagnostics are retained.
