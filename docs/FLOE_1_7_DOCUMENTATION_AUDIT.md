# Floe 1.7 文档维护清单

## 2026-09-22 Build 219 公开文档审计 / Build 219 public-doc audit

本轮把公开文档的“当前状态”对齐到 Build 219（TinyEMU/Linux 主要本地运行时），不修改任何代码、工作流、发布标签、`feather.json` 或私有文件：

- 双语 README 与使用指南改写了当前交付线：首次使用 Linux 的自动准备流程及设置／终端入口、客体网络自配置、无原生 Python/Node/Ruby 载荷、工作区 Office 预览 → 独立全屏编辑而 IDE 文件树保留内嵌标签、有界压缩包浏览（ZIP/TAR/7z）与需要 Linux 运行时的格式如实提示、IDE 源码管理即时刷新、MLX 快照校验与客体内存核算（Gemma 4 E4B 退出推荐列表）。
- 语言包描述由旧的 `apt install floe/lua|ruby|php` 形式改为签名 WASI 目录（`wasm.packages`），并明确它不是 Debian 包。
- `docs/README.md` 重建当前入口：当前内部交付为 219（`v1.7.0-beta.76` / `0b21be93`，TestFlight、未签名 GitHub 预发布与 Feather 源均已发布），218 归为上一内部交付；旧 216/201/196/197/198/199/200 段落归入“历史交付记录”。Build 219 已由主 Agent 核实 Apple VALID、未过期、唯一私有 Floe QA 组及 IN_BETA_TESTING；真机行为仍由用户验收。
- `FEATHER_SOURCE.md`、`ARCHITECTURE_OVERVIEW.md`、`ARCHITECTURE_LOCAL_SHELL.md`、`FLOE_1_7_COMPATIBILITY.md`、`FLOE_1_7_IMPLEMENTATION_STATUS.md`、`FLOE_LINUX_GUEST_BACKEND.md`、`FLOE_1_7_REPAIR_LIFECYCLE_MLX_IDE_OFFICE.md`、`FLOE_1_7_LINUX_GUEST_NETWORK_REPAIR.md`、`PUBLIC_BETA_PREPARATION.md`、`WORKFLOW_UPGRADE.md` 修正当前状态并保留原始日期、提交、运行编号与失败结论。`FLOE_1_7_LINUX_GUEST_NETWORK_REPAIR.md` 补记云端复核 run 35652797196（`netStatus=up`、`failures=0`）。
- 历史文件（`RELEASE_NOTES_*`、`TESTFLIGHT_*`、`RELEASE_VERIFICATION_*`、`evidence/`）不作回改；已退役内容（进程内 Node、原生 Python 宿主、iOS wheel 产线）只加“已退役／历史”标注。
- 检查：仓库内相对链接与引用、README 快速添加链接／Feather 源静态检查（`FloeAgent/scripts/tests/test_readme_source_links.py`）、中英文结构对照与私有信息关键词扫描。本清单只登记本轮刷新范围，不代表所有历史技术事实已重新验证。

本轮刷新介绍、双语 README/使用指南、产品、总体架构、shell 边界、工程构建、贡献、支持、安全、技能中心和 wheelhouse 说明；新增构建验收、迁移恢复和兼容性入口。此清单是维护范围登记，不表示所有历史文档中的技术事实已重新验证。

当前版本状态统一引用 [实施状态](FLOE_1_7_IMPLEMENTATION_STATUS.md)。历史发布与证据不可回写成新版本成功结果；第三方许可/来源及签名生成产物保留各自流程。旧专题在对应功能变化时更新正文，不用统一日期掩盖内容年龄。

本地忽略的 `DESIGN.md` 和 `docs/DEVELOPMENT_PLAN.md` 已补充 1.7 方向，但仍遵循仓库原有忽略规则，不强行纳入提交。网站在线内容不由这些 Markdown 自动证明已部署。floe-video 已更新为 1.0.1，同步简短变更说明，并经云端签名与本地校验；后续能力接通仍须继续维护。

媒体工作台最小 App 的构建/模型测试说明见 [NativeMedia](../FloeAgent/Qualification/NativeMedia/README.md)；最新变更草稿见 [未发布变更](FLOE_1_7_CHANGELOG_DRAFT.md)。英文指南和工程构建说明已再次校对，默认采用本地定向测试与云端 App 构建。

## 文件登记

| 文件 | 类别 | 本轮处理 |
|---|---|---|
| [.github/PULL_REQUEST_TEMPLATE.md](../.github/PULL_REQUEST_TEMPLATE.md) | 专题说明/既有计划 | 保留专题范围；1.7 进展以实施状态为准，后续随对应代码更新 |
| [CODE_OF_CONDUCT.md](../CODE_OF_CONDUCT.md) | 治理/许可 | 与本轮功能升级无冲突，保留政策正文 |
| [CODE_OF_CONDUCT.zh-CN.md](../CODE_OF_CONDUCT.zh-CN.md) | 治理/许可 | 与本轮功能升级无冲突，保留政策正文 |
| [CONTRIBUTING.md](../CONTRIBUTING.md) | 当前 1.7 说明 | 本轮更新或引用当前实施状态 |
| [CONTRIBUTING.zh-CN.md](../CONTRIBUTING.zh-CN.md) | 当前 1.7 说明 | 本轮更新或引用当前实施状态 |
| [FloeAgent/Qualification/NativeNode/README.md](../FloeAgent/Qualification/NativeNode/README.md) | 专题说明/既有计划 | 保留专题范围；1.7 进展以实施状态为准，后续随对应代码更新 |
| [FloeAgent/Qualification/Tests/PackageTests/Fixtures/README.md](../FloeAgent/Qualification/Tests/PackageTests/Fixtures/README.md) | 专题说明/既有计划 | 保留专题范围；1.7 进展以实施状态为准，后续随对应代码更新 |
| [FloeAgent/README.md](../FloeAgent/README.md) | 当前 1.7 说明 | 本轮更新或引用当前实施状态 |
| [FloeAgent/ThirdParty/Collabora/EMBEDDING_INPUTS.md](../FloeAgent/ThirdParty/Collabora/EMBEDDING_INPUTS.md) | 第三方或捆绑/生成内容 | 保留来源、许可与生成流程，不批量改写 |
| [FloeAgent/ThirdParty/Collabora/patches/xlsx-embedded-objects.md](../FloeAgent/ThirdParty/Collabora/patches/xlsx-embedded-objects.md) | 第三方或捆绑/生成内容 | 保留来源、许可与生成流程，不批量改写 |
| [FloeAgent/ThirdParty/DashIOS/PROVENANCE.md](../FloeAgent/ThirdParty/DashIOS/PROVENANCE.md) | 第三方或捆绑/生成内容 | 保留来源、许可与生成流程，不批量改写 |
| [FloeAgent/ThirdParty/DocumentConversion/FONT_PROVENANCE.md](../FloeAgent/ThirdParty/DocumentConversion/FONT_PROVENANCE.md) | 第三方或捆绑/生成内容 | 保留来源、许可与生成流程，不批量改写 |
| [FloeAgent/ThirdParty/DocumentConversion/README.md](../FloeAgent/ThirdParty/DocumentConversion/README.md) | 第三方或捆绑/生成内容 | 保留来源、许可与生成流程，不批量改写 |
| [FloeAgent/ThirdParty/FloeShellEngine/PROVENANCE.md](../FloeAgent/ThirdParty/FloeShellEngine/PROVENANCE.md) | 第三方或捆绑/生成内容 | 保留来源、许可与生成流程，不批量改写 |
| [FloeAgent/ThirdParty/RoyalVNCKit/FLOE_PATCHES.md](../FloeAgent/ThirdParty/RoyalVNCKit/FLOE_PATCHES.md) | 第三方或捆绑/生成内容 | 保留来源、许可与生成流程，不批量改写 |
| [FloeAgent/ThirdParty/WasmKit/FLOE_PATCHES.md](../FloeAgent/ThirdParty/WasmKit/FLOE_PATCHES.md) | 第三方或捆绑/生成内容 | 保留来源、许可与生成流程，不批量改写 |
| [FloeAgent/ThirdParty/WasmKit/Sources/WAT/Docs.docc/Docs.md](../FloeAgent/ThirdParty/WasmKit/Sources/WAT/Docs.docc/Docs.md) | 第三方或捆绑/生成内容 | 保留来源、许可与生成流程，不批量改写 |
| [FloeAgent/ThirdParty/WasmKit/Sources/WasmKit/Docs.docc/Docs.md](../FloeAgent/ThirdParty/WasmKit/Sources/WasmKit/Docs.docc/Docs.md) | 第三方或捆绑/生成内容 | 保留来源、许可与生成流程，不批量改写 |
| [FloeAgent/ThirdParty/WasmKit/Sources/WasmParser/Docs.docc/Docs.md](../FloeAgent/ThirdParty/WasmKit/Sources/WasmParser/Docs.docc/Docs.md) | 第三方或捆绑/生成内容 | 保留来源、许可与生成流程，不批量改写 |
| [FloeAgent/scripts/fixtures/OFFICE_NATIVE_PROBE.md](../FloeAgent/scripts/fixtures/OFFICE_NATIVE_PROBE.md) | 专题说明/既有计划 | 保留专题范围；1.7 进展以实施状态为准，后续随对应代码更新 |
| [FloeAgent/ThirdParty/NativeRuntimeArchive/recipes/pandas-runtime-release.md](../FloeAgent/ThirdParty/NativeRuntimeArchive/recipes/pandas-runtime-release.md) | 历史归档/既有计划 | 原生 pandas 配方已随 Phase 2 退役并移入 NativeRuntimeArchive，仅作历史记录 |
| [PRODUCT.md](../PRODUCT.md) | 当前 1.7 说明 | 本轮更新或引用当前实施状态 |
| [README.md](../README.md) | 当前 1.7 说明 | 本轮更新或引用当前实施状态 |
| [README.zh-CN.md](../README.zh-CN.md) | 当前 1.7 说明 | 本轮更新或引用当前实施状态 |
| [SECURITY.md](../SECURITY.md) | 当前 1.7 说明 | 本轮更新或引用当前实施状态 |
| [SECURITY.zh-CN.md](../SECURITY.zh-CN.md) | 当前 1.7 说明 | 本轮更新或引用当前实施状态 |
| [SUPPORT.md](../SUPPORT.md) | 当前 1.7 说明 | 本轮更新或引用当前实施状态 |
| [SUPPORT.zh-CN.md](../SUPPORT.zh-CN.md) | 当前 1.7 说明 | 本轮更新或引用当前实施状态 |
| [docs/ARCHITECTURE_LOCAL_SHELL.md](ARCHITECTURE_LOCAL_SHELL.md) | 当前 1.7 说明 | 本轮更新或引用当前实施状态 |
| [docs/ARCHITECTURE_OVERVIEW.md](ARCHITECTURE_OVERVIEW.md) | 当前 1.7 说明 | 本轮更新或引用当前实施状态 |
| [docs/CREATIVE_MODE_AND_ASSET_ARCHITECTURE.md](CREATIVE_MODE_AND_ASSET_ARCHITECTURE.md) | 专题说明/既有计划 | 保留专题范围；1.7 进展以实施状态为准，后续随对应代码更新 |
| [docs/CREATIVE_MODE_AND_ASSET_ARCHITECTURE.zh-CN.md](CREATIVE_MODE_AND_ASSET_ARCHITECTURE.zh-CN.md) | 专题说明/既有计划 | 保留专题范围；1.7 进展以实施状态为准，后续随对应代码更新 |
| [docs/FLOE_1_7_BUILD_AND_ACCEPTANCE.md](FLOE_1_7_BUILD_AND_ACCEPTANCE.md) | 当前 1.7 说明 | 本轮更新或引用当前实施状态 |
| [docs/FLOE_1_7_COMPATIBILITY.md](FLOE_1_7_COMPATIBILITY.md) | 当前 1.7 说明 | 本轮更新或引用当前实施状态 |
| [docs/FLOE_1_7_IMPLEMENTATION_STATUS.md](FLOE_1_7_IMPLEMENTATION_STATUS.md) | 当前 1.7 说明 | 本轮更新或引用当前实施状态 |
| [docs/FLOE_1_7_MIGRATION.md](FLOE_1_7_MIGRATION.md) | 当前 1.7 说明 | 本轮更新或引用当前实施状态 |
| [docs/FLOE_1_7_NODE_RUNTIME.md](FLOE_1_7_NODE_RUNTIME.md) | 当前 1.7 说明 | 本轮更新或引用当前实施状态 |
| [docs/FLOE_BROWSER_PROTOCOL.md](FLOE_BROWSER_PROTOCOL.md) | 专题说明/既有计划 | 保留专题范围；1.7 进展以实施状态为准，后续随对应代码更新 |
| [docs/HARNESS_TIER3_DESIGN.md](HARNESS_TIER3_DESIGN.md) | 专题说明/既有计划 | 保留专题范围；1.7 进展以实施状态为准，后续随对应代码更新 |
| [docs/IMPLEMENTATION_1.5.0.md](IMPLEMENTATION_1.5.0.md) | 历史发布/验证记录 | 保留日期与原始结论，不充当 1.7 验收 |
| [docs/INTERNAL_PROMPT_AUDIT.md](INTERNAL_PROMPT_AUDIT.md) | 历史发布/验证记录 | 保留日期与原始结论，不充当 1.7 验收 |
| [docs/LOCAL_SHELL_IMPLEMENTATION_2026-09-12.md](LOCAL_SHELL_IMPLEMENTATION_2026-09-12.md) | 专题说明/既有计划 | 保留专题范围；1.7 进展以实施状态为准，后续随对应代码更新 |
| [docs/MAIL_CONNECTOR.md](MAIL_CONNECTOR.md) | 专题说明/既有计划 | 保留专题范围；1.7 进展以实施状态为准，后续随对应代码更新 |
| [docs/MEDIA_MODEL_CATALOG_2026-09-08.md](MEDIA_MODEL_CATALOG_2026-09-08.md) | 专题说明/既有计划 | 保留专题范围；1.7 进展以实施状态为准，后续随对应代码更新 |
| [docs/OFFICE_FRONTEND_ACCEPTANCE.md](OFFICE_FRONTEND_ACCEPTANCE.md) | 专题说明/既有计划 | 保留专题范围；1.7 进展以实施状态为准，后续随对应代码更新 |
| [docs/OFFICE_SCREENSHOT_INDEX.md](OFFICE_SCREENSHOT_INDEX.md) | 专题说明/既有计划 | 保留专题范围；1.7 进展以实施状态为准，后续随对应代码更新 |
| [docs/PDF_SKILL_HUB_IMPLEMENTATION.md](PDF_SKILL_HUB_IMPLEMENTATION.md) | 专题说明/既有计划 | 保留专题范围；1.7 进展以实施状态为准，后续随对应代码更新 |
| [docs/PLAN_LOCAL_SHELL.md](PLAN_LOCAL_SHELL.md) | 专题说明/既有计划 | 保留专题范围；1.7 进展以实施状态为准，后续随对应代码更新 |
| [docs/README.md](README.md) | 当前 1.7 说明 | 本轮更新或引用当前实施状态 |
| [docs/RELEASE_CODE_AUDIT_20260909.md](RELEASE_CODE_AUDIT_20260909.md) | 历史发布/验证记录 | 保留日期与原始结论，不充当 1.7 验收 |
| [docs/RELEASE_NOTES_1.4.87.md](RELEASE_NOTES_1.4.87.md) | 历史发布/验证记录 | 保留日期与原始结论，不充当 1.7 验收 |
| [docs/RELEASE_NOTES_1.4.88.md](RELEASE_NOTES_1.4.88.md) | 历史发布/验证记录 | 保留日期与原始结论，不充当 1.7 验收 |
| [docs/RELEASE_NOTES_1.4.89.md](RELEASE_NOTES_1.4.89.md) | 历史发布/验证记录 | 保留日期与原始结论，不充当 1.7 验收 |
| [docs/RELEASE_NOTES_1.4.90.md](RELEASE_NOTES_1.4.90.md) | 历史发布/验证记录 | 保留日期与原始结论，不充当 1.7 验收 |
| [docs/RELEASE_NOTES_1.4.91.md](RELEASE_NOTES_1.4.91.md) | 历史发布/验证记录 | 保留日期与原始结论，不充当 1.7 验收 |
| [docs/RELEASE_NOTES_1.4.92.md](RELEASE_NOTES_1.4.92.md) | 历史发布/验证记录 | 保留日期与原始结论，不充当 1.7 验收 |
| [docs/RELEASE_NOTES_1.4.93.md](RELEASE_NOTES_1.4.93.md) | 历史发布/验证记录 | 保留日期与原始结论，不充当 1.7 验收 |
| [docs/RELEASE_NOTES_1.4.94.md](RELEASE_NOTES_1.4.94.md) | 历史发布/验证记录 | 保留日期与原始结论，不充当 1.7 验收 |
| [docs/RELEASE_NOTES_1.4.95.md](RELEASE_NOTES_1.4.95.md) | 历史发布/验证记录 | 保留日期与原始结论，不充当 1.7 验收 |
| [docs/RELEASE_NOTES_1.4.96.md](RELEASE_NOTES_1.4.96.md) | 历史发布/验证记录 | 保留日期与原始结论，不充当 1.7 验收 |
| [docs/RELEASE_NOTES_1.4.97.md](RELEASE_NOTES_1.4.97.md) | 历史发布/验证记录 | 保留日期与原始结论，不充当 1.7 验收 |
| [docs/RELEASE_NOTES_1.4.98.md](RELEASE_NOTES_1.4.98.md) | 历史发布/验证记录 | 保留日期与原始结论，不充当 1.7 验收 |
| [docs/RELEASE_NOTES_1.4.99.md](RELEASE_NOTES_1.4.99.md) | 历史发布/验证记录 | 保留日期与原始结论，不充当 1.7 验收 |
| [docs/RELEASE_NOTES_1.5.0.md](RELEASE_NOTES_1.5.0.md) | 历史发布/验证记录 | 保留日期与原始结论，不充当 1.7 验收 |
| [docs/RELEASE_NOTES_1.5.1.md](RELEASE_NOTES_1.5.1.md) | 历史发布/验证记录 | 保留日期与原始结论，不充当 1.7 验收 |
| [docs/RELEASE_NOTES_1.5.2.md](RELEASE_NOTES_1.5.2.md) | 历史发布/验证记录 | 保留日期与原始结论，不充当 1.7 验收 |
| [docs/RELEASE_NOTES_1.5.3.md](RELEASE_NOTES_1.5.3.md) | 历史发布/验证记录 | 保留日期与原始结论，不充当 1.7 验收 |
| [docs/RELEASE_NOTES_1.6.0.md](RELEASE_NOTES_1.6.0.md) | 历史发布/验证记录 | 保留日期与原始结论，不充当 1.7 验收 |
| [docs/RELEASE_NOTES_1.6.1.md](RELEASE_NOTES_1.6.1.md) | 历史发布/验证记录 | 保留日期与原始结论，不充当 1.7 验收 |
| [docs/RELEASE_NOTES_1.6.2.md](RELEASE_NOTES_1.6.2.md) | 历史发布/验证记录 | 保留日期与原始结论，不充当 1.7 验收 |
| [docs/RELEASE_NOTES_1.6.3.md](RELEASE_NOTES_1.6.3.md) | 历史发布/验证记录 | 保留日期与原始结论，不充当 1.7 验收 |
| [docs/RELEASE_NOTES_1.6.4.md](RELEASE_NOTES_1.6.4.md) | 历史发布/验证记录 | 保留日期与原始结论，不充当 1.7 验收 |
| [docs/RELEASE_NOTES_1.6.5.md](RELEASE_NOTES_1.6.5.md) | 历史发布/验证记录 | 保留日期与原始结论，不充当 1.7 验收 |
| [docs/RELEASE_NOTES_1.6.6.md](RELEASE_NOTES_1.6.6.md) | 历史发布/验证记录 | 保留日期与原始结论，不充当 1.7 验收 |
| [docs/RELEASE_NOTES_1.6.7.md](RELEASE_NOTES_1.6.7.md) | 历史发布/验证记录 | 保留日期与原始结论，不充当 1.7 验收 |
| [docs/RELEASE_VERIFICATION_1.5.2.md](RELEASE_VERIFICATION_1.5.2.md) | 历史发布/验证记录 | 保留日期与原始结论，不充当 1.7 验收 |
| [docs/RELEASE_VERIFICATION_1.5.3.md](RELEASE_VERIFICATION_1.5.3.md) | 历史发布/验证记录 | 保留日期与原始结论，不充当 1.7 验收 |
| [docs/RELEASE_VERIFICATION_1.6.0.md](RELEASE_VERIFICATION_1.6.0.md) | 历史发布/验证记录 | 保留日期与原始结论，不充当 1.7 验收 |
| [docs/RELEASE_VERIFICATION_1.6.1.md](RELEASE_VERIFICATION_1.6.1.md) | 历史发布/验证记录 | 保留日期与原始结论，不充当 1.7 验收 |
| [docs/RELEASE_VERIFICATION_1.6.2.md](RELEASE_VERIFICATION_1.6.2.md) | 历史发布/验证记录 | 保留日期与原始结论，不充当 1.7 验收 |
| [docs/RELEASE_VERIFICATION_1.6.3.md](RELEASE_VERIFICATION_1.6.3.md) | 历史发布/验证记录 | 保留日期与原始结论，不充当 1.7 验收 |
| [docs/RELEASE_VERIFICATION_1.6.4.md](RELEASE_VERIFICATION_1.6.4.md) | 历史发布/验证记录 | 保留日期与原始结论，不充当 1.7 验收 |
| [docs/RELEASE_VERIFICATION_1.6.6.md](RELEASE_VERIFICATION_1.6.6.md) | 历史发布/验证记录 | 保留日期与原始结论，不充当 1.7 验收 |
| [docs/SKILL_ROUTING_UPGRADE_WORK.md](SKILL_ROUTING_UPGRADE_WORK.md) | 专题说明/既有计划 | 保留专题范围；1.7 进展以实施状态为准，后续随对应代码更新 |
| [docs/STABILITY_1.4.88.md](STABILITY_1.4.88.md) | 历史发布/验证记录 | 保留日期与原始结论，不充当 1.7 验收 |
| [docs/TESTFLIGHT_1.4.24.md](TESTFLIGHT_1.4.24.md) | 历史发布/验证记录 | 保留日期与原始结论，不充当 1.7 验收 |
| [docs/TESTFLIGHT_1.4.25.md](TESTFLIGHT_1.4.25.md) | 历史发布/验证记录 | 保留日期与原始结论，不充当 1.7 验收 |
| [docs/TESTFLIGHT_1.4.26.md](TESTFLIGHT_1.4.26.md) | 历史发布/验证记录 | 保留日期与原始结论，不充当 1.7 验收 |
| [docs/TESTFLIGHT_1.4.27.md](TESTFLIGHT_1.4.27.md) | 历史发布/验证记录 | 保留日期与原始结论，不充当 1.7 验收 |
| [docs/TESTFLIGHT_1.4.28.md](TESTFLIGHT_1.4.28.md) | 历史发布/验证记录 | 保留日期与原始结论，不充当 1.7 验收 |
| [docs/TESTFLIGHT_1.4.29.md](TESTFLIGHT_1.4.29.md) | 历史发布/验证记录 | 保留日期与原始结论，不充当 1.7 验收 |
| [docs/TESTFLIGHT_1.4.30.md](TESTFLIGHT_1.4.30.md) | 历史发布/验证记录 | 保留日期与原始结论，不充当 1.7 验收 |
| [docs/TESTFLIGHT_1.4.31.md](TESTFLIGHT_1.4.31.md) | 历史发布/验证记录 | 保留日期与原始结论，不充当 1.7 验收 |
| [docs/TESTFLIGHT_1.4.32.md](TESTFLIGHT_1.4.32.md) | 历史发布/验证记录 | 保留日期与原始结论，不充当 1.7 验收 |
| [docs/TESTFLIGHT_1.4.33.md](TESTFLIGHT_1.4.33.md) | 历史发布/验证记录 | 保留日期与原始结论，不充当 1.7 验收 |
| [docs/TESTFLIGHT_1.4.41.md](TESTFLIGHT_1.4.41.md) | 历史发布/验证记录 | 保留日期与原始结论，不充当 1.7 验收 |
| [docs/TESTFLIGHT_1.4.42.md](TESTFLIGHT_1.4.42.md) | 历史发布/验证记录 | 保留日期与原始结论，不充当 1.7 验收 |
| [docs/TESTFLIGHT_1.4.45.md](TESTFLIGHT_1.4.45.md) | 历史发布/验证记录 | 保留日期与原始结论，不充当 1.7 验收 |
| [docs/TESTFLIGHT_1.4.46.md](TESTFLIGHT_1.4.46.md) | 历史发布/验证记录 | 保留日期与原始结论，不充当 1.7 验收 |
| [docs/TESTFLIGHT_1.4.47.md](TESTFLIGHT_1.4.47.md) | 历史发布/验证记录 | 保留日期与原始结论，不充当 1.7 验收 |
| [docs/TESTFLIGHT_1.4.49.md](TESTFLIGHT_1.4.49.md) | 历史发布/验证记录 | 保留日期与原始结论，不充当 1.7 验收 |
| [docs/TESTFLIGHT_1.4.50.md](TESTFLIGHT_1.4.50.md) | 历史发布/验证记录 | 保留日期与原始结论，不充当 1.7 验收 |
| [docs/TESTFLIGHT_1.4.73.md](TESTFLIGHT_1.4.73.md) | 历史发布/验证记录 | 保留日期与原始结论，不充当 1.7 验收 |
| [docs/TESTFLIGHT_1.4.74.md](TESTFLIGHT_1.4.74.md) | 历史发布/验证记录 | 保留日期与原始结论，不充当 1.7 验收 |
| [docs/TESTFLIGHT_1.4.75.md](TESTFLIGHT_1.4.75.md) | 历史发布/验证记录 | 保留日期与原始结论，不充当 1.7 验收 |
| [docs/TESTFLIGHT_1.4.76.md](TESTFLIGHT_1.4.76.md) | 历史发布/验证记录 | 保留日期与原始结论，不充当 1.7 验收 |
| [docs/TESTFLIGHT_1.4.77.md](TESTFLIGHT_1.4.77.md) | 历史发布/验证记录 | 保留日期与原始结论，不充当 1.7 验收 |
| [docs/TESTFLIGHT_1.4.78.md](TESTFLIGHT_1.4.78.md) | 历史发布/验证记录 | 保留日期与原始结论，不充当 1.7 验收 |
| [docs/TESTFLIGHT_1.4.79.md](TESTFLIGHT_1.4.79.md) | 历史发布/验证记录 | 保留日期与原始结论，不充当 1.7 验收 |
| [docs/TESTFLIGHT_1.4.80.md](TESTFLIGHT_1.4.80.md) | 历史发布/验证记录 | 保留日期与原始结论，不充当 1.7 验收 |
| [docs/TESTFLIGHT_1.4.81.md](TESTFLIGHT_1.4.81.md) | 历史发布/验证记录 | 保留日期与原始结论，不充当 1.7 验收 |
| [docs/TESTFLIGHT_1.4.82.md](TESTFLIGHT_1.4.82.md) | 历史发布/验证记录 | 保留日期与原始结论，不充当 1.7 验收 |
| [docs/TESTFLIGHT_1.4.83.md](TESTFLIGHT_1.4.83.md) | 历史发布/验证记录 | 保留日期与原始结论，不充当 1.7 验收 |
| [docs/TESTFLIGHT_1.4.84.md](TESTFLIGHT_1.4.84.md) | 历史发布/验证记录 | 保留日期与原始结论，不充当 1.7 验收 |
| [docs/TESTFLIGHT_1.4.85.md](TESTFLIGHT_1.4.85.md) | 历史发布/验证记录 | 保留日期与原始结论，不充当 1.7 验收 |
| [docs/TESTFLIGHT_1.4.86.md](TESTFLIGHT_1.4.86.md) | 历史发布/验证记录 | 保留日期与原始结论，不充当 1.7 验收 |
| [docs/TESTFLIGHT_1.4.87.md](TESTFLIGHT_1.4.87.md) | 历史发布/验证记录 | 保留日期与原始结论，不充当 1.7 验收 |
| [docs/TESTFLIGHT_1.4.88.md](TESTFLIGHT_1.4.88.md) | 历史发布/验证记录 | 保留日期与原始结论，不充当 1.7 验收 |
| [docs/TOOL_CLOSURE_IMPLEMENTATION.md](TOOL_CLOSURE_IMPLEMENTATION.md) | 专题说明/既有计划 | 保留专题范围；1.7 进展以实施状态为准，后续随对应代码更新 |
| [docs/USER_GUIDE.md](USER_GUIDE.md) | 当前 1.7 说明 | 本轮更新或引用当前实施状态 |
| [docs/USER_GUIDE.zh-CN.md](USER_GUIDE.zh-CN.md) | 当前 1.7 说明 | 本轮更新或引用当前实施状态 |
| [docs/WORKFLOW_UPGRADE.md](WORKFLOW_UPGRADE.md) | 专题说明/既有计划 | 保留专题范围；1.7 进展以实施状态为准，后续随对应代码更新 |
| [docs/WORKFLOW_UPGRADE_IMPLEMENTATION.md](WORKFLOW_UPGRADE_IMPLEMENTATION.md) | 专题说明/既有计划 | 保留专题范围；1.7 进展以实施状态为准，后续随对应代码更新 |
| [docs/evidence/workflow-upgrade-20260909/README.md](evidence/workflow-upgrade-20260909/README.md) | 历史发布/验证记录 | 保留日期与原始结论，不充当 1.7 验收 |
| [ios-wheelhouse/](../ios-wheelhouse/) | 历史归档 | 已退役的 iOS wheel 产线目录（仅有旧产物），不接入构建，无 README |
| [skill-hub/README.md](../skill-hub/README.md) | 当前 1.7 说明 | 本轮更新或引用当前实施状态 |
| [skill-hub/sources/floe-network/SKILL.md](../skill-hub/sources/floe-network/SKILL.md) | 可发布 Skill | 既有技能说明保留；行为变化时同步版本与签名 |
| [skill-hub/sources/floe-office/SKILL.md](../skill-hub/sources/floe-office/SKILL.md) | 可发布 Skill | 既有技能说明保留；行为变化时同步版本与签名 |
| [skill-hub/sources/floe-pdf/SKILL.md](../skill-hub/sources/floe-pdf/SKILL.md) | 可发布 Skill | 既有技能说明保留；行为变化时同步版本与签名 |
| [skill-hub/sources/floe-video/SKILL.md](../skill-hub/sources/floe-video/SKILL.md) | 可发布 Skill | 1.0.1 已校正能力描述，云端签名与本地验证通过 |

## 2026-09-13 界面与分发记录核对

补充通用里的日夜主题、项目/会话容器管理、思考与工具组交互说明及合成样本截图。工程验收和迁移说明同步记录 49 项模块测试、两项原生界面测试的边界。文档索引中六个指向未纳入版本控制的本地资料链接改为明确的本地资料标记，不把这些旧规划误当成可访问的仓库文档。

TestFlight beta.4 固定在 `2cd030c2121ef48214da312ad310c74ae1c72324`，版本 1.7.0 / build 147；云端工作流 [34711460906](https://github.com/JiangNanGenius/floe-agent/actions/runs/34711460906) 已启动，尚未获得上传或 Apple 处理完成结果。后续文档提交不会移动这个标签。

后续结果：beta.4 在 Swift 回归阶段取消，未进入上传。完整日志确认 SVG 只读检查规则回归，以及执行模块测试停止输出；修复后的 83 项权限测试和 147 项执行测试在定向宿主入口通过。build 148 / beta.5 候选加入停滞采样与测试日志保留，云端全套回归仍需重新验证，不能把本地未复现写成云端阻塞已修复。

## Build 156 描述核对

本轮对 20 份当前介绍、指南与 1.7 文档的 275 个相对文件链接检查通过，无缺失目标。SDK 27 与上传 Xcode 26.6 / SDK 26.5 的边界、用户负责真机检查、Apple 打包失败与恢复分别记录；成功分发后再更新首页和版本状态。历史截图保留原提交与设备标签，失败记录不改写。

最终交付同步：双语首页和使用指南、工程 README、文档索引、实施状态、交接、变更草稿、版本说明、TestFlight 记录及证据均更新到 build 156 的真实内部可安装状态。旧失败记录、组件截图标签和尚未完成的包/模型边界保留。

最终分发前，22 份当前文档的 337 个相对文件链接检查通过。内部可安装状态确认后完成 main 合并和四个已合并分支的清理，记录随文档保留。
