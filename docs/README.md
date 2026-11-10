# Floe Agent 文档索引 / Documentation Index

按用途选择入口。安装版本集中记录在 [CURRENT_STATUS](CURRENT_STATUS.md)；计划、源码和已交付能力分别阅读。 / Choose an entry by purpose. Channel snapshots live in CURRENT_STATUS; plans, source and shipped capabilities have separate evidence.

<a id="任务式快速开始--guided-quickstart"></a>
## 使用手册 / User manuals

[从安装到第一个成果](QUICKSTART.zh-CN.md) · [English quickstart](QUICKSTART.md) · [中文图文手册](USER_GUIDE.zh-CN.md) · [English illustrated manual](USER_GUIDE.md) · [官网中文](https://www.floe-agent.com/docs/zh.html) · [Website English](https://www.floe-agent.com/docs/en.html)

| 阅读主题 / Topic | 简体中文 | English |
| --- | --- | --- |
| 安装与模型 / Install & models | [阅读](USER_GUIDE.zh-CN.md#1-安装与首次使用) | [Read](USER_GUIDE.md#1-installation-and-first-use) |
| 任务与文件 / Tasks & files | [阅读](USER_GUIDE.zh-CN.md#3-新建任务与选择工作区) | [Read](USER_GUIDE.md#3-tasks-and-workspace-ownership) |
| 手记与阅读 / Notes & reading | [阅读](USER_GUIDE.zh-CN.md#7-手记导入搜索与书写) | [Read](USER_GUIDE.md#7-notes-import-search-and-handwriting) |
| Office | [阅读](USER_GUIDE.zh-CN.md#8-office编辑批注保存和重新打开) | [Read](USER_GUIDE.md#8-office-edit-annotate-save-and-reopen) |
| 空间与专用工作台 / Space & workbenches | [阅读](WORKSPACES_GUIDE.zh-CN.md) | [Read](WORKSPACES_GUIDE.md) |
| 画布与媒体 / Canvas & media | [阅读](USER_GUIDE.zh-CN.md#15-画布图像音视频) | [Read](USER_GUIDE.md#15-canvas-images-audio-and-video) |
| 图纸与 3D / Drawings & 3D | [阅读](USER_GUIDE.zh-CN.md#14-工程图纸与图纸助手) | [Read](USER_GUIDE.md#14-engineering-drawings-and-ai-review) |
| 开发与连接 / Code & connections | [阅读](USER_GUIDE.zh-CN.md#9-本地终端与-linux-性能配置) | [Read](USER_GUIDE.md#9-local-terminal-and-linux-performance) |
| 常见问题 / Troubleshooting | [阅读](USER_GUIDE.zh-CN.md#20-常见问题与排查顺序) | [Read](USER_GUIDE.md#20-troubleshooting) |

## 安装与帮助 / Installation & help

[渠道版本与核实日期 / Channel snapshots](CURRENT_STATUS.md) · [Feather / AltStore](FEATHER_SOURCE.md) · [支持 / Support](../SUPPORT.zh-CN.md) / [English](../SUPPORT.md) · [安全 / Security](../SECURITY.zh-CN.md) / [English](../SECURITY.md)

<a id="开发与档案--engineering--archives"></a>
<a id="当前有效阅读与维护入口"></a>
## 工程入口 / Engineering entry points

| 用途 / Purpose | 入口 / Entry |
| --- | --- |
| 仓库工作约定 / Repository instructions | [AGENTS.md](../AGENTS.md) |
| 贡献与构建 / Contributing & building | [贡献指南](../CONTRIBUTING.zh-CN.md) / [English](../CONTRIBUTING.md) · [工程指南](../FloeAgent/README.md) |
| 本地验证与补充 CI / Local qualification & supplementary CI | [中文](FLOE_LOCAL_QUALIFICATION.zh-CN.md) / [English](FLOE_LOCAL_QUALIFICATION.md) · [构建与验收](FLOE_1_7_BUILD_AND_ACCEPTANCE.md) |
| 架构与运行环境 / Architecture & runtime | [总体架构](ARCHITECTURE_OVERVIEW.md) · [共享 ARM64 Linux 与执行入口](ARCHITECTURE_LOCAL_SHELL.md) |
| 浏览器、并发与储存 / Browser, concurrency & storage | [浏览器协议](FLOE_BROWSER_PROTOCOL.md) · [并发编辑](FLOE_CONCURRENT_EDITING.md) · [储存诊断](FLOE_STORAGE_DIAGNOSTICS.zh-CN.md) / [English](FLOE_STORAGE_DIAGNOSTICS.md) |
| Skill 与内容 / Skills & content | [依赖作者规范](skills/SKILL_DEPENDENCIES_AUTHOR_GUIDE.zh-CN.md) / [English](skills/SKILL_DEPENDENCIES_AUTHOR_GUIDE.md) · [Schema](skills/dependencies.schema.json) · [示例](skills/examples/README.md) · [Skill Hub](../skill-hub/README.md) · [内容更新](FLOE_CONTENT_UPDATE_UPGRADE.md) |
| Android | [工程说明](../FloeAndroid/README.md) · [实施计划](FLOE_ANDROID_IMPLEMENTATION_PLAN.zh-CN.md) · [进展](FLOE_ANDROID_PROGRESS.zh-CN.md) · [iOS 增量对齐](FLOE_ANDROID_IOS_DELTA_AUDIT.zh-CN.md) |
| 配套 Bridge / Companion bridges | [Mac Bridge](FLOE_MAC_BRIDGE.md) · [iOS Bridge](../FloeIOSBridge/README.zh-CN.md) / [English](../FloeIOSBridge/README.md) |

版本和构建号以 [`project.yml`](../FloeAgent/project.yml) 为准，数据库版本以 [`DatabaseManager.currentSchemaVersion`](../FloeAgent/Sources/FloePersistence/DatabaseManager.swift) 为准。工程文档说明源码路径；安装包包含哪些能力，仍需核对该版发布说明。 / Source metadata comes from the project and migration code. Source documentation alone does not establish what a released package contains.

<a id="实施跟踪当前里程碑"></a>
## 在研计划与接入记录 / Plans & integration records

这些文档保留原需求编号、负责人交接与阶段证据。完成状态以各条实际记录为准；“预研完成”“组件通过”和“App 已交付”分别核对。 / These records retain requirement identities and staged evidence. Research, component qualification and App delivery are separate states.

| 范围 / Scope | 跟踪入口 / Tracking entry |
| --- | --- |
| App 接入与本轮修整 / App integration & usability | [预研接入](FLOE_PREDEVELOPMENT_APP_INTEGRATION.zh-CN.md) · [引擎与可用性计划](FLOE_NEXT_ROUND_ENGINES_AND_USABILITY_PLAN.zh-CN.md) · [需求问答](FLOE_NEXT_ROUND_REQUIREMENTS_QA_20261109.zh-CN.md) |
| 3D、物理与仿真 / 3D, physics & simulation | [CAD 实施进展](FLOE_CAD_3D_IMPLEMENTATION_PROGRESS.zh-CN.md) · [物理与 CAE 计划](FLOE_3D_PHYSICS_CAE_ANIMATION_PREDEVELOPMENT_PLAN.zh-CN.md) · [实施状态](FLOE_3D_SIMULATION_IMPLEMENTATION_STATUS.zh-CN.md) |
| 专用编辑器 / Specialist editors | [GIS／制谱／字体](FLOE_GIS_SCORE_FONT_PREDEVELOPMENT.zh-CN.md) · [LaTeX](FLOE_LATEX_PREDEVELOPMENT_PLAN.zh-CN.md) · [PCB](FLOE_PCB_EDITOR_IMPLEMENTATION_PLAN.zh-CN.md) · [引擎缺口](FLOE_NATIVE_ENGINE_GAPS.zh-CN.md) / [English](FLOE_NATIVE_ENGINE_GAPS.md) |
| 科学与工具箱 / Science & toolbox | [生物学](FLOE_BIOLOGY_PREDEVELOPMENT_QA_PLAN.zh-CN.md) · [化学](FLOE_CHEMISTRY_PREDEVELOPMENT_QA_PLAN.zh-CN.md) · [工具箱](FLOE_TOOLBOX_PREDEVELOPMENT_QA_PLAN.zh-CN.md) |
| 运行框架设计 / Runtime design reference | [Harness Tier-3 设计](HARNESS_TIER3_DESIGN.md)：设计稿的日期不等于需求已失效，实现与交付另行核对。 / A dated design does not establish retirement, implementation or delivery. |

专题技术参考：[CAD 与图纸助手](FLOE_CAD_AND_DRAWING_ASSISTANT.md)、[媒体工作台](FLOE_MEDIA_WORKBENCH.md)、[设计流程](FLOE_DESIGN_WORKFLOW.zh-CN.md) / [English](FLOE_DESIGN_WORKFLOW.md)、[端口管理](FLOE_PORT_MANAGEMENT.md)、[快捷指令模板](FLOE_SHORTCUT_SCHEDULE_TEMPLATE.md)、[邮件连接器](MAIL_CONNECTOR.md)。各文档中的日期、适用版本及限制仍然有效。 / Topic references retain their stated dates, versions and limits.

<a id="发布档案只追加不回改"></a>
<a id="历史研究结论以现行代码为准"></a>
## 历史与证据 / History & evidence

- [历史文档索引 / Historical documents](history/README.md)：旧实施状态、退役运行时、旧工作流与原始手册；保留原路径及引用。
- [发布档案 / Release archive](releases/README.md)：逐版说明、TestFlight 文案、交付和失败记录。
- [组件与 App 资格记录 / Qualification](qualification/) · [原始证据 / Evidence](evidence/) · [验证附件 / Validation](validation/) · [公测资料 / Beta materials](public-beta/)：按对应源码、目标和日期读取。

<a id="写作约定"></a>
## 维护方式 / Maintenance

| 文档性质 / Kind | 处理方式 / Treatment |
| --- | --- |
| 现行指南 / Maintained guide | 行为或构建路径变化时更新正文；用户指引同步中英。 / Update with behavior or build changes; keep user guidance bilingual. |
| 在研计划 / Active plan | 保留原需求编号，追加实际进展及证据，不因计划日期较早就归档。 / Preserve requirement identities and add verified progress; age alone is not retirement. |
| 历史参考 / Historical reference | 顶部标明适用范围与替代入口，从历史索引访问；原路径保留。 / Mark scope and successor at the top; retain paths. |
| 发布与验收证据 / Release & acceptance evidence | 保留原始结果和失败；后续结果另记，不将旧候选改成已通过。 / Preserve original outcomes and failures; record later evidence separately. |

渠道版本只在 CURRENT_STATUS 维护；其他入口引用它。日期表示文档核对或证据发生时间，不等于新一轮验收。迁移或删除文件前，先检查 Markdown、脚本、工作流及网站引用；第三方文档和许可随其上游保持。 / Maintain channel snapshots in one place. A documentation date is not fresh product acceptance. Check links and automated consumers before moving or deleting files; preserve upstream documentation and licenses.
