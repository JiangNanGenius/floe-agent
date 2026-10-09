<!-- docs-updated: 2026-10-09 -->
# 当前版本与验证状态 / Current release and verification status

文档更新时间 / Document updated: 2026-10-09. 本页区分已记录交付与未发布候选，不保证 TestFlight 的实时审核/到期状态；安装前以 App Store Connect/TestFlight 当前显示为准。This page separates recorded delivery from candidates; check TestFlight for current approval and expiration.

## 渠道只读复核 / Channel readback · 2026-10-09

- GitHub Releases 与 Feather 源实时读取：最新公开 App 预发布与源条目均为 **1.7.19（260）**。GitHub 的 latest 稳定版为 1.7.0（241）；不能用 latest 稳定版端点代替预发布查询。Live GitHub and Feather readback: newest public App prerelease/feed entry is **1.7.19 (260)**; the stable latest endpoint returns 1.7.0 (241).
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
