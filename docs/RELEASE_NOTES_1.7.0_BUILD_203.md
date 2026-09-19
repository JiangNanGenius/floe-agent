# Floe Agent 1.7.0 (203) / beta.60 — 内部测试构建元数据与版本准备 / internal-testing build metadata and version preparation

> **状态：仅完成发布元数据与版本准备提交；尚未触发任何 CI 构建、未上传、未创建标签、未发布。**
> 本提交冻结 Build 203 的版本号（`CURRENT_PROJECT_VERSION = 203`，`MARKETING_VERSION = 1.7.0`
> 不变）与双语说明来源。Build 203 基于 `codex/build202-device-feedback` 分支当前顶端
> `0d4e6b0f`，实现范围为 `0450b2ae..0d4e6b0f`（3 个提交）；单次云端 App 构建按计划随后在
> 同一来源上执行，当前不存在可引用的运行编号或 Apple 构建号。计划标签为
> `v1.7.0-beta.60`（尚未创建）。
>
> **Status: release-metadata and version preparation commit only; no CI build dispatched, no
> upload, no tag created, no publication.** This commit freezes the build 203 version
> (`CURRENT_PROJECT_VERSION = 203`, `MARKETING_VERSION` unchanged at `1.7.0`) and the bilingual
> notes source. Build 203 is based on the current `codex/build202-device-feedback` tip
> `0d4e6b0f`; implementation range `0450b2ae..0d4e6b0f` (3 commits). The single cloud App build
> is planned to run from the same source afterwards — no run IDs or Apple build IDs exist yet.
> Planned tag: `v1.7.0-beta.60` (not created yet).

## 前版失败记录 / Previous build failure record

**Build 202 / `v1.7.0-beta.59` 已冻结在失败来源 `0450b2aeb52ee4a1bad2fce4ef76f1ecd2fcdd49`，
永不移动。** 其唯一授权的 lean 云端调度 [run 35474286467](https://github.com/JiangNanGenius/floe-agent/actions/runs/35474286467)
在 accepted-SDK App 构建（[job 105980757911](https://github.com/JiangNanGenius/floe-agent/actions/runs/35474286467/job/105980757911)，
step "Rebuild the exact tag with the accepted App Store SDK"）以 `xcodebuild` exit 65 失败：
`SourceControlView.swift:293:90` 将非可选 `\.children` keypath 传给 SDK 26 要求
`[SourceControlChangeTreeNode]?` 的 `OutlineGroup`。已验证的后果：未保留任何 unsigned IPA；
恢复／Feather 产物、dSYM、签名、TestFlight 验证与上传全部未到达；`lean-publish` 被跳过，
未创建任何 GitHub 发布；**未向 App Store Connect 上传任何内容，Build 202 不存在 Apple
构建号**。完整证据：[build 202 lean-build failure](qualification/build202-release/build202-lean-build-failure.md)。

**Build 202 / `v1.7.0-beta.59` stays frozen at the failed source
`0450b2aeb52ee4a1bad2fce4ef76f1ecd2fcdd49`, never to move.** Its single authorized lean cloud
dispatch [run 35474286467](https://github.com/JiangNanGenius/floe-agent/actions/runs/35474286467)
failed in the accepted-SDK App build ([job 105980757911](https://github.com/JiangNanGenius/floe-agent/actions/runs/35474286467/job/105980757911),
step "Rebuild the exact tag with the accepted App Store SDK") with `xcodebuild` exit 65:
`SourceControlView.swift:293:90` passes the non-optional `\.children` keypath where the SDK 26
`OutlineGroup` requires `[SourceControlChangeTreeNode]?`. Verified consequences: no unsigned IPA
was retained; recovery/Feather artifact, dSYM capture, signing, TestFlight validation and upload
were never reached; `lean-publish` was skipped and no GitHub release was created; **nothing was
uploaded to App Store Connect and no Apple build ID exists for build 202**. Full evidence:
[build 202 lean-build failure](qualification/build202-release/build202-lean-build-failure.md).

## 本版内容 / What's in this build

1. **源码控制：Swift 6 OutlineGroup 子节点 keypath 编译修复 / Swift 6 OutlineGroup child
   keypath compile repair**（`8784442a`）：`SourceControlView` 新增计算属性
   `outlineChildren` 投影，为叶子节点返回 `nil`，保持存储的非可选 `children` 与树构建器
   不变；直接修复 Build 202 accepted-SDK Release 构建的 exit-65 编译失败。聚焦
   Swift 6 语义检查已通过；完整设备 Release 构建按计划在单次云端构建中验证。
2. **发布诊断：完整构建日志与 xcresult / full rebuild log & xcresult diagnostics**
   （`2d3f27fa`、`0d4e6b0f`）：`testflight-direct.yml` 的重建步骤现将 `xcodebuild` tee
   到完整日志文件并写 `-resultBundlePath`，失败时打印 error/warning 摘要与日志尾部，并
   仅在失败时上传诊断产物；步骤仍以真实构建状态退出（成功则继续进入打包，失败才带
   诊断退出），修复了诊断提交中 `exit` 提前跳过打包的控制流缺陷。新增聚焦测试
   `RebuildDiagnosticsControlFlowTests`（`test_release_review_workflows.py`）。
3. **继承 Build 202 的产品范围 / Build 202 product scope carried over**：
   - 运行时：有界的工具后重放／检查点内存（`86636f43`）；
   - IDE：嵌套 Git 仓库发现与目录变更树（`01ec01dd`）；
   - Office：有界的打开／保存／重试（`01ec01dd`；已知残留：CodeBlitz error-95 toast
     仍需真机验证）；
   - 工作区：预览直接进入图片编辑器（`b4ffc46c`）；
   - GitHub 发布方式：CI 支持普通 Latest 发布，本版 GitHub App 发布将为**正常 Latest，
     不是预发布**（`39fa5ec7`）。

## 验证边界 / Verification boundary

本轮验证按范围要求刻意限定：聚焦源码／目标编译、专项脚本、发布元数据／项目一致性检查，
以及**一次待执行的云端 App 构建**；未运行完整 SwiftPM 测试包，不做模拟器资格、不做完整
UI 测试。真机 UI 验收属于用户。Build 203 **不包含公开 Beta 提交，也不构成 App Store
生产发布**；TestFlight 说明仅面向内部测试组。本文档在标签创建之前存在，满足发布步骤对
冻结标签检出中说明文件的要求。

Validation is deliberately limited as scoped: focused source/target compilation, dedicated
scripts and release-metadata/project consistency checks, plus **one upcoming cloud App build**.
The full SwiftPM test bundle was not run; there is no simulator qualification and no full UI
test run. Physical-device UI acceptance belongs to the user. Build 203 includes **no public
Beta submission and is not an App Store production release**; the TestFlight notes target the
internal testing group only. This document exists before tag creation, satisfying the publish
step's requirement that the notes file be present in the frozen tag checkout.
