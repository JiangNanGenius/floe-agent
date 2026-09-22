# Floe 1.7.0 (224) — Runtime v2 启动修复、Gitee 分片回退与专项修复 / Runtime v2 startup repairs, Gitee sharded fallback and focused repairs

Status: source candidate. This document describes the Build 224 source candidate.
All four shipping targets declare build 224 in `FloeAgent/project.yml` and the
regenerated `FloeAgent.xcodeproj` matches. Cloud App build, saved IPA, signed
upload, Apple processing, Floe QA availability, TestFlight availability,
GitHub prerelease publication and physical-device acceptance are recorded only
after each result is obtained; none is claimed here.

## 简体中文

Build 224 修复 Build 223 Runtime v2 的一组启动与迁移缺陷，并加入国内网络可用的
Gitee 分片镜像回退，以及本地模型与 PPT 编辑入口两项真机反馈修复。

**Runtime v2 启动与迁移。** Build 223 中每个全新 Runtime v2 注册表都无法打开：
第 1 版迁移重复创建了引导步骤刚建立的 `schema_migrations` 表，迁移事务必然回滚，
导致“Linux 已安装却无法启动”。现在由引导步骤唯一负责该表，失败迁移会在错误中
标明自身。其余启动链一并修复：旧镜像迁移幂等（旧目录移走后重跑直接报告已验证
安装而不是报错）；源冲突路径改为 upsert 环境行，不再丢失 `repairRequired`
状态；v2 迁移移走旧目录后安装状态仍准确（由不触发迁移的已验证存储门组合判断，
runner 更新检查从展开视图读取逐字清单）；启动恢复会从已验证注册表/blob/清单重建
缺失或不完整的展开视图，并在重建失败时显式提示，绝不把设备已有的已验证内容误报
为未安装或需重新下载。需要修复（repairRequired）的迁移在迁移器与集成器两侧都
fail closed，在任何租约或物化之前报错且每次重试都报错，被隔离的数据永不覆盖。
设置中不再提供独立的“启动 Linux”控件：运行 Python/Node/Shell 会自动准备并租用
当前会话的环境；环境详情将共享基础镜像/运行时版本与每会话环境身份、状态、探测
到的客体运行时和活动 VM 分开显示。

**本地模型驻留。** Build 223 的两分钟空闲卸载在每次预加载和每轮结束后无条件
布防，计时器触发时不复查任务驻留记账，因此超过 120 秒的保留窗口（审批、慢速
工具、多轮间隔）会在任务中途拆除映射，下一轮被迫重新初始化数 GB 容器。现在只
在没有持久任务保留模型时布防，计时器触发时再以驻留记账为权威复核；最后一个任务
释放时仍按既有两分钟窗口卸载，Linux/MLX 互斥与多轮顺序工具调用保持不变。

**PPT 编辑入口。** Build 223 的 PPT/PPTX 在工作区、IDE 和手记中一直停在“打开
中”：预览正常，但编辑到不了首个可编辑渲染。宿主编辑模式初始化在引擎完成
“关闭再打开”文档切换前过早放弃。修复后权限探测预算覆盖冷页加载与文档切换，
编辑入口对未就绪/忙碌页面有界重试且只接受引擎的确定答复，渲染探测截止改为挂钟
驱动，有界结果即使探测求值永不返回也会触发，链式完成必定结算；App 侧编辑确认
有界等待，丢失的原生完成读作未验证只读而不是永久卡死。宿主框架已由 CI 从修复
源码重新构建并重新固定（run 35747909238）。首个可编辑渲染、保存重开与原文件
回写仍是真机验收项；DOCX/XLSX 维持仅打开契约。

**GitHub 优先、Gitee 分片回退。** GitHub Releases 仍是承担信任的唯一主源；
仅在主源出现有界可用性失败（断网、5xx、408/429）后才联系固定的 Gitee 镜像，
明确 4xx、无效响应、本地拒绝或取消一律 fail closed，绝不触碰镜像。573 MB 镜像
超过 Gitee 单个附件 100 MB 上限，因此镜像发布一份分片清单加九个 64 MiB 分片，
每个分片按大小与 SHA-512 固定、整包按与目录一致的 SHA-512 固定；协调器校验
清单与镜像 id/摘要，从按镜像 id 与整包摘要派生的稳定暂存目录重组，已验证分片
可复用，因此失败安装续传而不是重来；内容型失败会清除暂存与重组包，网络失败与
取消保留已验证分片；最终拼接在既有的原子导入再次校验前先比对整包 SHA-512。
公开镜像已于 2026-09-23 端到端验证（九个分片公开 URL 的大小与逐片 SHA-512 均
与清单一致，重组归档哈希与固定值一致）——这是镜像资产校验，不代表 App 已云端
构建或上架。

**GitHub→Gitee 单向镜像。** `gitee-mirror` 工作流在每次推送时把 `main` 与
`v*`、`floe-linux-guest-*` 发布标签单向推送到公开 Gitee 镜像并校验 Gitee main
与 GitHub main 一致；它从不从 Gitee 拉取，Gitee 永远不能覆盖 GitHub，令牌只经
mode-0600 临时文件与凭据助手传递，不进 argv、URL、日志或持久配置。

**源码验证。** 本轮为源码候选：`RuntimeV2StartupTests` 16 项覆盖全新打开回归、
真实 Build 223 残留数据库、重开幂等、队列恢复、租约获取/回收/隔离、幂等旧镜像
与环境迁移（含已验证磁盘差异往返）、源冲突隔离、repairRequired fail-closed 与
展开视图重建；`FloeLocalModels` 套件与重型资源仲裁、多轮顺序工具契约、Gitee
分片/回退（顺序、fail-closed 分类、清单校验、续传、暂存卫生与清除语义）以及
PPT 编辑入口确认语义和宿主链式脚本均有定向测试。云端 App 编译/打包、Apple
处理、TestFlight 可用性、发布发布与真机 PPT/MLX/PiP/Linux 行为均不在本候选的
已验证范围内。

## English

Build 224 repairs a set of Build 223 Runtime v2 startup and migration defects,
adds a Gitee sharded-mirror fallback for networks where GitHub is slow, and
ships two device-feedback fixes covering local-model residency and the PPT
edit entry.

**Runtime v2 startup and migration.** In Build 223 every fresh Runtime v2
registry failed to open: the version-1 migration re-created the
`schema_migrations` table the bootstrap had just created, so the migration
transaction always rolled back — the "Linux installed but cannot start"
report. The bootstrap now owns that table exclusively and a failing migration
names itself. The rest of the startup chain is repaired too: legacy image
migration is idempotent (a rerun after the legacy directory moved aside
reports the verified install instead of failing), the origin-conflict path
upserts the environment row rather than silently losing `repairRequired`,
install state stays accurate after the v2 migration moves the legacy directory
aside (composed from a non-migrating verified-storage gate, with the runner
update reading the verbatim manifest from the expanded view), and startup
recovery rebuilds a missing/incomplete expanded view from the verified
registry/blob/manifest, reporting an explicit failure instead of redownloading
content the device already holds. `repairRequired` migrations fail closed at
both the migrator and integrator seams, before any lease or materialization,
on every retry; quarantined data is never overwritten. Settings no longer
offers a standalone Start Linux guest control — running Python/Node/Shell
prepares and leases the conversation's environment automatically — and the
environment detail separates the shared base image/runtime version from
per-conversation identity, state, probed guest runtimes and the active VM.

**Local-model residency.** Build 223 armed the two-minute idle unload
unconditionally after every preload and every finished turn and fired the
timer without re-checking the task residency ledger, so a retained window over
120 seconds (approvals, slow tools, multi-turn gaps) tore the mapping down
mid-task and forced a multi-gigabyte container re-initialization on the next
turn. The timer now arms only while no durable task retains the model and
re-checks the ledger at fire time as the authoritative backstop; the last task
release still unloads after the existing two-minute window, and Linux/MLX
mutual exclusion and sequential multi-turn tools are unchanged.

**PPT edit entry.** Build 223's PPT/PPTX editor stayed on "opening" in
Workspace, IDE and Notes: preview worked but editing never reached the first
editable render, because host edit-mode initialization gave up before the
engine finished its close-then-reopen document switch. The permission probe
budget now covers a cold page load and the document switch, the edit entry
retries a not-ready/busy page within bounded retries and accepts only the
engine's definitive answer, the render probe deadline is wall-clock driven so
the bounded outcome fires even if a probe eval never returns, and chain
completions always settle; the App edit acknowledgement is bounded, and a
lost native completion reads as unverified read-only rather than wedging the
session. CI rebuilt and re-pinned the host framework from the repaired source
(run 35747909238). The first editable render, save/reopen and original-file
write-back remain physical-device acceptance items; DOCX/XLSX keep their
open-only contract.

**GitHub primary, Gitee sharded fallback.** GitHub Releases stays the single
trust-bearing primary; the pinned Gitee mirror is contacted only after a
bounded primary availability failure (network loss, 5xx, 408/429). A definite
4xx, invalid response, local rejection or cancellation fails closed without
touching the mirror. The 573 MB archive exceeds Gitee's 100 MB single-
attachment cap, so the mirror publishes a shard manifest plus nine 64 MiB
pieces, every piece pinned by size and SHA-512 and the whole archive by the
same digest as the catalog. The coordinator validates the manifest against the
image id/digest and reconstructs from a stable staging directory derived from
the image id and archive digest, reusing verified pieces so a failed install
resumes instead of restarting; content-shaped failures purge staging and the
assembled archive, while network failures and cancellation keep verified
pieces; the concatenation is checked against the pinned SHA-512 before the
existing atomic import re-verifies it. The public mirror was verified end to
end on 2026-09-23 (all nine pieces' sizes and per-piece SHA-512 matched the
manifest and the reassembled archive hashed to the pinned value) — that is
mirror-asset verification, not a claim that the App was cloud-built or
distributed.

**One-way GitHub→Gitee mirror.** The `gitee-mirror` workflow pushes `main`
and the `v*` / `floe-linux-guest-*` release tags one-way to the public Gitee
mirror on every push and verifies Gitee main matches GitHub main. It never
fetches from Gitee and Gitee can never overwrite GitHub; the token passes only
through mode-0600 temporary files and a credential helper, never argv, URLs,
logs or persisted config.

**Source validation.** This is a source candidate: `RuntimeV2StartupTests`
(16 tests) covers the fresh-open regression, the exact Build 223 residue
database, reopen idempotency, queue recovery, lease acquire/reclaim/quarantine,
idempotent legacy image/environment migration with a verified disk-delta round
trip, origin-conflict quarantine, repairRequired fail-closed behavior and
expanded-view rebuild; focused suites also cover `FloeLocalModels` and the
heavy-runtime arbiter, the sequential multi-turn tool contract, Gitee
shard/fallback behavior (ordering, fail-closed classification, manifest
validation, resume, staging hygiene and purge semantics), and the PPT edit-
entry acknowledgement semantics and host chain scripts. Cloud App
compile/package, Apple processing, TestFlight availability, any release
publication, and real-device PPT/MLX/PiP/Linux behavior are not validated by
this candidate.

## Build 223 recovery note

Build 223 is the current delivered internal baseline, pinned by
`v1.7.0-beta.80` at source `e933305d`. Release run 35725410528 completed the
accepted-SDK build, preserved the unsigned IPA, signed and uploaded the App,
and published the GitHub prerelease. Apple build
`19f9bebc-88f0-437c-8863-b25d76e6b9be` was verified `VALID`, unexpired and
`IN_BETA_TESTING` in the sole private Floe QA group by run 35732736716 at
2026-09-22T13:19:54Z. Build 224 supersedes its source with the startup,
residency, PPT and Gitee repairs above; physical-device behavior remains user
acceptance, and the immutable Build 223 tag, notes and diagnostics are retained.
