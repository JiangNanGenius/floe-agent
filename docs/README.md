# Floe Agent 文档索引 / Documentation Index

仓库文档分四类：**当前有效**（描述现状）、**发布档案**（逐版本，不可改）、**历史研究**（结论可能已过时）、**实施跟踪**。改动代码行为时同步更新"当前有效"文档；发布档案只追加、不回改。

## Floe 1.7 当前升级入口 / Current upgrade

**当前内部 TestFlight：1.7.0（216）**。2026-09-21T07:55:04Z 已核实 Apple VALID、未过期、唯一私有内部 Floe QA 组（无公开链接）及 IN_BETA_TESTING；中英文测试说明已保存并读回，真机安装仍由用户验收。固定标签 `v1.7.0-beta.73`，源码 `c2f20f6e`，[发布作业 35570785184](https://github.com/JiangNanGenius/floe-agent/actions/runs/35570785184)；未签名 IPA 已随 [v1.7.0-beta.73 预发布](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.7.0-beta.73) 证明发布，[Feather 作业 35573496016](https://github.com/JiangNanGenius/floe-agent/actions/runs/35573496016) 提交 `feather.json`（`72b21a3e`，sha256/size/sourceCommit 一致）。按用户要求跳过模拟器/界面验收，只做定向检查与云端 App 构建。详见 [TestFlight 交付记录](TESTFLIGHT_1.7.0_BETA.md) 与 [版本说明](RELEASE_NOTES_1.7.0_BUILD_216.md)。

**Build 214 已成为上一版内部交付**（`v1.7.0-beta.71`，`33759e44`，9 月 20 日 21:32 UTC 核实 VALID/未过期/Floe QA/IN_BETA_TESTING）：首个 TinyEMU/Linux 主环境版本，原生 Python/Node 不再打包；[交付证据](qualification/build214-release/README.md)保持原记录。Build 215 在其真机日志基础上修复本地模型第二轮工具续写、跨任务闭环、并行终端与取消、Git 初始化、IDE 内 Office/PDF、中文字体、保存流程和思维导图拖动。

下一版公开 TestFlight Beta 的[审核材料准备包](PUBLIC_BETA_PREPARATION.md)包含中英文介绍、测试重点、审核步骤和隐私／演示访问清单；尚未提交或开放外部测试。

此前内部 TestFlight **1.7.0（201）**，已核实 Apple VALID、未过期、唯一私有 Floe QA 组和 IN_BETA_TESTING（2026-09-19 17:44 UTC），中英文测试说明均已保存并读回。该构建的发布作业因冻结标签检出中缺少 `RELEASE_NOTES_1.7.0_BUILD_201.md` 而停止；[beta.58](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.7.0-beta.58) 开发者包与 [Feather 源](FEATHER_SOURCE.md)均由同一保留工件恢复（未重新构建、未二次上传）。Build 196（[beta.53](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.7.0-beta.53)）仍在同一内部组可安装。上一交付 191 保持原记录：三项界面失败仅获内部测试豁免。完整包/模型、RDP App 集成和部分真机验收仍未完成。[191 交付证据](qualification/build191-release/README.md)，历史记录保持原结论。

**Build 196 已在内部 Floe QA TestFlight 可安装**（Apple buildID `27355e88…`，`VALID`／未过期／唯一私有 Floe QA 组／`IN_BETA_TESTING`，2026-09-19 02:24 UTC 核实；中英文测试说明已读回）。Build 192/193 编译失败；Build 194/195 被 Apple 接受但从未发布；四个标签均作为证据保留，194–196 的 App 源码相同。工作区包含 191 反馈修复，[Build 196 发布说明](RELEASE_NOTES_1.7.0_BUILD_196.md)区分已实现、宿主级验证与待真机验收；[TestFlight 测试说明](TESTFLIGHT_1.7_WHATS_NEW_BUILD_196.json)已附加到该构建。本构建内置的签名目录已包含 `floe/ruby` 3.4.1 与 `floe/php` 8.2.33（签名批次 35399070312，源提交 `96be231e`），安装与真机运行验收仍由测试者完成；语言状态详见 [LANGUAGES.md](../capability-hub/LANGUAGES.md)。

**Build 197（1.7.0，`v1.7.0-beta.54`）编译失败，从未上传**：标签 `v1.7.0-beta.54` 固定在 `f05b02ac`（不得移动）。[run 35426497884](https://github.com/JiangNanGenius/floe-agent/actions/runs/35426497884) 的验收上传 SDK App 编译报 5 条诊断、2 个独立错误：`ExecutionEnvironmentView.swift:82/105/124/147` 找不到 `RuntimeInventoryEntry`（缺 `import FloeExecution`），`FileInspectorView.swift:132` 对已解包的 `previewPath` 重复条件绑定；编译之后的步骤全部跳过，无工件、无签名、无 TestFlight 上传。其功能实现范围 `1cff5665..11681a0f`（8 个功能提交）保持不变，[Build 197 发布说明](RELEASE_NOTES_1.7.0_BUILD_197.md)保留原记录。

**Build 198（1.7.0，`v1.7.0-beta.55`）已交付内部 Floe QA（Build 197 的替代）**：功能与 197 相同（思维导图触摸新增节点、视频公开候选与方舟凭据修复、跨 run 工具上下文恢复与摘要脱敏、执行环境真实版本与 APT 路由、妙控键盘 Return 发送／Shift+Return 换行、Office 首次预览／第二次直编与 IDE 集成、Pencil 墨迹与远端快照只读、移除无效“加入画布”入口），修复上述两处编译错误（`ExecutionEnvironmentView.swift` 增加 `import FloeExecution`；`FileInspectorView.swift` 去掉多余的第二处可选绑定），4 个 target 的版本／构建号统一为 1.7.0／198。[Build 198 发布说明](RELEASE_NOTES_1.7.0_BUILD_198.md)与 [TestFlight 测试说明](TESTFLIGHT_1.7_WHATS_NEW_BUILD_198.json)记录本轮轻量校验（swiftc parse、xcodegen、版本／构建号一致性、JSON 校验、`git diff --check`）；本地 Qwen/GDN 首次消息崩溃仍待真机确认（尚未证实修复）。

**Build 199（`v1.7.0-beta.56`）未上传，Build 200（`v1.7.0-beta.57`，`45553423`）在验收上传 SDK App 编译内停止（无工件、无签名、无上传）**；其暴露的两处 Swift 6 诊断由 `3744103f` 修复。**Build 201（`be06cece`，`v1.7.0-beta.58`）为当前内部交付**：单次验收上传 SDK 构建（[run 35453588806](https://github.com/JiangNanGenius/floe-agent/actions/runs/35453588806)）保留未签名 IPA 与匹配私有符号、TestFlight 接受上传；发布作业因冻结标签检出缺少发布说明文件而停止，GitHub 预发布与 Feather 源随后从同一保留工件恢复（未重新构建、未二次上传），复用重试暴露的 `testflight-direct.yml` 元数据校验调用缺陷已在本分支修复并加回归测试。[Build 201 发布说明](RELEASE_NOTES_1.7.0_BUILD_201.md)记录完整恢复与核验证据。

| 文档 | 阅读目的 |
|---|---|
| [Build 216 版本说明](RELEASE_NOTES_1.7.0_BUILD_216.md) | 当前内部交付：Build 215 修复集与发布路径兼容修复；TestFlight、GitHub 预发布和 Feather 已完成 |
| [Build 215 候选说明](RELEASE_NOTES_1.7.0_BUILD_215.md) | 上一版内部交付：稳定性修复、轻量验证边界与待真机验收项 |
| [178 反馈修复与 179 验证](FLOE_BUILD178_FEEDBACK_REPAIR.md) | 当前修复、原始失败、定向验证与剩余门槛 |
| [本地模型/视频/工具上下文修复（2026-09-19）](FLOE_LOCAL_VIDEO_TOOLCHAIN_REPAIR_2026-09-19.md) | 本地聊天取消竞态、公开视频候选选择、工具证据回灌的根因、改动与待真机项 |
| [Build 201 发布说明](RELEASE_NOTES_1.7.0_BUILD_201.md) | 当前交付（1.7.0/201，`v1.7.0-beta.58`）：构建与上传接受、从保留工件恢复发布、Floe QA 核验与复用步骤修复 |
| [Build 198 发布说明](RELEASE_NOTES_1.7.0_BUILD_198.md) | 已交付内部 Floe QA（1.7.0/198，`v1.7.0-beta.55`）：功能与 197 相同并修复两处编译错误 |
| [Build 197 发布说明](RELEASE_NOTES_1.7.0_BUILD_197.md) | 编译失败的候选（`v1.7.0-beta.54` 固定于 `f05b02ac`，run 35426497884 报 2 个编译错误，未上传）：功能实现、轻量校验与待真机项 |
| [Build 196 发布说明](RELEASE_NOTES_1.7.0_BUILD_196.md) | 191 反馈修复：已实现、宿主级验证与待真机验收（已交付内部 Floe QA；192/193 编译失败、194/195 上传未发布记录见各自说明） |
| [179 候选说明](RELEASE_1.7.0_BETA_36.md) | 本轮改动、已验证范围与发布状态 |
| [当前手记截图](qualification/build178-feedback/full-app-955e346a/README.md) / [CAD 编辑验证](qualification/build178-feedback/cad-layout/README.md) | 原始截图、固定源码与平台限制 |
| [未发布变更草稿](FLOE_1_7_CHANGELOG_DRAFT.md) | 本轮改动与分发前剩余工作 |
| [本轮继续实施状态](FLOE_1_7_CONTINUATION_STATUS.md) | 手记、Office、Whisper 与剩余验收事实 |
| [实施状态](FLOE_1_7_IMPLEMENTATION_STATUS.md) | 已验证路径、固定提交和剩余门槛 |
| [构建与验收](FLOE_1_7_BUILD_AND_ACCEPTANCE.md) | 本地定向测试、云端 SDK 构建和 TestFlight 门槛 |
| [迁移与恢复](FLOE_1_7_MIGRATION.md) | 分层语义、数据保护和故障恢复限制 |
| [兼容性说明](FLOE_1_7_COMPATIBILITY.md) | 包、编码器、模型的真实支持范围 |
| [包与模型资格矩阵](FLOE_1_7_QUALIFICATION_MATRIX.md) | 15 个包、33 个模型逐项状态与待验证门槛 |
| [TestFlight 候选记录](TESTFLIGHT_1.7.0_BETA.md) | 固定版本、构建尝试与 Apple 处理结果 |
| [界面截图与交互测试](evidence/floe-1.7/interface/README.md) | 通用里的日夜主题、思考框和连续工具折叠 |
| [Node 运行时](FLOE_1_7_NODE_RUNTIME.md) | 常驻宿主、依赖 pin 和验证证据 |
| [文档维护清单](FLOE_1_7_DOCUMENTATION_AUDIT.md) | 当前说明、历史档案与生成内容的维护归属 |

## 当前有效（阅读与维护入口）

| 文档 | 内容 |
|---|---|
| [../AGENTS.md](../AGENTS.md) | Repository instructions for coding agents: architecture, focused checks, release recovery and cleanup |
| [../README.md](../README.md) / [../README.zh-CN.md](../README.zh-CN.md) | 项目门面：能力总览与当前候选版本 |
| [USER_GUIDE.md](USER_GUIDE.md) / [USER_GUIDE.zh-CN.md](USER_GUIDE.zh-CN.md) | 使用说明（工具、后台任务、Python、字体、工作区、远端） |
| [ARCHITECTURE_OVERVIEW.md](ARCHITECTURE_OVERVIEW.md) | 总体架构 |
| [ARCHITECTURE_LOCAL_SHELL.md](ARCHITECTURE_LOCAL_SHELL.md) | 本地 Shell / 终端 / apt·pkg 能力层架构（安全边界、Linux 兼容性、第三方许可） |
| [Shell 工具路由与运行时版本展示](FLOE_SHELL_TOOL_ROUTES.md) | 评审工具路由目录、运行时版本真实来源、`--check-tools` 校验与真机限制（2026-09-19） |
| [Floe Linux 环境后端（TinyEMU RV64）](FLOE_LINUX_GUEST_BACKEND.md) | Linux 环境 runtime、共享 guest 解释器、9p/hostfwd、边界与未合格镜像的诚实状态（2026-09-20） |
| [Linux guest 镜像构建与验证](FLOE_LINUX_GUEST_IMAGE_BUILD.md) | component-image-ci：固定输入、两次真实 PID1 启动验证（floe.epoch 时钟／签名 HTTPS APT／13 条命令）、manifest 与配套源码包、诚实限制 |
| [Linux guest 镜像来源与许可清单](FLOE_LINUX_GUEST_IMAGE_MANIFEST.md) | 逐组件 exact source／许可／缺口：kernel GPL-2.0、bbl BSD-3、runner MPL-2.0＋静态 glibc LGPL-2.1、Debian 包→源映射；仍未公开发布 |
| [PLAN_LOCAL_SHELL.md](PLAN_LOCAL_SHELL.md) | 本地 Shell 实现记录与遗留事项 |
| `DEVELOPMENT_PLAN.md`（本地资料，未随仓库分发） | 里程碑计划（§11 的 on-device 代码排除已由本地 Shell 架构取代） |
| [FLOE_BROWSER_PROTOCOL.md](FLOE_BROWSER_PROTOCOL.md) | 浏览器自动化协议 |
| [MAIL_CONNECTOR.md](MAIL_CONNECTOR.md) | 邮件连接器 |
| [CREATIVE_MODE_AND_ASSET_ARCHITECTURE.md](CREATIVE_MODE_AND_ASSET_ARCHITECTURE.md)（+zh-CN） | 画布与素材架构 |
| [INTERNAL_PROMPT_AUDIT.md](INTERNAL_PROMPT_AUDIT.md) | 内部提示词审计 |
| [HARNESS_TIER3_DESIGN.md](HARNESS_TIER3_DESIGN.md) | 快照回滚/模型 failover/hooks 的 Tier-3 设计（对标 OpenCode/Claude Code/Kimi Code） |
| [TOOL_CLOSURE_IMPLEMENTATION.md](TOOL_CLOSURE_IMPLEMENTATION.md) | 工具闭环实现 |
| `../FloeAgent/docs/`（本地资料，未随仓库分发） | 工程侧架构（HARNESS_PROMPT_PROTOCOL 等） |
| [../FloeAgent/README.md](../FloeAgent/README.md) | 构建说明与模块图 |
| [../skill-hub/](../skill-hub/) / [../ios-wheelhouse/](../ios-wheelhouse/README.md) | 官方技能中心 / iOS wheel 产线 |

## 发布档案（只追加、不回改）

- `RELEASE_NOTES_<版本>.md` — 每个测试版的发布说明（release workflow 依固定路径读取，**勿移动**）
- [RELEASE_NOTES_1.7.0_BUILD_216.md](RELEASE_NOTES_1.7.0_BUILD_216.md) — 当前内部交付（1.7.0/216，`v1.7.0-beta.73`；已核实 Floe QA 可安装，GitHub 预发布与 Feather 已发布，真机验收由用户完成）
- [RELEASE_NOTES_1.7.0_BUILD_215.md](RELEASE_NOTES_1.7.0_BUILD_215.md) — 上一版内部交付（1.7.0/215，`v1.7.0-beta.72`）：稳定性修复、验证边界与真机测试重点
- [RELEASE_NOTES_1.7.0_BUILD_201.md](RELEASE_NOTES_1.7.0_BUILD_201.md) — 当前交付（1.7.0/201，`v1.7.0-beta.58`；构建/上传接受、发布从保留工件恢复、Floe QA 核验与复用步骤修复）
- [RELEASE_NOTES_1.7.0_BUILD_198.md](RELEASE_NOTES_1.7.0_BUILD_198.md) — 已交付内部 Floe QA（1.7.0/198，`v1.7.0-beta.55`；修复 197 的两处编译错误）
- [RELEASE_NOTES_1.7.0_BUILD_197.md](RELEASE_NOTES_1.7.0_BUILD_197.md) — 编译失败记录（1.7.0/197，`v1.7.0-beta.54` 固定于 `f05b02ac`，run 35426497884 报 2 个编译错误；从未上传；标签不动）
- [RELEASE_NOTES_1.7.0_BUILD_196.md](RELEASE_NOTES_1.7.0_BUILD_196.md) — 下一候选的完整说明（已冻结；发布工作流在冻结提交创建标签并上传，191 交付记录保持原样）
- [RELEASE_NOTES_1.7.0_BUILD_195.md](RELEASE_NOTES_1.7.0_BUILD_195.md) — 已上传但未发布（GitHub 工件服务故障丢失 TestFlight 证据；App 源码与 196 相同；标签不动）
- [RELEASE_NOTES_1.7.0_BUILD_194.md](RELEASE_NOTES_1.7.0_BUILD_194.md) — 已上传但未发布（发布工作流验证调用缺陷；App 源码与 195 相同；标签不动）
- [RELEASE_NOTES_1.7.0_BUILD_193.md](RELEASE_NOTES_1.7.0_BUILD_193.md) — 第二次冻结的失败记录（7 个 App 目标编译错误，未上传；标签不动）
- [RELEASE_NOTES_1.7.0_BUILD_192.md](RELEASE_NOTES_1.7.0_BUILD_192.md) — 首次冻结的失败记录（验收上传 SDK 编译区域隔离错误，未上传；标签不动）
- `RELEASE_VERIFICATION_<版本>.md`、`TESTFLIGHT_<版本>.md` — 对应核验与上传记录
- `RELEASE_CODE_AUDIT_20260909.md` — 1.6.1 代码审计
- [evidence/](evidence/) — 逐版本证据包

## 历史研究（结论以现行代码为准）

- `FRAMEWORK_AUDIT_2026-08-13.md`（本地资料，未随仓库分发）、`SPIKE_MYLLM_APP_REVIEW_RESEARCH_2026-08-22.md`（本地资料，未随仓库分发）、`reviews/CODEX_*.md`（本地资料，未随仓库分发）
- `ALPHA_DAILY_PLAN.md`（本地资料，未随仓库分发）、[MEDIA_MODEL_CATALOG_2026-09-08.md](MEDIA_MODEL_CATALOG_2026-09-08.md)（目录随版本更新）
- ⚠️ `../FloeAgent/docs/ARCHITECTURE_EXECUTION.md` 中"本轮不做本地 Python"的 P3 结论是**历史结论**；现状为 BeeWare CPython 内嵌 + ios-wheelhouse，见 [USER_GUIDE](USER_GUIDE.md) 与 [../ios-wheelhouse/README.md](../ios-wheelhouse/README.md)。

## 实施跟踪（当前里程碑）

- [WORKFLOW_UPGRADE.md](WORKFLOW_UPGRADE.md) / [WORKFLOW_UPGRADE_IMPLEMENTATION.md](WORKFLOW_UPGRADE_IMPLEMENTATION.md) — Office 工作流升级
- [OFFICE_FRONTEND_ACCEPTANCE.md](OFFICE_FRONTEND_ACCEPTANCE.md) / [OFFICE_SCREENSHOT_INDEX.md](OFFICE_SCREENSHOT_INDEX.md) — Office 验收矩阵与操作证据
- [PDF_SKILL_HUB_IMPLEMENTATION.md](PDF_SKILL_HUB_IMPLEMENTATION.md) — 原生 pandas 与技能中心验收
- [SKILL_ROUTING_UPGRADE_WORK.md](SKILL_ROUTING_UPGRADE_WORK.md)、[STABILITY_1.4.88.md](STABILITY_1.4.88.md)

## 写作约定

- 面向用户的能力描述必须与工具目录一致；工具行为变化时同步 USER_GUIDE 双语版。
- 每版发布新增 `RELEASE_NOTES_<版本>.md`（含 `### 简体中文` 与 `### English` 两节）与对应核验记录。
- 已过时的结论就地加"历史"横幅，不删除（保留考古上下文）。

- [Video editor integration](FLOE_1_7_VIDEO_EDITOR_INTEGRATION.md)
- [Screenshot archive](evidence/floe-1.7/SCREENSHOTS.md)

- [Floe 1.7 图像编辑器：来源、使用与验证边界](FLOE_1_7_IMAGE_EDITOR_INTEGRATION.md)

## Floe 1.7 当前发布准备

- [中英文功能介绍、版本说明及 TestFlight 测试描述](RELEASE_NOTES_1.7.0.md)
- [手记、动态导图、语音与当前证据](FLOE_1_7_CONTINUATION_STATUS.md)
- [升级和恢复，包括永久删除与资源回收](FLOE_1_7_MIGRATION.md)
- [包与模型资格矩阵](FLOE_1_7_QUALIFICATION_MATRIX.md)

当前为 [191 加急内部交付](qualification/build191-release/README.md)：原上传因发布 SDK 新增 iPhone 助手界面失败而在签名前停止；用户现已同意跳过全部三项失败，修正后的恢复任务35347141494已上传成功。13:43UTC 已核实 Apple VALID、未过期、Floe QA 和 IN_BETA_TESTING，中英文测试说明保存成功，内部测试者可安装。[190 最终结果](qualification/build190-release/final-results.json)与[封面截图](qualification/build190-release/accepted-ipad-covers-after-relaunch.png)均已保留。

- [同时编辑与冲突恢复](FLOE_CONCURRENT_EDITING.md) — IDE、文本、Office、手记的保存规则与验证边界。

- [Engineering viewers: format matrix, offline architecture and qualification](FLOE_ENGINEERING_VIEWERS.md)

- [Build 177 historical candidate record](RELEASE_NOTES_1.7.0_BUILD_177.md): earlier personalization, CAD/IDE and UI qualification work; its recorded status is historical.
- [RDP integration status](FLOE_RDP.md): pinned native bridge, real loopback evidence and remaining App integration.

- [Build 187 preparation](RELEASE_1.7.0_BETA_44.md): progressive content covers, navigation identity and pre-build localization checks; tagged d77aa11f; run35312393708 in progress, no upload yet.
- [Build 186 failed qualification](RELEASE_1.7.0_BETA_43.md): fixed source `d421fea2`, run `35306551280`; original evidence and unsigned recovery archive retained, not uploaded.
- [Build 185 candidate](RELEASE_1.7.0_BETA_42.md): durable cloud jobs, WASI environment repair and content-cover qualification; both App regressions passed but UI failures blocked upload.
- [Build 184 failed candidate](RELEASE_1.7.0_BETA_41.md): both SDK App builds passed; Lua runtime regression blocked upload.
- [Build 183 candidate](RELEASE_1.7.0_BETA_40.md): durable IDE cloud builds, real library covers, runtime lifecycle checks; App compilation failed before upload.
- [IDE GitHub Actions](IDE_GITHUB_ACTIONS.md): snapshots, workflow setup, restart recovery and cancellation.
- [Office/CAD covers](NOTES_OFFICE_THUMBNAIL_ACCEPTANCE.md): per-format content and full-App evidence requirements.
- [Runtime lifecycle](RUNTIME_LIFECYCLE_ACCEPTANCE.md): service restart, environment deletion and Lua execution acceptance.
- [Accepted-SDK recovery](ACCEPTED_SDK_RELEASE_RECOVERY.md): immutable-source artifacts, per-device gates and host reuse.
