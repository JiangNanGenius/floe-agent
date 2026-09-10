# Floe Agent 文档索引 / Documentation Index

仓库文档分四类：**当前有效**（描述现状）、**发布档案**（逐版本，不可改）、**历史研究**（结论可能已过时）、**实施跟踪**。改动代码行为时同步更新"当前有效"文档；发布档案只追加、不回改。

## 当前有效（阅读与维护入口）

| 文档 | 内容 |
|---|---|
| [../README.md](../README.md) / [../README.zh-CN.md](../README.zh-CN.md) | 项目门面：能力总览与当前候选版本 |
| [USER_GUIDE.md](USER_GUIDE.md) / [USER_GUIDE.zh-CN.md](USER_GUIDE.zh-CN.md) | 使用说明（工具、后台任务、Python、字体、工作区、远端） |
| [ARCHITECTURE_OVERVIEW.md](ARCHITECTURE_OVERVIEW.md) | 总体架构 |
| [DEVELOPMENT_PLAN.md](DEVELOPMENT_PLAN.md) | 里程碑计划 |
| [FLOE_BROWSER_PROTOCOL.md](FLOE_BROWSER_PROTOCOL.md) | 浏览器自动化协议 |
| [MAIL_CONNECTOR.md](MAIL_CONNECTOR.md) | 邮件连接器 |
| [CREATIVE_MODE_AND_ASSET_ARCHITECTURE.md](CREATIVE_MODE_AND_ASSET_ARCHITECTURE.md)（+zh-CN） | 画布与素材架构 |
| [INTERNAL_PROMPT_AUDIT.md](INTERNAL_PROMPT_AUDIT.md) | 内部提示词审计 |
| [HARNESS_TIER3_DESIGN.md](HARNESS_TIER3_DESIGN.md) | 快照回滚/模型 failover/hooks 的 Tier-3 设计（对标 OpenCode/Claude Code/Kimi Code） |
| [TOOL_CLOSURE_IMPLEMENTATION.md](TOOL_CLOSURE_IMPLEMENTATION.md) | 工具闭环实现 |
| [../FloeAgent/docs/](../FloeAgent/docs/) | 工程侧架构（HARNESS_PROMPT_PROTOCOL 等） |
| [../FloeAgent/README.md](../FloeAgent/README.md) | 构建说明与模块图 |
| [../skill-hub/](../skill-hub/) / [../ios-wheelhouse/](../ios-wheelhouse/README.md) | 官方技能中心 / iOS wheel 产线 |

## 发布档案（只追加、不回改）

- `RELEASE_NOTES_<版本>.md` — 每个测试版的发布说明（release workflow 依固定路径读取，**勿移动**）
- `RELEASE_VERIFICATION_<版本>.md`、`TESTFLIGHT_<版本>.md` — 对应核验与上传记录
- `RELEASE_CODE_AUDIT_20260909.md` — 1.6.1 代码审计
- [evidence/](evidence/) — 逐版本证据包

## 历史研究（结论以现行代码为准）

- [FRAMEWORK_AUDIT_2026-08-13.md](FRAMEWORK_AUDIT_2026-08-13.md)、[SPIKE_MYLLM_APP_REVIEW_RESEARCH_2026-08-22.md](SPIKE_MYLLM_APP_REVIEW_RESEARCH_2026-08-22.md)、[reviews/CODEX_*.md](reviews/)
- [ALPHA_DAILY_PLAN.md](ALPHA_DAILY_PLAN.md)、[MEDIA_MODEL_CATALOG_2026-09-08.md](MEDIA_MODEL_CATALOG_2026-09-08.md)（目录随版本更新）
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
