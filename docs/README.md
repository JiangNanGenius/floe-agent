# Floe Agent 文档索引 / Documentation Index

仓库文档分四类：**当前有效**（描述现状）、**发布档案**（逐版本，不可改）、**历史研究**（结论可能已过时）、**实施跟踪**。改动代码行为时同步更新"当前有效"文档；发布档案只追加、不回改。

## 当前阅读入口 / Start here

- [完整中文使用手册](USER_GUIDE.zh-CN.md) / [English user manual](USER_GUIDE.md)：20 章操作步骤、排障与数据保护。
- [版本与验证状态](CURRENT_STATUS.md)：已记录交付、当前候选和待验收边界。
- [官网中文版](https://www.floe-agent.com/docs/zh.html) / [Website English manual](https://www.floe-agent.com/docs/en.html)：与仓库手册同源。
- [文档更新清单](DOCUMENTATION_REFRESH_20261005.md)：本次覆盖范围；[旧版手册](history/USER_GUIDE.zh-CN.pre-20261005.md)保留旧截图和记录。
- [发布档案](releases/README.md)：逐版本原始证据，不作为当前可安装状态的实时查询。

## 当前有效（阅读与维护入口）

| 文档 | 内容 |
|---|---|
| [../AGENTS.md](../AGENTS.md) | Repository instructions for coding agents: architecture, focused checks, release recovery and cleanup |
| [../README.md](../README.md) / [../README.zh-CN.md](../README.zh-CN.md) | 项目门面：能力总览与当前交付版本 |
| [USER_GUIDE.md](USER_GUIDE.md) / [USER_GUIDE.zh-CN.md](USER_GUIDE.zh-CN.md) | 使用说明（工具、后台任务、Python、字体、工作区、远端） |
| [FEATHER_SOURCE.md](FEATHER_SOURCE.md) | Feather/AltStore 安装源：稳定源地址、官网深层链接、发布校验与手动添加步骤 |
| [Build 256 stability work](releases/repairs/FLOE_256_STABILITY.md) | 候选修复：Linux 配置恢复、按任务选性能、本地终端和 Office 自由绘制；非发布记录 |
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
| [../skill-hub/](../skill-hub/) / [../ios-wheelhouse/](../ios-wheelhouse/) | 官方技能中心 / 已封存的 iOS wheel 产线（不再随 App 分发原生载荷，见 [Phase 2 迁移](PHASE2_migration.md)） |
| [Floe 1.7 图像编辑器集成](FLOE_1_7_IMAGE_EDITOR_INTEGRATION.md) / [视频编辑器集成](FLOE_1_7_VIDEO_EDITOR_INTEGRATION.md) | 媒体编辑来源、接入状态与验证边界 |
| [截图档案](evidence/floe-1.7/SCREENSHOTS.md) | 界面截图与对应证据 |

## 发布档案（只追加、不回改）

逐版说明、TestFlight 文案、核验、候选与修复记录已归入 [发布档案](releases/README.md)。旧版状态与原索引详见 [历史版本导览](releases/HISTORY.md)；证据仍保存在 `evidence/`、`qualification/` 和 `validation/`。新发布说明写入 `releases/notes/`，测试文案写入 `releases/testflight/`。

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

- [Port management and linux.port / 端口管理](FLOE_PORT_MANAGEMENT.md) — candidate 1.7.22 contract; current availability is tracked separately.
