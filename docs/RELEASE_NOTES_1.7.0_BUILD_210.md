# Cancelled before upload

Build 210 / beta.67 (source `f6f97691`, run35504683419) was cancelled before upload after the environment settings image-download entry was found missing. The candidate had the installer and CLI, but the intended UI flow was incomplete. Build211 adds that entry. The original preparation record follows.

# Floe Agent 1.7.0 (210) — 内部测试候选版 / internal-testing candidate

> **状态：本提交只做 Build 210 的版本元数据准备：`FloeAgent/project.yml` 四个目标
> 的 `CURRENT_PROJECT_VERSION` 由 209 改为 210，再生的 Xcode 工程与双语说明同步。
> 本任务没有调度云端 App 构建、没有签名、没有上传；Build 210 的 unsigned IPA 保留、
> 签名上传、Apple `VALID` 处理与 Floe QA 可见性都尚未发生，必须单独记录。**
>
> **Status: this commit is only the Build 210 version-metadata preparation:
> `CURRENT_PROJECT_VERSION` for all four targets in `FloeAgent/project.yml` moves
> from 209 to 210, with the regenerated Xcode project and bilingual notes kept in
> sync. This task dispatched no cloud App build, no signing and no upload; the
> Build 210 unsigned IPA retention, signed upload, Apple `VALID` processing and
> Floe QA availability have not happened and must be recorded separately.**

## 前版失败记录 / Previous build failure record

**Build 209 / `v1.7.0-beta.66` 已冻结在失败来源
`43a10a0a76c3cc183340ffb36ac940df7f24f818`，不再移动。** 其唯一一次云端调度
[run 35501871606](https://github.com/JiangNanGenius/floe-agent/actions/runs/35501871606)
通过了 release preflight，但 accepted-SDK App 构建（job 106054964811）于
2026-09-20T09:44:17Z 以 `xcodebuild` exit 65 失败，报出 5 个 optional 解包错误
（`AppEnvironment.swift` 的 4 处 `TinyEMULinuxCommandService?`，
`LocalServiceTool.swift` 的 1 处 `UUID?`）。完整日志与 xcresult 保留在失败诊断产物
`rebuild-diagnostics-run35501871606`（ID 10603081167）。**未保留 unsigned IPA、
未保留 dSYM、未签名、未向 App Store Connect 上传任何内容，Build 209 不存在 Apple
构建号**；双语说明 JSON 已写好但未被使用。完整记录：
[build 209 compile failure](qualification/build209-release/build209-compile-failure.md)。

**Build 209 / `v1.7.0-beta.66` stays frozen at the failed source
`43a10a0a76c3cc183340ffb36ac940df7f24f818`, never to move.** Its single cloud
dispatch [run 35501871606](https://github.com/JiangNanGenius/floe-agent/actions/runs/35501871606)
passed release preflight but failed the accepted-SDK App build (job 106054964811)
at 2026-09-20T09:44:17Z with `xcodebuild` exit 65 and five optional-unwrap errors
(four `TinyEMULinuxCommandService?` uses in `AppEnvironment.swift`, one `UUID?`
use in `LocalServiceTool.swift`). The full log and xcresult are retained in
failure diagnostics artifact `rebuild-diagnostics-run35501871606` (ID
10603081167). **No unsigned IPA or dSYM was retained, no signing occurred and
nothing was uploaded to App Store Connect; no Apple build ID exists for build
209**; the bilingual notes JSON was prepared but unused. Full record:
[build 209 compile failure](qualification/build209-release/build209-compile-failure.md).

## 本版修复 / Fix in this candidate

`33a72da9` 修正了两处编译原因：`LinuxGuestBackendAssembly.makeService` 不再返回
可选值（无持久化 artifact root 时使用显式的 `UnavailableLinuxGuestImageResolver`，
不因镜像存储缺失而放弃环境归属）；`LocalServiceTool` 将任务的 `conversationID`
以 `UUID` 传入。该来源尚未经过云端 accepted-SDK App 构建验证。

`33a72da9` corrects both compile causes: `LinuxGuestBackendAssembly.makeService`
no longer returns an optional (with an explicit
`UnavailableLinuxGuestImageResolver` when there is no durable artifact root, so
missing image storage cannot drop environment ownership), and `LocalServiceTool`
passes the job's `conversationID` as a `UUID`. That source has not yet been
verified by a cloud accepted-SDK App build.

## 简体中文

Build 210 候选版继承为 Build 209 准备好的范围：207 的 Office、IDE 内部文档标签、
Git 初始化、原生思维导图和 Shell 修复；跨任务历史分页与最终答复恢复；本地模型
上下文压缩与工具结果处理；Linux / Python / Node / WASM 分离的包管理入口。
Linux 环境选中的 Shell、local Python 与后台服务共用 guest 后端和持久 venv，
停止的 Linux 环境不会回退到 iOS 原生包存储；TinyEMU 包含 FENCE.TSO 兼容补丁。
本次元数据准备只做了以下定向检查：xcodegen 再生与工程一致性、本地化目录校验
（1121 条，en + zh-Hans 完整）、四目标版本一致性；**未运行 App 构建、未做模拟器
或 UI 回归、未运行完整测试**。真机验收由用户执行。本候选版固定了已通过云端组件验证的 Linux 镜像，原生执行保持默认。
TestFlight 交付前，必须先完成组件镜像及对应源码的公开下载发布；镜像分发与 App 分发分别记录。

## English

Build 210 carries the scope prepared for build 209: the build 207 Office,
internal IDE document tabs, Git initialization, native mind map and Shell
repairs; cross-task history pagination and final-answer recovery; bounded
local-model context compression and tool-result handling; and separate Linux,
Python, Node and WASM package entries. Linux-selected Shell, local Python and
services share the guest backend and its persistent venv, and a stopped Linux
environment does not fall back to native iOS package storage; TinyEMU includes
the FENCE.TSO compatibility patch. This metadata preparation ran only focused
checks: xcodegen regeneration and project consistency, the localization catalog
gate (1121 entries, complete en + zh-Hans) and four-target version consistency;
**no App build, simulator/UI regression or full test suite was run**. Physical
acceptance belongs to the user. This candidate pins the cloud-qualified Linux image; native execution remains
the default. Before TestFlight delivery, the component image and matching sources
must be available at their public download URLs. Image and App delivery are tracked separately.

## 验证边界 / Verification boundary

本文档不是上传或可安装声明：只有云端构建成功、unsigned IPA 与私有符号保留、签名
上传被接受、Apple 处理为 `VALID` 且在 Floe QA 组可用之后，才可分别记录对应状态。
Build 207 的既有 TestFlight 可安装事实与 Build 209 的失败记录各自独立保留。本版本
没有公开 Beta 提交，也不构成 App Store 生产发布。

This document is not an upload or installability claim: build success, unsigned
IPA/private-symbol retention, accepted signed upload, Apple `VALID` processing
and Floe QA availability are recorded separately only after they occur. Build
207's existing TestFlight availability and build 209's failure remain
independently recorded. This build includes no public Beta submission and is not
an App Store production release.

## Fixed Linux component

- Component: `floe-linux-guest-20260920.1`; image `floe-debian13-riscv64-202609202607`.
- Archive: 572643214 bytes; SHA-512 `ad691732212fd4c229e62f71bb6d97fd41a54e1b1f9e2eb1e1aa47b3edaffb7ef21ae31948439bae2d8eba9ffe7d61b7b2e1a3049ecf57fec88996ce5641d34a`.
- Hash evidence: [run 35504351755](https://github.com/JiangNanGenius/floe-agent/actions/runs/35504351755), artifact `10602619348`. That run completed image packaging but its source-path check failed; publication is pending the corrected packaging run.
- The package uses the verified kernel/bbl/disk bytes from image run35501535251. It uses Linux4.15 with Debian13 userland. SSH/SCP transfer and iPad performance remain user acceptance items.
