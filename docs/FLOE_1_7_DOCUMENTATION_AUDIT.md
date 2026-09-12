# Floe 1.7 文档维护清单

本轮刷新介绍、双语 README/使用指南、产品、总体架构、shell 边界、工程构建、贡献、支持、安全、技能中心和 wheelhouse 说明；新增构建验收、迁移恢复和兼容性入口。此清单是维护范围登记，不表示所有历史文档中的技术事实已重新验证。

当前版本状态统一引用 [实施状态](FLOE_1_7_IMPLEMENTATION_STATUS.md)。历史发布与证据不可回写成新版本成功结果；第三方许可/来源及签名生成产物保留各自流程。旧专题在对应功能变化时更新正文，不用统一日期掩盖内容年龄。

本地忽略的 `DESIGN.md` 和 `docs/DEVELOPMENT_PLAN.md` 已补充 1.7 方向，但仍遵循仓库原有忽略规则，不强行纳入提交。网站在线内容不由这些 Markdown 自动证明已部署。签名 floe-video 的更新还须同步版本、简短变更说明及签名，属于后续功能接通工作。

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
| [FloeAgent/scripts/pandas-runtime-release.md](../FloeAgent/scripts/pandas-runtime-release.md) | 专题说明/既有计划 | 保留专题范围；1.7 进展以实施状态为准，后续随对应代码更新 |
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
| [ios-wheelhouse/README.md](../ios-wheelhouse/README.md) | 当前 1.7 说明 | 本轮更新或引用当前实施状态 |
| [skill-hub/README.md](../skill-hub/README.md) | 当前 1.7 说明 | 本轮更新或引用当前实施状态 |
| [skill-hub/sources/floe-network/SKILL.md](../skill-hub/sources/floe-network/SKILL.md) | 可发布 Skill | 既有技能说明保留；行为变化时同步版本与签名 |
| [skill-hub/sources/floe-office/SKILL.md](../skill-hub/sources/floe-office/SKILL.md) | 可发布 Skill | 既有技能说明保留；行为变化时同步版本与签名 |
| [skill-hub/sources/floe-pdf/SKILL.md](../skill-hub/sources/floe-pdf/SKILL.md) | 可发布 Skill | 既有技能说明保留；行为变化时同步版本与签名 |
| [skill-hub/sources/floe-video/SKILL.md](../skill-hub/sources/floe-video/SKILL.md) | 可发布 Skill | 版本/签名流程维护；floe-video 能力描述仍待专项校正 |
