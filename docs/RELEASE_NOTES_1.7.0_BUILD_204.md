# Floe Agent 1.7.0 (204) / beta.61 — 内部测试构建发布说明 / internal-testing release notes

> **状态：Build 204 的唯一授权 lean 云端调度已从本精确来源触发；`v1.7.0-beta.61` 由发布
> 工作流在该提交创建；签名上传由工作流完成，Apple `VALID` 与内部 Floe QA 可见性仍需单独
> 核验。**
> 本提交在 Build 203 元数据提交 `9e64d2a3`（标签 `v1.7.0-beta.60` 已冻结于该来源）之上做两
> 处最小变更：① 将 `withNativeDeadline` 的 `timeoutError` 参数标记为 `@escaping`（唯一编译
> 错误修复，无产品行为变化）；② 版本号递增为 `CURRENT_PROJECT_VERSION = 204`
> （`MARKETING_VERSION = 1.7.0` 不变），并同步再生的 Xcode 工程与双语说明。Build 204 实现
> 范围为 `0450b2ae..` 当前顶端。单次云端 App 构建与签名上传由 `release-unsigned-ipa.yml`
> lean 路由执行；不包含公开 Beta 或 App Store 生产发布。
>
> **Status: the single authorized lean cloud dispatch for Build 204 was triggered from this
> exact source; `v1.7.0-beta.61` is created at this commit by the release workflow; the signed
> upload is performed by the workflow, while Apple `VALID` and internal Floe QA visibility still
> require separate verification.** On top of the Build 203 metadata commit `9e64d2a3` (tag
> `v1.7.0-beta.60` now frozen at that source), this commit makes exactly two minimal changes:
> (1) mark `withNativeDeadline`'s `timeoutError` parameter `@escaping` (fix for the sole compile
> error; no product behavior change); (2) bump `CURRENT_PROJECT_VERSION` to `204`
> (`MARKETING_VERSION = 1.7.0` unchanged), with the regenerated Xcode project and bilingual notes
> kept in sync. Build 204 implementation range is `0450b2ae..` the current tip. The single cloud
> App build and signed upload run through the `release-unsigned-ipa.yml` lean route; no public
> beta or App Store production release is included.

## 前版失败记录 / Previous build failure record

**Build 202 / `v1.7.0-beta.59` 已冻结在失败来源 `0450b2aeb52ee4a1bad2fce4ef76f1ecd2fcdd49`，
永不移动。** 其唯一授权的 lean 云端调度 [run 35474286467](https://github.com/JiangNanGenius/floe-agent/actions/runs/35474286467)
在 accepted-SDK App 构建（[job 105980757911](https://github.com/JiangNanGenius/floe-agent/actions/runs/35474286467/job/105980757911)）
以 `xcodebuild` exit 65 失败：`SourceControlView.swift:293:90` 将非可选 `\.children` keypath
传给 SDK 26 要求 `[SourceControlChangeTreeNode]?` 的 `OutlineGroup`。未上传任何内容；
Build 202 不存在 Apple 构建号。完整证据：[build 202 lean-build failure](qualification/build202-release/build202-lean-build-failure.md)。

**Build 203 / `v1.7.0-beta.60` 已冻结在失败来源 `9e64d2a3cb96b9388994ac163bb0d3cba024d3ac`，
永不移动。** 其唯一授权的 lean 云端调度 [run 35476640882](https://github.com/JiangNanGenius/floe-agent/actions/runs/35476640882)
在 accepted-SDK App 构建（[job 105986924093](https://github.com/JiangNanGenius/floe-agent/actions/runs/35476640882/job/105986924093)，
step "Rebuild the exact tag with the accepted App Store SDK"）以 `xcodebuild` exit 65 失败，
全量重建日志与 `FloeRebuild.xcresult` 已由该运行的失败诊断产物
（`rebuild-diagnostics-run35476640882`）保留：`OfficeDocumentEditorView.swift:1153` 的
`Task { @MainActor in … }` 逃逸闭包捕获了隐式非逃逸的 `timeoutError: @autoclosure () ->
NSError` 参数（Swift 6 并发检查）。已验证的后果：未保留 unsigned IPA；恢复／Feather 产物、
dSYM、签名、TestFlight 验证与上传全部未到达；`lean-publish` 被跳过，未创建任何 GitHub
发布；**未向 App Store Connect 上传任何内容，Build 203 不存在 Apple 构建号**。

**Build 202 / `v1.7.0-beta.59` stays frozen at the failed source
`0450b2aeb52ee4a1bad2fce4ef76f1ecd2fcdd49`, never to move.** Its single authorized lean cloud
dispatch [run 35474286467](https://github.com/JiangNanGenius/floe-agent/actions/runs/35474286467)
failed in the accepted-SDK App build ([job 105980757911](https://github.com/JiangNanGenius/floe-agent/actions/runs/35474286467/job/105980757911))
with `xcodebuild` exit 65: `SourceControlView.swift:293:90` passed the non-optional `\.children`
keypath where the SDK 26 `OutlineGroup` requires `[SourceControlChangeTreeNode]?`. Nothing was
uploaded; no Apple build ID exists for build 202. Full evidence:
[build 202 lean-build failure](qualification/build202-release/build202-lean-build-failure.md).

**Build 203 / `v1.7.0-beta.60` stays frozen at the failed source
`9e64d2a3cb96b9388994ac163bb0d3cba024d3ac`, never to move.** Its single authorized lean cloud
dispatch [run 35476640882](https://github.com/JiangNanGenius/floe-agent/actions/runs/35476640882)
failed in the accepted-SDK App build ([job 105986924093](https://github.com/JiangNanGenius/floe-agent/actions/runs/35476640882/job/105986924093),
step "Rebuild the exact tag with the accepted App Store SDK") with `xcodebuild` exit 65; the full
rebuild log and `FloeRebuild.xcresult` are retained in that run's failure diagnostics artifact
(`rebuild-diagnostics-run35476640882`): the escaping `Task { @MainActor in … }` closure at
`OfficeDocumentEditorView.swift:1153` captured the implicitly non-escaping
`timeoutError: @autoclosure () -> NSError` parameter (Swift 6 concurrency check). Verified
consequences: no unsigned IPA was retained; recovery/Feather artifact, dSYM capture, signing,
TestFlight validation and upload were never reached; `lean-publish` was skipped and no GitHub
release was created; **nothing was uploaded to App Store Connect and no Apple build ID exists for
build 203**.

## 简体中文

1. **Office 原生 deadline：唯一的 Swift 6 编译修复 / the sole Swift 6 compile repair**：`withNativeDeadline` 的 `timeoutError` 参数由 `@autoclosure () -> NSError` 改为 `@escaping @autoclosure () -> NSError`（`OfficeDocumentEditorView.swift:1149`）。该参数被超时 `Task` 的逃逸闭包捕获，Swift 6 并发检查要求显式 `@escaping`；两个调用点（运行时准备、工作副本保存）的自动闭包实参不变，产品行为无变化。
2. **继承 Build 202/203 的产品与发布范围 / Build 202/203 scope carried over**：
   - 源码控制：Swift 6 OutlineGroup 子节点 keypath 编译修复（`8784442a`）；
   - 发布诊断：完整构建日志与 xcresult，失败时上传仅失败时的诊断产物（`2d3f27fa`、`0d4e6b0f`）；
   - 运行时：有界的工具后重放／检查点内存（`86636f43`）；
   - IDE：嵌套 Git 仓库发现与目录变更树（`01ec01dd`）；
   - Office：有界的打开／保存／重试（`01ec01dd`；已知残留：CodeBlitz error-95 toast 仍需真机验证）；
   - 工作区：预览直接进入图片编辑器（`b4ffc46c`）；
   - GitHub 发布方式：CI 支持普通 Latest 发布，本版 GitHub App 发布将为**正常 Latest，不是预发布**（`39fa5ec7`）。

## English

1. **Office native deadline: the sole Swift 6 compile repair**: `withNativeDeadline`'s `timeoutError` parameter changes from `@autoclosure () -> NSError` to `@escaping @autoclosure () -> NSError` (`OfficeDocumentEditorView.swift:1149`). The parameter is captured by the timeout `Task`'s escaping closure, which the Swift 6 concurrency check requires to be explicitly `@escaping`; both call sites (runtime preparation, working-copy save) keep their autoclosure arguments unchanged, with no product behavior change.
2. **Build 202/203 product and release scope carried over**:
   - Source control: Swift 6 OutlineGroup child-keypath compile repair (`8784442a`);
   - Release diagnostics: full rebuild log and xcresult, with failure-only diagnostics upload (`2d3f27fa`, `0d4e6b0f`);
   - Runtime: bounded post-tool replay/checkpoint memory (`86636f43`);
   - IDE: nested Git repository discovery and a directory change tree (`01ec01dd`);
   - Office: bounded open/save/retry (`01ec01dd`; known remainder: CodeBlitz error-95 toast still needs your on-device verification);
   - Workspace: open image files into the editor from previews (`b4ffc46c`);
   - GitHub publication mode: CI supports a normal Latest release; this build's GitHub App release is a **normal Latest release, not a prerelease** (`39fa5ec7`).

## 验证边界 / Verification boundary

本轮验证按范围要求刻意限定：聚焦源码／目标编译、专项脚本、发布元数据／项目一致性检查，
以及**一次云端 App 构建**；未运行完整 SwiftPM 测试包，不做模拟器资格、不做完整 UI 测试。
真机 UI 验收属于用户。Build 204 **不包含公开 Beta 提交，也不构成 App Store 生产发布**；
TestFlight 说明仅面向内部测试组。

Validation is deliberately limited as scoped: focused source/target compilation, dedicated
scripts and release-metadata/project consistency checks, plus **one cloud App build**. The full
SwiftPM test bundle was not run; there is no simulator qualification and no full UI test run.
Physical-device UI acceptance belongs to the user. Build 204 includes **no public Beta submission
and is not an App Store production release**; the TestFlight notes target the internal testing
group only.
