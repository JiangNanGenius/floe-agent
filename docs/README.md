# Floe Agent 文档索引 / Documentation Index

先按主题阅读使用手册；需要构建、集成或追踪发布时，再查看下方工程与档案索引。 / Start with the user manual by topic; use the engineering and archive index below for development and delivery records.

## 使用手册 / User manuals

[**中文图文手册**](USER_GUIDE.zh-CN.md) · [**English illustrated manual**](USER_GUIDE.md) · [官网中文](https://www.floe-agent.com/docs/zh.html) · [Website English](https://www.floe-agent.com/docs/en.html)

| 阅读主题 / Topic | 简体中文 | English |
| --- | --- | --- |
| 安装与模型 / Install & models | [阅读](USER_GUIDE.zh-CN.md#1-安装与首次使用) | [Read](USER_GUIDE.md#1-installation-and-first-use) |
| 任务与文件 / Tasks & files | [阅读](USER_GUIDE.zh-CN.md#3-新建任务与选择工作区) | [Read](USER_GUIDE.md#3-tasks-and-workspace-ownership) |
| 手记与阅读 / Notes & reading | [阅读](USER_GUIDE.zh-CN.md#7-手记导入搜索与书写) | [Read](USER_GUIDE.md#7-notes-import-search-and-handwriting) |
| Office | [阅读](USER_GUIDE.zh-CN.md#8-office编辑批注保存和重新打开) | [Read](USER_GUIDE.md#8-office-edit-annotate-save-and-reopen) |
| 画布与媒体 / Canvas & media | [阅读](USER_GUIDE.zh-CN.md#15-画布图像音视频) | [Read](USER_GUIDE.md#15-canvas-images-audio-and-video) |
| 图纸与 3D / Drawings & 3D | [阅读](USER_GUIDE.zh-CN.md#14-工程图纸与图纸助手) | [Read](USER_GUIDE.md#14-engineering-drawings-and-ai-review) |
| 开发与连接 / Code & connections | [阅读](USER_GUIDE.zh-CN.md#9-本地终端与-linux-性能配置) | [Read](USER_GUIDE.md#9-local-terminal-and-linux-performance) |
| 常见问题 / Troubleshooting | [阅读](USER_GUIDE.zh-CN.md#20-常见问题与排查顺序) | [Read](USER_GUIDE.md#20-troubleshooting) |

## 安装与帮助 / Installation & help

[安装渠道与版本状态 / Channel status](CURRENT_STATUS.md) · [Feather / AltStore](FEATHER_SOURCE.md) · [支持 / Support](../SUPPORT.zh-CN.md) · [安全 / Security](../SECURITY.zh-CN.md)

## 开发与档案 / Engineering & archives

[工程指南 / Engineering guide](../FloeAgent/README.md) · [架构 / Architecture](ARCHITECTURE_OVERVIEW.md) · [发布档案 / Release archive](releases/README.md)

以下目录包括现行工程说明、历史研究和实施记录。历史文件只代表记录当时的状态。 / The index below includes current engineering guides, historical research and implementation records; dated records describe their recorded state.

## 当前有效（阅读与维护入口）

| 文档 | 内容 |
|---|---|
| [../AGENTS.md](../AGENTS.md) | Repository instructions for coding agents: architecture, focused checks, release recovery and cleanup |
| [../README.md](../README.md) / [../README.zh-CN.md](../README.zh-CN.md) | 项目门面：能力总览与当前交付版本 |
| [USER_GUIDE.md](USER_GUIDE.md) / [USER_GUIDE.zh-CN.md](USER_GUIDE.zh-CN.md) | 使用说明（工具、后台任务、Python、字体、工作区、远端） |
| [Skill 依赖作者规范](skills/SKILL_DEPENDENCIES_AUTHOR_GUIDE.zh-CN.md) / [English](skills/SKILL_DEPENDENCIES_AUTHOR_GUIDE.md) | 精确依赖、版本与签名覆盖；[机器 Schema](skills/dependencies.schema.json) 和[示例](skills/examples/README.md) / Exact dependencies, versioning and signed package coverage |
| [Skill Hub artwork](SKILL_HUB_ARTWORK.md) | 商店分类原创插图的固定来源与摘要 / Immutable sources and hashes for category illustrations |
| [聊天、语音及搜索资格记录](qualification/FLOE_CHAT_VOICE_SEARCH_20261023.md) | 288：207 项应用内测试、设备构建及菜单检查；交付状态单独记录 / App-hosted tests, device build and interface evidence |
| [FEATHER_SOURCE.md](FEATHER_SOURCE.md) | Feather/AltStore 安装源：稳定源地址、官网深层链接、发布校验与手动添加步骤 |
| [Scheduled Shortcut template](FLOE_SHORTCUT_SCHEDULE_TEMPLATE.md) | 签名模板、计划身份及系统交接与清理提醒的验收边界 / Signed template, stable plan binding and cleanup acceptance boundaries |
| [Shortcuts draft queue S3-B](releases/repairs/FLOE_SHORTCUTS_S3B_20261020.md) | 持久草稿、迁移及恢复源码验收：62 项原生通过；待后续安装包集成 / Durable draft source qualification; installable integration pending |
| [Build 256 stability work](releases/repairs/FLOE_256_STABILITY.md) | 候选修复：Linux 配置恢复、按任务选性能、本地终端和 Office 自由绘制；非发布记录 |
| [Office／Pencil S1 本地验收](releases/repairs/FLOE_OFFICE_PENCIL_S1_20261020.md) | 本轮原生组件及完整 App：三格式笔点与边界共 12 项通过；281 交付状态单独记录 |
| [Office 当前页面与实时笔迹](releases/repairs/FLOE_OFFICE_ASSISTANT_LIVE_INK_20261021.md) | 当前笔迹进入实际助手请求、同一手记写入求和保存，以及带侧栏／动画的普通与画笔实时缩放；[282 已交付](releases/testflight/BUILD_282_LOCAL_VERIFICATION.md)并清理 |
| [283 内测及无签名交付](releases/testflight/BUILD_283_LOCAL_VERIFICATION.md) | Office 保存／区域／导出、荧光笔、PDF／打印与文件结果；内部、稳定 Release／Feather、源码及清理已核对，公开送审单列跟进 |
| [282 内测及无签名交付](releases/testflight/BUILD_282_LOCAL_VERIFICATION.md) | 不可变源码、本地归档、独立 Apple 可安装、稳定 Release／Feather 与清理记录 |
| [Shortcuts 精确运行与文本 S3-C](releases/repairs/FLOE_SHORTCUTS_S3C_20261021.md) | 原 137 项通过保留，13 项 Intent 与 3 项实际修复／保存证明补验通过；文件和定时接续 D／S4 |
| [Office 连续双指缩放源码实现](releases/repairs/FLOE_OFFICE_LIVE_PINCH_SOURCE_20261019.md) | 连续缩放源码、组件及分模式验收历史；剩余 S1 问题分别跟踪 |
| [Excel 双指缩放锚点修复](releases/repairs/FLOE_CALC_ZOOM_ANCHOR_20261020.md) | 修复旧单元格重定位；普通／画笔完整 App 模拟器用例 2 通过，匹配设备组件及新安装包待交付 |
| [FLOE_156_FEEDBACK_REPAIR.md](releases/repairs/FLOE_156_FEEDBACK_REPAIR.md) | 反馈修复记录、PPTX 可见渲染门禁与 2026-09-22 宿主重建/重新固定更新 |
| [ARCHITECTURE_OVERVIEW.md](ARCHITECTURE_OVERVIEW.md) | 总体架构 |
| [ARCHITECTURE_LOCAL_SHELL.md](ARCHITECTURE_LOCAL_SHELL.md) | 本地 Shell / 终端 / apt·pkg 能力层架构（安全边界、Linux 兼容性、第三方许可） |
| [Shell 工具路由与运行时版本展示](FLOE_SHELL_TOOL_ROUTES.md) | 评审工具路由目录、运行时版本真实来源、`--check-tools` 校验与真机限制（2026-09-19） |
| [Floe Linux 环境后端（TinyEMU RV64）](FLOE_LINUX_GUEST_BACKEND.md) | Linux 环境 runtime、共享 guest 解释器、9p/hostfwd、边界与未合格镜像的诚实状态（2026-09-20） |
| [Linux guest 镜像构建与验证](FLOE_LINUX_GUEST_IMAGE_BUILD.md) | component-image-ci：固定输入、两次真实 PID1 启动验证（floe.epoch 时钟／签名 HTTPS APT／13 条命令）、manifest 与配套源码包、诚实限制 |
| [Linux guest 镜像来源与许可清单](FLOE_LINUX_GUEST_IMAGE_MANIFEST.md) | 逐组件 exact source／许可／缺口；当前三核镜像与对应源码已在[组件预发布](https://github.com/JiangNanGenius/floe-agent/releases/tag/floe-linux-guest-smp3-20261004.1)公开，文档保留早期候选记录 |
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
| [../skill-hub/](../skill-hub/) / `ios-wheelhouse/`（本地历史配方） | 官方技能中心 / 已封存的 iOS wheel 产线（不再随 App 分发原生载荷，见 [Phase 2 迁移](PHASE2_migration.md)） |
| [Floe 1.7 图像编辑器集成](FLOE_1_7_IMAGE_EDITOR_INTEGRATION.md) / [视频编辑器集成](FLOE_1_7_VIDEO_EDITOR_INTEGRATION.md) | 媒体编辑来源、接入状态与验证边界 |
| [媒体工作台（1.7.23／264）](FLOE_MEDIA_WORKBENCH.md) | 统一图像/视频工作台：版本化项目、渲染器、`media.project` 工具契约与已执行验证 |
| [储存空间诊断与安全清理（中英）](FLOE_STORAGE_DIAGNOSTICS.md) | 稀疏/克隆感知的计量引擎、真实根清单、诚实上限估算、所有权安全清理；含[中文版](FLOE_STORAGE_DIAGNOSTICS.zh-CN.md) |
| [设计流程（简报到导出，中英）](FLOE_DESIGN_WORKFLOW.md) | 冻结运行、锚定反馈、修订候选、采纳/拒绝/恢复、DESIGN.md 保留、能力诚实表；含[中文版](FLOE_DESIGN_WORKFLOW.zh-CN.md) |
| [统一 3D 与共享设计流程迁移（中英，1.7.29／270）](FLOE_UNIFIED_DESIGN_MIGRATION.md) | 底部插入菜单创建原生 `.floecad` 节点、旧版 3D 场景首次编辑转换与恢复、四个设计入口共用服务；含[中文版](FLOE_UNIFIED_DESIGN_MIGRATION.zh-CN.md)，安装状态见 CURRENT_STATUS |
| [CAD 引擎、cad.document 与画布子工程（1.7.24／265）](FLOE_CAD_AND_DRAWING_ASSISTANT.md) | 二维 CAD 引擎能力、无界面 Worker 宿主、`cad.document` 契约、画布绑定/分支语义与图像/视频细化；文末追加 2026-10-15 未发布的绘图/装配可发现契约（安装状态见 CURRENT_STATUS） |
| [创作工具契约与格式能力表（1.7.24／265，中英）](FLOE_1_7_24_CREATIVE_TOOLS.md) | 共享 discover→read→propose→confirm→apply→verify 契约，`cad.document`/`document.office.edit`/手记/`media.project` 模式与示例，图纸助手，以及区分已验证/引擎层待真机/不支持的 CAD 与 Office 真实格式能力表 |
| [截图档案](evidence/floe-1.7/SCREENSHOTS.md) | 界面截图与对应证据 |

## 发布档案（只追加、不回改）

逐版说明、TestFlight 文案、核验、候选与修复记录已归入 [发布档案](releases/README.md)。最近已核验交付为 [1.7.60（301）](releases/testflight/BUILD_301_DELIVERY.md)：内部 Floe QA 可用，publictest1 等待审核，稳定 latest 无签名 Release 与同次 Feather 已独立核验。424 项相关测试通过，真机与在用远端验证单列；清理和单独发现的 Python 状态查询兼容性项见交付记录。[298 记录](releases/repairs/FLOE_VOICE_INTERACTION_SEARCH_BUILD298_20261025.md)与[历史版本导览](releases/HISTORY.md)保留此前状态。Latest verified delivery: 301; internal and unsigned/Feather available, external review pending.

## 历史研究（结论以现行代码为准）

- `FRAMEWORK_AUDIT_2026-08-13.md`（本地资料，未随仓库分发）、`SPIKE_MYLLM_APP_REVIEW_RESEARCH_2026-08-22.md`（本地资料，未随仓库分发）、`reviews/CODEX_*.md`（本地资料，未随仓库分发）
- `ALPHA_DAILY_PLAN.md`（本地资料，未随仓库分发）、[MEDIA_MODEL_CATALOG_2026-09-08.md](MEDIA_MODEL_CATALOG_2026-09-08.md)（目录随版本更新）
- ⚠️ `../FloeAgent/docs/ARCHITECTURE_EXECUTION.md` 中"本轮不做本地 Python"的 P3 结论是**历史结论**；当前实现为 Linux 客体（TinyEMU RV64）运行本地 Python/Node，`FloeAgent/scripts/audit_native_runtime_free.py` 阻止原生 Python/Node/Ruby 载荷回归，见 [USER_GUIDE](USER_GUIDE.md)、[Linux 环境后端](FLOE_LINUX_GUEST_BACKEND.md) 与 [Phase 2 迁移](PHASE2_migration.md)。`ios-wheelhouse/` 与 `FloeAgent/ThirdParty/NativeRuntimeArchive/` 仅作历史配方归档，不接入构建。

## 实施跟踪（当前里程碑）

- [WORKFLOW_UPGRADE.md](WORKFLOW_UPGRADE.md) / [WORKFLOW_UPGRADE_IMPLEMENTATION.md](WORKFLOW_UPGRADE_IMPLEMENTATION.md) — Office 工作流升级
- [OFFICE_FRONTEND_ACCEPTANCE.md](OFFICE_FRONTEND_ACCEPTANCE.md) / [OFFICE_SCREENSHOT_INDEX.md](OFFICE_SCREENSHOT_INDEX.md) — Office 验收矩阵与操作证据
- [PDF_SKILL_HUB_IMPLEMENTATION.md](PDF_SKILL_HUB_IMPLEMENTATION.md) — PDF 技能中心验收（其中进程内 pandas 部分为历史，现行 Python 运行在 Linux 客体）
- [SKILL_ROUTING_UPGRADE_WORK.md](SKILL_ROUTING_UPGRADE_WORK.md)、[STABILITY_1.4.88.md](releases/repairs/STABILITY_1.4.88.md)

## 写作约定

- 面向用户的能力描述必须与工具目录一致；工具行为变化时同步 USER_GUIDE 双语版。
- 每版发布在 `releases/notes/` 新增 `RELEASE_NOTES_<版本>.md`（含 `### 简体中文` 与 `### English` 两节）与对应核验记录。
- 已过时的结论就地加"历史"横幅，不删除（保留考古上下文）。

- [Port management and linux.port / 端口管理](FLOE_PORT_MANAGEMENT.md) — 1.7.22 contract; installation availability is tracked in CURRENT_STATUS.
