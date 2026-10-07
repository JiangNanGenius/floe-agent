# 当前版本与验证状态 / Current release and verification status

更新时间 / Updated: 2026-10-07. 本页区分已记录交付与未发布候选，不保证 TestFlight 的实时审核/到期状态；安装前以 App Store Connect/TestFlight 当前显示为准。This page separates recorded delivery from candidates; check TestFlight for current approval and expiration.

## 1.7.22（263）候选 / Candidate

- 浏览器接管交接、真实地址和全屏；大会话首批数据与时间线缓存；虚拟机启动合并、停止确认；终端与共享端口管理。Browser handoff, address/full screen, bounded history and cached timeline, coalesced VM startup, terminal and shared ports.
- 本地 Xcode 27 完整设备验证构建通过；模块 38 + 19 项、iPad 模拟器 45 项定向测试通过。后续 UI 修订及最终固定源码构建正在验证。Local Xcode 27 full-device validation build, 38 + 19 module cases and 45 focused iPad Simulator cases passed; final source verification is pending.
- 尚未上传、内部尚不可安装、尚未公测送审。Not uploaded, internally installable or submitted for external review yet.
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
