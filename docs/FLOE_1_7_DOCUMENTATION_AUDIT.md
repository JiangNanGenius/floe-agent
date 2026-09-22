# Floe 1.7 文档维护清单

## 2026-09-23 Build 224：Runtime v2 启动修复、本地模型驻留、PPT 编辑入口与 Gitee 回退 / Runtime v2 startup fixes, local-model residency, PPT edit entry and Gitee fallback

Build 224 moves all four shipping targets to 1.7.0 (224); `FloeAgent/project.yml` carries four `CURRENT_PROJECT_VERSION: "224"` entries and the regenerated `FloeAgent.xcodeproj` matches (eight Debug/Release entries), with `Package.resolved` untouched. Bilingual release notes (`RELEASE_NOTES_1.7.0_BUILD_224.md`) and bilingual TestFlight notes (`TESTFLIGHT_1.7_WHATS_NEW_BUILD_224.json`, validated) document the Build 223 startup/migration repair (duplicate `schema_migrations` rollback, idempotent legacy migration, repairRequired fail-closed, accurate install state, expanded-view rebuild), the retained-task local-model idle fix, the PPT edit-entry first-render repair (host re-pinned by CI run 35747909238), and the GitHub-primary/sharded-Gitee fallback with verified resume plus the one-way GitHub→Gitee `gitee-mirror` workflow. Both READMEs gain a Gitee China-mirror section; current-pointer docs (`TESTFLIGHT_1.7.0_BETA.md`, `FLOE_1_7_BUILD_AND_ACCEPTANCE.md`, `FLOE_1_7_IMPLEMENTATION_STATUS.md`, `docs/README.md`) advance from 223/222 to 224 while Build 223/222 records stay retained. Evidence is source-level tests and metadata only; cloud App build/package, Apple processing, TestFlight availability, release publication and physical-device PPT/MLX/PiP/Linux behavior are explicitly not claimed. No private paths, credentials, topology or tokens are recorded.

## 2026-09-22 官网快速添加 HTTPS 端点与 README 徽章 / Official quick-add HTTPS endpoints and README badges

本轮补齐侧载快速添加链路：官网（`Local/Private/official-service`，私有）新增两个固定公网 HTTPS 入口 `https://www.floe-agent.com/add/feather` 与 `https://www.floe-agent.com/add/altstore`。每个入口在设备上先尝试与已验证目标逐字节一致的深链（`feather://source/<stable-source-url>`、`altstore://source?url=<percent-encoded>`，源地址 `https://raw.githubusercontent.com/JiangNanGenius/floe-agent/main/feather.json`），随后始终显示可手动复制的源地址、「打开 App」按钮、下载页与 GitHub 发布链接；未知应用名返回 404，内联启动脚本绑定逐响应 CSP nonce。官网下载页 chooser 的 Feather／AltStore 项改为路由到这两个端点。已通过源站与公网域名实测：两端点 200 且含精确深链、回退内容与 `no-store`／`noindex`／nonce CSP 响应头。

- 双语 README 顶部改为两张徽章图片（`docs/images/badge-add-to-feather.svg`、`docs/images/badge-add-to-altstore.svg`），分别直连上述两个 HTTPS 端点；「下载发布版本 / Download releases」保留为独立文字链接。README「Feather 安装源 / Feather source」章节与 [FEATHER_SOURCE.md](FEATHER_SOURCE.md) 同步改写：GitHub 仍只渲染 `http`/`https`/`mailto`，因此徽章指向 HTTPS 端点，由端点完成自定义 scheme 启动与可读回退。
- 测试：`FloeAgent/scripts/tests/test_readme_source_links.py` 改为钉住徽章→端点契约（锚点 href、本地徽章资源存在、下载链接独立、scheme 白名单）、源地址、Feed 形状与文档一致性，共 5 项通过；另用 GitHub Markdown API 实测渲染后徽章锚点 href 存活。
- 明确不做：不改动发布标签、`feather.json`、TestFlight 状态；不宣称端点在任何具体设备上完成过真实拉起（真机验收仍属用户）。

## 2026-09-22 Build 222：Runtime v2 与专项修复 / Runtime v2 and focused repairs

Build 222 documents the versioned Runtime v2 layout, content-addressed shared images, per-environment CoW/data ownership, migration recovery points, one-writer leases, four-VM queue, dynamic memory budget and Linux/MLX arbitration. It also records the local-model multi-turn tool repair and bounded PPT opening behavior. All four shipping targets move to 1.7.0 (222); release notes and bilingual TestFlight notes are added. Current evidence is source-level only: `FloeExecution` Swift 6 object compilation and seven focused PPT policy tests. Cloud distribution and physical-device results remain separate.

## 2026-09-22 Build 221：Build 220 App 编译修复与发布元数据 / Build 221: Build 220 App compile repair and release metadata

Build 220 的云端验收 SDK Release 设备 App 编译（rebuild run
[35673428023](https://github.com/JiangNanGenius/floe-agent/actions/runs/35673428023)，
Xcode 26.6 / iPhoneOS 26.5）在 App 目标失败：3 个文件共 14 条诊断
（`BackgroundRunCoordinator.swift` 9 条缺类型、`LinuxImageInstallCard.swift`
4 条 async/import、`OfficeDocumentEditorView.swift` 1 条属性名），无工件、无
签名、无上传。本轮在 `main` 上修复并把版本推进到 1.7.0（221）：

- 代码修复（不用条件编译隐藏，不移动文件）：`BackgroundRunCoordinator.swift`
  补 `import FloeExecution`（`LinuxGuestMetricsSampler`）与
  `import FloeModels`（`TaskNotificationDecision`、
  `NotificationAuthorizationState`），并把通知响应路由中送入 `MainActor` 闭包
  的非 Sendable 原始字典改为从深链身份重建的 `Sendable` 字符串负载；
  `LinuxImageInstallCard.swift` 改写 `hint ?? await …`（autoclosure 不支持
  并发）并补 `import FloeTools`（`CancellationToken`）；
  `OfficeDocumentEditorView.swift` 看门狗改用门禁真实属性
  `awaitsVisibleRender`。新增源文件的目标归属经核对：App 源按目录、SPM 目标
  按路径自动纳入，`TaskBannerCenter.swift` 已在生成工程中。
- 版本：四个出货目标统一 `MARKETING_VERSION 1.7.0` /
  `CURRENT_PROJECT_VERSION 221`，xcodegen 重新生成，pbxproj 仅 8 处
  `CURRENT_PROJECT_VERSION` 变化。
- 文档：新增 [Build 221 版本说明](RELEASE_NOTES_1.7.0_BUILD_221.md) 与
  [Build 221 测试说明](TESTFLIGHT_1.7_WHATS_NEW_BUILD_221.json)；更新
  `docs/README.md`、[TestFlight 交付记录](TESTFLIGHT_1.7.0_BETA.md)（220
  标记为编译失败、221 为当前候选）、实施状态与构建验收文档；Build 219 及
  更早记录保持原样。仓库根双语 README 不在本轮声明的编辑范围内，其候选段落
  仍指向 Build 220，留给下一步在授权范围内更新。
- 明确不做的：不创建或移动标签（尤其不动 `v1.7.0-beta.77` 与既有 beta 标签）、
  不推送、不触发工作流、不上传，也不宣称 Build 221 已云端构建、被 Apple
  处理、可安装、通过真机验收或已发布。
- 本轮检查：本机 Xcode 27 对修复后源码的 Debug 真机 SDK
  （iphoneos / generic iOS device）无签名完整构建成功（含固定 Office 宿主
  工件 run 35668651442、`engine.lock.json` 哈希校验与嵌入；App 与 Screen
  Share 扩展版本均为 1.7.0（221）；`#if canImport(FloeOfficeNative)` 设备
  路径参与编译）；`test_release_preflight_versions.py`（8）、
  `test_release_review_workflows.py`（28）、`test_readme_source_links.py`（4）、
  `test_feather_source.py`（4）、`test_prepare_testflight.py`（4）、
  `test_release_notes_component_gate.py`（24）与 FloeCore/FloeModels/
  FloeExecution 定向 Swift 测试、project.yml/pbxproj 版本一致性检查、
  TestFlight JSON 校验、`git diff --check`。
- 后续交付：固定标签 `v1.7.0-beta.78` 绑定源码 `20253e67`；release run
  35678610685 完成云端验收 SDK 构建、恢复工件留存、签名和上传。Apple build
  `387e2282-0814-4384-88a8-5a756d46a5ef` 经 prepare 35682313921 与 verify
  35682374446 核实 VALID、未过期、唯一私有内部 Floe QA 组、无公开链接且
  IN_BETA_TESTING，中英文测试说明已读回。GitHub 未签名预发布与 Feather 源已
  发布；模拟器 UI 按加速要求跳过，真机行为仍由用户验收。上述发布前限制保留为
  当时记录，不代表最终交付状态。

## 2026-09-22 Build 220 版本与发布元数据准备 / Build 220 version and release-metadata preparation

本轮在隔离分支 `codex/build220-release-metadata` 上把合并后的 `main` 源码 `9e83fcfa` 准备为 Floe 1.7.0（220），不改产品代码、工作流、标签或 `feather.json`：

- 版本：`FloeAgent/project.yml` 四个出货目标（App、Screen Share、Share、Widgets）统一为 `MARKETING_VERSION 1.7.0` / `CURRENT_PROJECT_VERSION 220`，并用 xcodegen 重新生成 `FloeAgent.xcodeproj`。生成结果与提交内容一致（`gen_project.sh` 的干净树检查）；pbxproj 仅 8 处 `CURRENT_PROJECT_VERSION` 变化，`MARKETING_VERSION` 不变，无 219 残留。
- 新增 [Build 220 版本说明](RELEASE_NOTES_1.7.0_BUILD_220.md)（中英双语：Linux 持久磁盘／`/floe/env` 缓存／9P `ls -l` 语义／安装状态，显式后台模式与实测指标，任务完成通知，PPTX 可见渲染与编辑入口修复，文档与侧载链接刷新；并区分源码实现与云端编译、真机验收）与 [Build 220 测试说明](TESTFLIGHT_1.7_WHATS_NEW_BUILD_220.json)。
- 指针更新：双语 README 的当前候选段落改为 Build 220（保留 219 已核实可安装的交付陈述）；`docs/README.md` 增加 220 候选入口、测试说明行与发布档案条目；[TestFlight 交付记录](TESTFLIGHT_1.7.0_BETA.md) 顶部新增 “Preparing: 1.7.0 (220) — metadata only, not built or uploaded”；实施状态与构建验收文档补记候选状态。
- 明确不做的：不创建或移动标签、不推送、不触发工作流、不上传，也不宣称 Build 220 已构建、已被 Apple 处理、可安装、通过真机验收或已发布；219 及更早的发布档案保持原样。
- 顺带修复：`FloeAgent/scripts/tests/test_release_review_workflows.py` 的便携 plist／版本夹具此前只在 `release_preflight.sh` 依赖 `bootstrap_office_host` 时打了桩，未给新增的 `office_release_gates` 读取打桩，导致该夹具在 HEAD 上 3 项失败（已用 stash 对照确认与本次版本改动无关）。本轮按夹具自身的“隔离便携检查、Office 门禁另有专项测试”约定补上通过型 no-op 桩，不弱化任何断言。
- 本轮检查：`test_release_preflight_versions.py`（8 项通过，含真实 Office pin 门禁与版本夹具）、`test_release_review_workflows.py`（28 项通过）、`test_readme_source_links.py`／`test_feather_source.py`／`test_prepare_testflight.py`／`test_release_notes_component_gate.py`（36 项通过）、TestFlight JSON 校验、真实 `project.yml` 与 pbxproj 的版本一致性 awk 检查、发布说明中英标题检查、改动文档相对链接检查与 `git diff --check`。

## 2026-09-22 侧载入口与 219 之后现状复核 / Sideload and post-219 audit

本轮只修改公开文档（`README.md`、`README.zh-CN.md` 与 `docs/`），不改代码、工作流、标签、`feather.json` 或 `Local/` 私有内容：

- 按钮复核：双语 README 顶部的 **Add to Feather / Add to AltStore**（中文「添加到 Feather / 添加到 AltStore」）按钮继续指向官网下载页 `https://www.floe-agent.com/#download`。GitHub 的 Markdown 过滤会同时移除 HTML 与 Markdown 写法中的 `feather://`、`altstore://` 链接（已用 GitHub Markdown API 实测：两种写法都只剩纯文本），所以 GitHub 上唯一可点击的快速添加入口就是官网，官网 chooser 再从页面发出真正的深链。
- 与官网逐字节对照：线上 `assets/index-CFo2eGcE.js` 中官网按钮使用 `feather://source/${SOURCE_URL}` 与 `altstore://source?url=${encodeURIComponent(SOURCE_URL)}`，`SOURCE_URL` 为 `https://raw.githubusercontent.com/JiangNanGenius/floe-agent/main/feather.json`。双语 README 的 Feather 安装源章节与 [FEATHER_SOURCE.md](FEATHER_SOURCE.md) 已记录两条完整深链（Feather 形式直接拼接，AltStore 形式为百分号编码），并注明 GitHub 会移除自定义 scheme。线上 `feather.json` 与仓库内文件逐字节一致（build 219）。
- 导航：中文 README 的「Feather 安装源」章节从文件末尾移回「开始使用」，与英文版顺序一致；文档索引补充 [FEATHER_SOURCE.md](FEATHER_SOURCE.md) 与 [FLOE_156_FEEDBACK_REPAIR.md](FLOE_156_FEEDBACK_REPAIR.md) 两个入口。
- 219 之后的 Office 事实：演示文稿宿主已由 office-native-host 运行 35668651442（`c4ff0dde`）重新编译链接，并在 `f0ca71a7` 重新固定；`engine.lock.json` 的 `capabilityQualification` 四项设备回执仍全部为 false，真机往返与写回未取得证据。双语使用指南、[FLOE_1_7_COMPATIBILITY.md](FLOE_1_7_COMPATIBILITY.md) 与 [FLOE_156_FEEDBACK_REPAIR.md](FLOE_156_FEEDBACK_REPAIR.md) 已按此改写；模拟器编译守卫修复（`67a37db3`）只记录定向检查通过，完整 App 云端门禁在复核时仍在运行。
- 运行时措辞：使用指南中「Node 宿主」改为客体 Node；`pyreadstat`/PyStata 与「纯 Python iOS 沙箱」的旧描述改为 Linux 客体 riscv64 构建或可信 SSH 主机。双语 README、使用指南与索引继续明确 App 不含原生 Python/Node/Ruby 载荷，语言与包由 Linux 客体或签名 WASI 目录提供。
- 明确留待后续证据：不宣称 Build 220 已构建、已上传、已被 Apple 处理、可安装、通过真机验收或已发布（见 [docs/README.md](README.md) 同一说明）。
- 本轮检查：`test_readme_source_links.py`（4 项通过）、`test_feather_source.py`（4 项通过）、`test_native_runtime_free_audit.py`（5 项通过）；深链字面量与官网构造逐字节对照、AltStore 深链解码回稳定源地址、改动文档相对链接与 `git diff --check` 均通过。

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
