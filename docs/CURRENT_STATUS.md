<!-- docs-updated: 2026-10-16 -->
# 当前版本与验证状态 / Current release and verification status

文档更新时间 / Document updated: 2026-10-16. 本页区分已记录交付与未发布候选，不保证 TestFlight 的实时审核/到期状态；安装前以 App Store Connect/TestFlight 当前显示为准。This page separates recorded delivery from candidates; check TestFlight for current approval and expiration.

## 1.7.32（273）内部交付；工作分支为未发布候选 / Internal delivery; working branch is unreleased

- `project.yml` 声明 **1.7.32 (273)**。2026-10-15 由冻结源码 `29937dc025267bacd89434cc092b3906c99b93ee`（标签 `v1.7.32`）完成本地 Xcode 27 归档，复用本地产物签名上传（未重编 App），独立回读 Apple `VALID`、未过期、现有内部 Floe QA 组 `IN_BETA_TESTING`；**未提交 publictest1、未外审、未对外发布**。详见[发布说明](releases/notes/RELEASE_NOTES_1.7.32_BUILD_273.md)与[273 修复记录](releases/repairs/FLOE_273_TEMPORARY_SUBAGENT_REPAIR.md)。Build 273 is the current internal Floe QA build; no external submission or publication was performed.
- 工作分支 `codex/temporary-subagent-perf-20261015`（基线 `923b1e48`）包含下一轮的**未发布**改动：任务生命周期 UI（临时会话入口收敛、决定回执去重、子代理检查器）、后台/子运行闭环与调度扩展、逐模型能力元数据与一次性复查、CAD 绘图/装配可发现契约。当前仅为**已实现/组件级验证**，完整 App 编译、模拟器验收、版本冻结、上传和公测全部未开始；不得据此宣称任何新修复已交付。详见[任务生命周期回合记录](releases/repairs/FLOE_TASK_LIFECYCLE_20261015.md)。The working branch carries implemented, component-verified changes; full-App acceptance, versioning and upload have not started.
- 本轮授权：新版本在完成 G/主协调质量门后**可提交现有 publictest1 公测**；1.7.28（269）仍仅内部，不提升。更早记录（271 等）为本页历史，实际审核/到期状态以 App Store Connect/TestFlight 为准。Earlier records below remain historical; check App Store Connect for live review and expiry state.

## 1.7.30（271）紧急修复：内部可用，已送 publictest1 等待审核 / Internal available; external review pending

- `v1.7.30` 固定源码 `bdb79bf8751ba67676e2a57e6916fd6ca8d6d151`。名称整理保留中文、emoji、横杠、下划线及小数点；蓝牙改为实际扫描/连接时初始化，并提前拒绝无效 GATT UUID。Immutable hotfix source preserves meaningful Unicode and identifier punctuation; Bluetooth starts on demand and validates GATT UUIDs before the system API.
- 本地 Xcode 27 完整 App 编译及 Release 归档成功；43 项针对性测试、iPad/iPhone 保存与重启验收通过。真实服务商完整配置已保存，重启后使用 Keychain 凭据获得预期模型回复；数据库读回模型 ID 与 128K/4K 参数一致。[本地验收](releases/testflight/BUILD_271_LOCAL_VERIFICATION.md)。Full local build/archive, scoped tests, both UI flows and a restarted real-model request passed.
- 本地归档、匹配符号及哈希已保留；传输包 SHA-256 `052290d8038db81184e6e05203906952fe0c1b841c3cc7a53d75689b2beb7892`，App/dSYM UUID `DC35A10D-5E43-39A8-9C2C-B90EADF425D1`。[仅签名上传38208178806](https://github.com/JiangNanGenius/floe-agent/actions/runs/38208178806)成功；Apple `VALID`、未过期、Floe QA `IN_BETA_TESTING`。随后网页送审与[独立只读核验38209568536](https://github.com/JiangNanGenius/floe-agent/actions/runs/38209568536)确认 publictest1 已关联、仅一条 `pending_review`，外部状态 `WAITING_FOR_BETA_REVIEW`，双语测试说明与审核备注一致、issues 为空。Internal installation is available; external installation awaits review.
- 本轮不等待完整云端 CI；仅签名上传使用现有云端能力。蓝牙真机授权、外设连接与 iOS 26 实机仍待设备验证。No full cloud matrix; physical BLE and iOS 26 device acceptance remain open.

## 1.7.29（270）内部可用；已送 publictest1，等待 Apple 审核 / Internal available; submitted to publictest1, waiting for Apple review

- 不可变 `v1.7.29` 固定源码 `3286444c2c167f2a49305785dc78a06f60402ece`（版本检查点，位于已验收功能提交 `3c0e6fbd` 之上），并已合并 main（文档提交 `13d4dfc0`…`89473c22` 随行）。Immutable tag/source merged into main with its docs-only follow-ups. Earlier local candidate 1.7.28（269）remains internal-only and was never promoted.
- 本地 Xcode 27.0（27A266a）/ iPhoneOS 27.0 Release 设备构建成功，签名前已立即留存设备包、匹配 dSYM/UUID、SHA-256 与 provenance；该精确产物经私有 draft 传输由云端仅做签名/校验/上传（未重新编译 App）：[签名与内部核验](https://github.com/JiangNanGenius/floe-agent/actions/runs/38137064773)。App 二进制 `7519d466…`，传输包 `5d1f00ee…`（877,827,483 B），App/dSYM UUID `F12587B9-E443-3105-92C0-46D18B12BE22`。本地核验细节见 [BUILD_270_LOCAL_VERIFICATION.md](releases/testflight/BUILD_270_LOCAL_VERIFICATION.md)。
- 内部核验：Build 270 为 `VALID`、未过期、`APP_STORE_ELIGIBLE`，现有 Floe QA 组 `IN_BETA_TESTING`，中英文测试说明已读回（独立 GET-only [回读](https://github.com/JiangNanGenius/floe-agent/actions/runs/38139400836)）。内部 TestFlight 可安装。Independent readback confirms VALID, unexpired, APP_STORE_ELIGIBLE and existing Floe QA availability.
- 公测 publictest1：先在 API 提交时被 Apple 以 **HTTP 403 `FORBIDDEN_ERROR`** 拒绝首个写入（`PATCH /v1/betaAppReviewDetails`，当前 API 密钥缺少 App 级审核信息写权限；未附着、未提交、无部分写入，[只读回读](https://github.com/JiangNanGenius/floe-agent/actions/runs/38139655286) 保留）。随后主协调通过已登录的 App Store Connect 网页保存最终审核备注（读回 3,588 字符与仓库文件严格一致）并把 270 加入现有 publictest1 送审一次。独立只读 API [回读 38141425415](https://github.com/JiangNanGenius/floe-agent/actions/runs/38141425415) 确认：`VALID`、未过期、`IN_BETA_TESTING`、`publictest1` 已关联（`attachedToBuild true`）、提交状态 `WAITING_FOR_BETA_REVIEW`（submission count 1，`pending_review`）。**外审批准是独立门槛，尚未批准、尚不因此对外可安装。** The API write was refused with 403 (no partial write, retained); the existing authenticated web flow then submitted build 270 to publictest1 once, and the independent API readback confirms the waiting-review state. External approval remains pending.
- 到期与审核状态实时变化：以 App Store Connect/TestFlight 当前显示为准；不要用本页替代实时检查。Live expiry/review state must be re-checked in App Store Connect.
- 实测边界：T7 已验收 iPhone 全屏 3D 相机保持/返回与全屏取消（PNG26–30）；iPad 在系统标准最大字体下的创作首页与设计表单已通过（PNG31），**辅助功能特大字体未测试**；分屏/窗口化未验收——窗口边缘交互曾出现未定因黑屏（进程存活、无特定崩溃报告，重启设备后 Floe 正常，PNG32/34）。实体设备流畅度属用户验收。禁止把本页读作外审已通过。iPhone fullscreen 3D camera/cancel acceptance passed; iPad largest standard text passed (PNG31); accessibility extra-large text untested; split-window unqualified after an unconfirmed windowing black frame (process alive, device restarted normally); physical-device fluidity belongs to the user.

## 渠道只读复核 / Channel readback · 2026-10-09

- GitHub 与 Feather/AltStore 分发已于 2026-10-09 补齐至 **1.7.24（265）**；GitHub 为预发布，IPA 未签名，需自行签名。latest 稳定版仍为 1.7.0（241）。GitHub prerelease and source feed now carry **1.7.24 (265)**; the IPA requires your own signing. Stable latest remains 1.7.0 (241). [分发核验 / Distribution verification](releases/verification/RELEASE_DISTRIBUTION_1.7.24_20261009.md).
- Apple GET-only 核验（2026-10-09）：Build 265 为 `VALID`、未过期，内部 `IN_BETA_TESTING`，publictest1 外部状态 `WAITING_FOR_BETA_REVIEW`，检查 issues 为空。Apple readback confirms VALID, unexpired, internal availability and external review still pending; no submission or membership was changed. [只读核验 / Readback](https://github.com/JiangNanGenius/floe-agent/actions/runs/37872109678).
- 官网与源码版本不等于全部渠道同时可安装。Gitee 仅作源码与发行记录同步，不作为 App 下载加速或 Linux 自动回退。Website/source version does not establish installation availability across channels. Gitee synchronizes source and releases; it is not an App accelerator or automatic Linux fallback.

## 1.7.24（265）内部可用，公测待审 / Internal available, external review pending

- 不可变 `v1.7.24` 固定 `246d6c038f0a3f7ec7d7d9f7e19d074f13601bec`，已合并 main。Xcode 27A266a / iphoneos27.0 本地 Release 完成，App 与 dSYM UUID 匹配；相关定向测试和真实模型闭环通过，不宣称完整云端 CI 或实体设备验收。Immutable tag/source merged into main; local Release and matching symbols retained. Focused verification and the real-model loop passed; full cloud CI and physical-device acceptance are not claimed.


- 真实模型图纸助手闭环已通过：能力／图元查询、确定性测量、单图元移动提案、界面预览和确认、保存重开。独立 LibreDWG 回读确认目标直线从 (0,0)–(10,10) 变为 (1,0)–(11,10)，保存哈希匹配，通知送回原会话。最终 Xcode 27 设备构建已通过。The real-model Drawing Assistant loop passed queries, measurement, a one-entity move proposal, UI preview/confirmation and save/reopen. Independent LibreDWG confirmed the expected coordinates and saved hash; the decision reached the original conversation. The final Xcode 27 device build passed. Earlier checks below apply to their tested revisions.

- 二维 DWG/DXF 应用内编辑与 `cad.document`、图纸助手（图纸助手/Drawing Assistant）、Office 共享命令目录 `document.office.edit`、手记提案/精确搜索/PDF 与 `.floenote` 导出、画布矢量图纸节点与媒体子工程文件化备份（已含 CAD 草稿和修订素材，19 项备份定向测试通过）、图片/视频细化。In-app 2D DWG/DXF editing and `cad.document`, Drawing Assistant, the shared Office `document.office.edit` catalog, Notes propose/exact-search/PDF and `.floenote` export, vector Canvas drawing nodes and file-backed media child-project backups (including CAD drafts and revision assets, covered by 19 focused backup tests), plus image/video refinements.
- 历史：开发期分支 `codex/build265-creative-cad` 已合并 main 并删除；`project.yml` 1.7.24（265）。模拟器完整 App 构建通过、19 项定向 App 测试通过；CAD-in-Canvas 已在 iPad 模拟器 CUA 中两次“加线/加圆→保留草稿→重开→完成到同一节点”，独立 LibreDWG 复读 LINE1/CIRCLE2→LINE2/CIRCLE3，原节点哈希不变。Historical: the development branch `codex/build265-creative-cad` was merged into main and deleted; `project.yml` 1.7.24 (265). Simulator App build + 19 focused tests pass; CAD-in-Canvas verified twice in an iPad simulator CUA with an independent LibreDWG re-read and the original node hash unchanged.
- **已固定标签并保存设备包；已复用本地产物完成签名上传，未重新编译 App。** 独立回读确认 Apple VALID、未过期、现有 Floe QA 组关联和内部 IN_BETA_TESTING；2026-10-08 已加入现有 publictest1 并提交审核，正在等待 Apple 审核，尚未外部批准。引擎层 Office `.uno:` 编辑仅真机可验（准备时 `devicectl` 无真机），其他真实供应商效果未验；保存时的同引擎重解析是应用内门，LibreDWG 只是代表性产物的离线发布资格核对。**Immutable tag and recoverable device artifact retained; the local artifact was signed and uploaded without an App rebuild.** Independent readback confirms Apple VALID, unexpired, existing Floe QA membership and internal IN_BETA_TESTING. Build 265 was submitted to the existing publictest1 group on 2026-10-08 and is waiting for Apple review; external approval is pending. Engine-tier Office editing is device-only, other real providers remain unverified; the same-engine reparse is the in-app save gate while LibreDWG is only an offline release-qualification cross-check.
- [签名与内部验证 / Signing and internal verification](https://github.com/JiangNanGenius/floe-agent/actions/runs/37763059515) · [送审后独立回读 / Independent post-submission readback](https://github.com/JiangNanGenius/floe-agent/actions/runs/37766370762).
- [创作工具契约与能力表 / Tool contracts and capability table](FLOE_1_7_24_CREATIVE_TOOLS.md) · [更新说明 / Release notes](releases/notes/RELEASE_NOTES_1.7.24_BUILD_265.md)

## 1.7.23（264）内部可用，公测待审 / Internal available, external review pending

- 图片／视频统一工程、图层、时间线、AI 候选和 `media.project`，中英文手册已更新。Unified projects, layers, timeline, AI candidates and media.project; bilingual guides updated.
- Xcode 27 模拟器完整 App 编译通过，46 项模块测试及 19 项 App 定向测试通过；iPad 横竖屏、宽屏三栏、iPhone 窄屏、全屏、保存重开和系统“存储到文件”已实际检查。Full simulator App compile, 46 module and 19 focused App tests passed; rendered layouts, full screen, reopening and native Save to Files verified.
- 不可变标签 `v1.7.23` 固定源码 `7f23c5023257914c1e136400ecdd0659f06a0af4`；Xcode 27 设备 Release 构建通过，设备包和匹配符号已留存。已复用本地产物完成签名上传；Apple VALID、未过期、现有 Floe QA 关联和内部 IN_BETA_TESTING 已确认。2026-10-07 已加入现有 publictest1 并提交，正在等待审核，尚未外部批准。Immutable source/tag, device build and matching symbols are confirmed. The local artifact was signed and uploaded; VALID, unexpired status and Floe QA internal availability are confirmed. Submitted to existing publictest1 on 2026-10-07; waiting for review, not externally approved.
- [签名与内部验证 / Signing and internal verification](https://github.com/JiangNanGenius/floe-agent/actions/runs/37628290765) · [送审后独立回读 / Independent submission readback](https://github.com/JiangNanGenius/floe-agent/actions/runs/37630764926).
- 实际系统分屏拖动未能通过模拟器控制工具完成；真实设备流畅度、HDR 和付费生成未验收。OS split-window dragging could not be exercised through the simulator controller; physical performance, HDR and paid generation remain unverified.

[工作台说明 / Workbench guide](FLOE_MEDIA_WORKBENCH.md) · [验证记录 / Evidence](releases/notes/FLOE_1_7_23_MEDIA_WORKBENCH.md)

## 1.7.22（263）内部可用，公测待审 / Internal available, external review pending

- 浏览器接管交接、真实地址和全屏；大会话首批数据与时间线缓存；虚拟机启动合并、停止确认；终端与共享端口管理。Browser handoff, address/full screen, bounded history and cached timeline, coalesced VM startup, terminal and shared ports.
- 本地 Xcode 27 完整设备验证构建通过；模块 38 + 19 项、iPad 模拟器 45 项定向测试通过。最终源码 `0a847da5cf14fe5ee259056f0ac994b9dd9b9f4e` 的设备构建已通过，App／符号已留存并匹配 UUID；交接恢复 11 项通过，iPad 与 iPhone 浏览器 UI 已检查。Local Xcode 27 exact-source device build, 38 + 19 module cases, 45 focused iPad cases and 11 final handoff cases passed; matching App/symbol artifacts were retained and iPad/iPhone browser UI inspected.
- 已复用本地产物完成签名上传；Apple VALID、未过期、现有 Floe QA 关联及内部 IN_BETA_TESTING 已确认。2026-10-07 05:36 UTC，263 已加入现有 publictest1 并提交审核，正在等待 Apple 审核，尚未外部批准。[签名与内部验证](https://github.com/JiangNanGenius/floe-agent/actions/runs/37575259173) · [送审后独立回读](https://github.com/JiangNanGenius/floe-agent/actions/runs/37577274266)。Signing/upload reused the local artifact; VALID, unexpired status and existing Floe QA internal availability are confirmed. Build263 was submitted to existing publictest1 at05:36 UTC and is waiting for review; external approval remains pending.
- 1 万条合成消息的首批数据读取约 11 ms；这不是完整首屏历史版本对比，尚不能证明 40% 改善或峰值内存不回退。The 10k synthetic first data page took about 11 ms; this does not establish the 40% full-first-screen improvement or a peak-memory baseline comparison.

[更新说明 / Changes](releases/notes/RELEASE_NOTES_1.7.22_BUILD_263.md) · [端口说明 / Ports](FLOE_PORT_MANAGEMENT.md)

## 1.7.21（262）上一轮更新 / Previous update

- 不可变源码 / Immutable source: `v1.7.21` → `2bb37ca67a5d8ece5b3fd68e61069444eafdea58`，已合并 main / merged into main.
- Xcode 27 本地 Release 设备构建、27 项相关服务/终端测试及 iPad 运行窗口/全屏终端 UI 验证通过。Local Xcode 27 Release device build, 27 focused service/terminal tests and iPad run-sheet/full-screen terminal UI verification passed.
- 已复用本地产物完成签名上传。2026-10-06 21:13 UTC 独立回读确认 Apple VALID、未过期、现有 Floe QA 组关联及内部 IN_BETA_TESTING；内部可安装。publictest1 已于 2026-10-07 01:53 UTC 送审，正在等待 Apple 审核，尚未批准。Signing/upload reused the local artifact. Independent readback at 21:13 UTC confirmed VALID, unexpired, existing Floe QA membership and internal IN_BETA_TESTING. Internal installation is available; publictest1 was submitted on 2026-10-07 at 01:53 UTC and is waiting for Apple review; external approval is pending.
- [内部可用核验 / Internal availability](https://github.com/JiangNanGenius/floe-agent/actions/runs/37532263968) · [独立 Apple 回读 / Apple readback](https://github.com/JiangNanGenius/floe-agent/actions/runs/37531932664). 原签名运行的处理等待超时，未重复上传；之后独立核验通过。The original signing run timed out waiting for processing; later verification passed without another upload.
- [公测送审独立核验 / External submission verification](https://github.com/JiangNanGenius/floe-agent/actions/runs/37559293000): VALID、未过期、publictest1 已关联，WAITING_FOR_BETA_REVIEW；自动通知测试员已启用。VALID, unexpired, attached to publictest1 and waiting for beta review; automatic tester notification is enabled.
- 本轮按用户要求采用本地快速发布，未以完整云端矩阵作为门槛；真实 iPad 终端输入/换行及服务驻留仍待复测。This expedited local route does not claim a complete cloud matrix; physical iPad terminal input/wrapping and service persistence remain to be retested.

[更新说明 / Changes](releases/notes/RELEASE_NOTES_1.7.21_BUILD_262.md) · [本地证据 / Local evidence](releases/testflight/BUILD_262_LOCAL_VERIFICATION.md) · [快速发布流程 / Local release route](releases/testflight/LOCAL_BUILD_RELEASE.md)

## 上一轮已记录交付 / Previously recorded delivery

以下为各版本当时的状态，不表示本轮已完成。These are dated earlier-build records, not completion of the current update.

| 项目 / Item | 状态 / State | 证据 / Evidence |
| --- | --- | --- |
| 内部测试 / Internal beta | 1.7.19 (260), Apple VALID、未过期、Floe QA 已可用 / VALID, unexpired, available in Floe QA | [内部准备验证](https://github.com/JiangNanGenius/floe-agent/actions/runs/37436584073) |
| 公开测试 / External beta | Build 260 已加入 publictest1 并送审，正在等待审核 / submitted to publictest1, waiting for review | [送审记录](public-beta/build260/README.md) |
| 当前发布 / Current release | 1.7.19 (260), `0fbb7a191937fed37dbc2ada08c3d9d6921e3a91`; 完整 CI、签名上传和发布通过；标签不可变 / full CI, signed upload and release passed; immutable tag | [完整 CI](https://github.com/JiangNanGenius/floe-agent/actions/runs/37414808365) · [发布](https://github.com/JiangNanGenius/floe-agent/actions/runs/37424141658) |
| GitHub / Feather | GitHub prerelease 与 Feather 源已更新；Feather 使用未签名开发 IPA，需要用户自行签名 / prerelease and source updated; unsigned developer IPA requires signing | [预发布](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.7.19) · [Feather 发布](https://github.com/JiangNanGenius/floe-agent/actions/runs/37434428471) |
| 256–258 候选 / Earlier candidates | 测试受阻，未据此发布 / blocked by verification; not delivered | [稳定性修复](releases/repairs/FLOE_256_STABILITY.md) |
| 原生 Office / Native Office | 编译与部分工具链证据不替代 iPad 连续笔迹、原文件写回、保存重开 / device ink and writeback remain separate | [验收范围](OFFICE_FRONTEND_ACCEPTANCE.md) |

## 候选变更 / Candidate changes

- Linux 首次启动按任务选择性能；成功启动后恢复核心/内存配置；优先复用有效镜像。First-start workload selection, saved launch shape and verified image reuse.
- 工作区本地终端入口与明确的镜像安装提示。Local workspace terminal with visible image installation.
- Office 自由绘制入口默认图形修复。Office freehand entry fix.
- 本地模型提示压缩并保留工具契约。Bounded local prompt retaining required contracts.
- 工程图本地初次连接失败的一次恢复；已交付文档/编辑状态不重载。One initial local-preview recovery without reloading delivered editing state.

Build 260 已通过完整 CI、发布构建和签名上传。2026-10-06 08:30 UTC 的 Apple 验证显示 VALID、未过期、内部 IN_BETA_TESTING，已确认现有 Floe QA 组关联与双语测试说明。源码已合并 main，标签固定 `0fbb7a19`；可恢复设备产物已留存。外部 publictest1 已完成送审，正在等待审核，尚未批准。实体设备安装和 Office 连续笔迹验收仍待用户测试。

Build 260 passed full CI, release building and signed upload. Apple verification at 08:30 UTC on 2026-10-06 confirmed VALID, unexpired, internal IN_BETA_TESTING, existing Floe QA membership and bilingual test notes. Main is merged, the tag remains fixed at `0fbb7a19`, and a recoverable device artifact is retained. External publictest1 submission is complete and waiting for review, not approved. Physical installation and sustained Office ink acceptance remain unverified.

## 阅读顺序 / Reading order

1. [中文操作手册](USER_GUIDE.zh-CN.md) / [English manual](USER_GUIDE.md).
2. [文档索引](README.md) / [本次文档审计](DOCUMENTATION_REFRESH_20261005.md).
3. 专题文档说明实现和限制；其中带日期的构建结果只适用于原版本。Topic documents retain implementation detail; dated evidence applies to its recorded source.
4. [发布档案](releases/README.md)只作为逐版本证据。Release archives preserve original results.

发布完成需分别确认：构建、留存产物、签名上传、Apple VALID、目标测试组可用、外部审核。Build, retained artifact, signed upload, Apple processing, group availability and external approval are distinct gates. 官网文档上线不代表 App 候选发布。Website publication is separate from App release.
