# Floe Agent 1.7.0 (202) / beta.59 — 内部测试构建元数据与版本准备 / internal-testing build metadata and version preparation

> **状态：仅完成发布元数据与版本准备提交；尚未触发任何 CI 构建、未上传、未创建标签、未发布。**
> 本提交冻结 Build 202 的版本号（`CURRENT_PROJECT_VERSION = 202`，`MARKETING_VERSION = 1.7.0`
> 不变）与双语说明来源。Build 202 的实现范围是 `0f3cf254..86636f43`（4 个提交），基于
> `codex/build202-device-feedback` 分支当前顶端；单次云端 App 构建按计划随后在同一来源上执行，
> 当前不存在可引用的运行编号或 Apple 构建号。
>
> **Status: release-metadata and version preparation commit only; no CI build dispatched, no
> upload, no tag created, no publication.** This commit freezes the build 202 version
> (`CURRENT_PROJECT_VERSION = 202`, `MARKETING_VERSION` unchanged at `1.7.0`) and the bilingual
> notes source. Implementation range `0f3cf254..86636f43` (4 commits) on the current
> `codex/build202-device-feedback` tip; the single cloud App build is planned to run from the same
> source afterwards — no run IDs or Apple build IDs exist yet.

## 本版内容 / What's in this build

1. **运行时：有界的工具后重放／检查点内存 / bounded post-tool replay & checkpoint memory**
   （`86636f43`）：`AgentRuntime`／`AgentCheckpoint` 为有界保存工具后重放状态，远程与本地
   工具续跑不再累积无界重放／检查点内存。运行时源码与 `FloeAgentRuntimeTests` 目标已完成
   Swift 6 SIL／object 编译；全包测试运行器因本机缺少 `llama.framework` 未执行。
2. **IDE：嵌套 Git 仓库发现与目录变更树 / nested Git repository discovery & directory
   change tree**（`01ec01dd`）：`LocalGitService` 沿祖先目录发现仓库根（`.git` 目录或文件），
   嵌套在仓库／worktree 内的工作区不再误报非仓库；`SourceControlView` 以可折叠目录树展示
   变更，非 Git 工作区保留明确的空状态。新增聚焦测试已通过语法／目标编译门槛，真机交互留给用户。
3. **Office：有界的打开／保存／重试 / bounded open, save & retry**（`01ec01dd`）：打开失败
   进入可重试的终止状态；原生 prepare 与全部 `saveWorkingCopy` 路径由单次恢复截止门
   （`OfficeSaveReceipt`）约束；显式保存桥接增加有界看门狗。**已知残留**：CodeBlitz
   error-95 toast 仍需真机验证确认。save-bridge watchdog 专项测试已通过；新增的
   `LocalGitServiceTests`、`OfficeBridgeStateTests` 已通过语法检查，运行留给云端／后续验证。
4. **工作区：预览进入图片编辑 / workspace image editor entry**（`b4ffc46c`）：文件预览
   直接打开图片编辑器，编码支持位于 `FloeImages`。Focused tests: `ImageFileEncodingTests`。
5. **GitHub 发布方式 / GitHub release mode**（`39fa5ec7`）：CI 支持普通 Latest 发布，
   Build 202 的 GitHub App 发布将是**正常 Latest，不是预发布**。该工作流改动仅影响
   发布路径，不包含任何已执行的发布。

## 验证边界 / Verification boundary

本轮验证按范围要求刻意限定：聚焦源码／目标编译、专项脚本、发布元数据／项目一致性检查，以及
**一次待执行的云端 App 构建**；未运行完整 SwiftPM 测试包，不做模拟器资格、不做完整 UI 测试。真机 UI 验收属于
用户。Build 202 **不包含公开 Beta 提交，也不构成 App Store 生产发布**；TestFlight 说明仅
面向内部测试组。本文档在标签创建之前存在，满足发布步骤对冻结标签检出中说明文件的要求。

Validation is deliberately limited as scoped: focused source/target compilation, dedicated scripts
and release-metadata/project consistency checks, plus **one upcoming cloud App build**. The full
SwiftPM test bundle was not run; there is no
simulator qualification and no full UI test run. Physical-device UI acceptance belongs to the
user. Build 202 includes **no public Beta submission and is not an App Store production release**;
the TestFlight notes target the internal testing group only. This document exists before tag
creation, satisfying the publish step's requirement that the notes file be present in the frozen
tag checkout.
