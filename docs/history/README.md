# 历史文档索引 / Historical documentation

这里集中指向旧实施快照、退役方案与历史手册。文件保留原路径，便于读取旧引用和核对对应源码；文中的“当前”“本轮”“待完成”均指其记录日期。 / This index groups historical snapshots, retired designs and previous manuals. Existing paths remain valid; “current”, “this round” and open items refer to the recorded source and date.

[现行文档入口 / Documentation hub](../README.md) · [渠道版本快照 / Channel snapshots](../CURRENT_STATUS.md) · [源码架构 / Source architecture](../ARCHITECTURE_OVERVIEW.md) · [发布档案 / Release archive](../releases/README.md)

## 旧实施状态与工作流 / Earlier implementation & workflows

| 历史材料 / Historical material | 现行阅读入口 / Read next |
| --- | --- |
| [1.7 实施状态](../FLOE_1_7_IMPLEMENTATION_STATUS.md)、[下一版状态](../FLOE_1_7_NEXT_RELEASE_STATUS.md)、[继续实施](../FLOE_1_7_CONTINUATION_STATUS.md)、[下一轮交接](../FLOE_1_7_NEXT_ROUND_HANDOFF.md) | [App 接入记录](../FLOE_PREDEVELOPMENT_APP_INTEGRATION.zh-CN.md)、[引擎与可用性计划](../FLOE_NEXT_ROUND_ENGINES_AND_USABILITY_PLAN.zh-CN.md)；交付仍按渠道快照与逐版记录核对。 / Use current integration records; verify delivery separately. |
| [1.7 功能草稿](../FLOE_1_7_CHANGELOG_DRAFT.md)、[原生包补齐计划](../FLOE_1_7_NATIVE_PACKAGE_COMPLETION_PLAN.md)、[旧资格矩阵](../FLOE_1_7_QUALIFICATION_MATRIX.md)、[平台与 Office 范围](../FLOE_1_7_PLATFORM_AND_OFFICE_SCOPE.md) | [使用手册](../USER_GUIDE.zh-CN.md)、[空间教程](../WORKSPACES_GUIDE.zh-CN.md)、[本地验证](../FLOE_LOCAL_QUALIFICATION.zh-CN.md)；旧矩阵不作为所有改动的固定门槛。 / Historical matrices do not impose a fixed suite on every change. |
| [工作流升级](../WORKFLOW_UPGRADE.md)、[完整升级台账](../WORKFLOW_UPGRADE_IMPLEMENTATION.md)、[Office 前端验收](../OFFICE_FRONTEND_ACCEPTANCE.md)、[截图索引](../OFFICE_SCREENSHOT_INDEX.md)、[PDF Skill 实施](../PDF_SKILL_HUB_IMPLEMENTATION.md) | [手记与 Office 手册](../USER_GUIDE.zh-CN.md#8-office编辑批注保存和重新打开)、[发布修复档案](../releases/repairs/)；保留当时未通过的项目。 / Preserve original failures and open items. |
| [1.7.24 创作工具与格式表](../FLOE_1_7_24_CREATIVE_TOOLS.md) | [空间教程](../WORKSPACES_GUIDE.zh-CN.md)、[所选版本说明](../releases/notes/)；旧格式表限于 Build 265。 / The old format matrix applies to build 265. |
| [工具闭环清单](../TOOL_CLOSURE_IMPLEMENTATION.md)、[技能路由升级](../SKILL_ROUTING_UPGRADE_WORK.md)、[2026-09-08 媒体模型目录](../MEDIA_MODEL_CATALOG_2026-09-08.md) | [使用手册](../USER_GUIDE.zh-CN.md)、[Skill 依赖规范](../skills/SKILL_DEPENDENCIES_AUTHOR_GUIDE.zh-CN.md)及当前服务商配置；旧清单不作为当前模型/API 目录。 / Use current guidance and provider configuration; preserve the original checklist states. |
| [accepted-SDK 恢复方案](../ACCEPTED_SDK_RELEASE_RECOVERY.md) | 后续实际运行见 [Build 243 交付](../releases/testflight/TESTFLIGHT_1.7.2_BETA.md)；当前构建见[工程指南](../../FloeAgent/README.md)。 / Later execution and current procedure are separate references. |

## 退役的原生解释器与 TinyEMU / Retired native interpreters & TinyEMU

现行执行路径为共享 ARM64 Linux，经任务所属的 `exec.shell`、作业及服务入口调用。以[执行架构](../ARCHITECTURE_LOCAL_SHELL.md)和[当前源码](../../FloeAgent/Sources/FloeExecution/Linux/ARM64ResidentGuestSessionFactory.swift)为入口。以下文档保留旧实现、协议和证据，不用于恢复旧引擎或重新注册已退役工具。 / Current execution uses shared ARM64 Linux through the task-owned shell, jobs and service lifecycle. The references below retain earlier designs and evidence; they do not authorize restoring retired engines or tools.

| 历史主题 / Historical topic | 原始文件 / Original files |
| --- | --- |
| 进程内解释器与本地 Shell / In-process runtimes & local shell | [NodeMobile](../FLOE_1_7_NODE_RUNTIME.md) · [Shell 计划](../PLAN_LOCAL_SHELL.md) · [早期实现](../LOCAL_SHELL_IMPLEMENTATION_2026-09-12.md) · [旧工具路由](../FLOE_SHELL_TOOL_ROUTES.md) |
| Phase 2 迁移 / Phase 2 migration | [总计划](../FLOE_PHASE2_2026_09_21.md) · [迁移契约](../PHASE2_migration.md) · [adapter](../PHASE2_adapter.md) · [assistant](../PHASE2_assistant.md) · [component](../PHASE2_component.md) · [documents](../PHASE2_documents.md) · [engine](../PHASE2_engine.md) · [git](../PHASE2_git.md) · [upgrade](../PHASE2_upgrade.md) |
| TinyEMU RV64 后端与存储 / TinyEMU RV64 backend & storage | [后端](../FLOE_LINUX_GUEST_BACKEND.md) · [Runtime v2 设计](../TINYEMU_RUNTIME_V2.md) · [控制台扩展](../FLOE_LINUX_GUEST_PROTOCOL_EXTENSIONS.md) |
| 旧镜像、内核与许可 / Earlier images, kernel & licenses | [镜像构建](../FLOE_LINUX_GUEST_IMAGE_BUILD.md) · [来源和许可清单](../FLOE_LINUX_GUEST_IMAGE_MANIFEST.md) · [内核升级](../FLOE_LINUX_KERNEL_UPGRADE.md) · [下载来源研究](../FLOE_LINUX_DOWNLOAD_SOURCES_20260930.md) |

旧镜像与许可清单保留对应发布物的合规和复现用途，不能因为运行时退役而删除。已迁出源码的文件链接固定到迁出前的不可变提交，避免指向主线中已删除的路径。现行依赖以构建清单、锁定文件和随包许可为准。 / Retired-image source and license records remain relevant to those artifacts. Source links pin the immutable pre-removal commit; current dependencies follow current locks and shipped licenses.

## 手册与维护记录 / Manuals & documentation records

- [2026-10-05 之前的英文手册](USER_GUIDE.pre-20261005.md) / [中文手册](USER_GUIDE.zh-CN.pre-20261005.md)。
- [2026-10-09 之前的工程与发布过程](ENGINEERING_RELEASE_CHRONOLOGY.pre-20261009.md)。
- [2026-10-05 文档整理](../DOCUMENTATION_REFRESH_20261005.md)、[2026-10-09 文档与官网核对](../DOCUMENTATION_REFRESH_20261009.md)、[1.7 文档审计](../FLOE_1_7_DOCUMENTATION_AUDIT.md)。这些是完成时的盘点，不是滚动状态。 / These are dated inventories, not rolling status pages.

逐版发布说明、TestFlight、修复与原始资格证据继续保存在[发布档案](../releases/README.md)、[qualification](../qualification/)、[evidence](../evidence/)、[validation](../validation/)和[public-beta](../public-beta/)。在研计划仍从[文档入口](../README.md)访问，不按文件名或日期批量归档。 / Release and qualification evidence retain their existing directories. Active plans stay in the documentation hub and are not retired by filename or age.
