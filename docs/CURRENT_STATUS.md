<!-- docs-updated: 2026-10-23 -->
# 当前版本与验证状态 / Current release and verification status

文档更新时间 / Document updated: 2026-10-23. 最新交付见首项，较早版本保留当时记录。审核与到期状态以 App Store Connect/TestFlight 当前显示为准。The first entry records the latest delivery; older entries retain their dated results. Check TestFlight for live approval and expiration.

当前实施批次为**连续语音、增强语音模型替换、个性化管理、更新管理及外部文件导入去向**。先集成代码，再统一验证和发布；当前改动尚未交付。[活动计划](FLOE_VOICE_CLOSURE_20261023.md)。此前阶段的完成记录继续保留。

The active batch covers continuous voice, the smaller enhanced speech pack, personalization retention, Settings updates and Notes/task/Canvas import destinations. Code integration precedes unified qualification and distribution; this batch is not delivered yet.

## 1.7.47（288）内部可安装，无签名包与 Feather 已交付 / Internal and unsigned available

[288 交付记录](releases/testflight/BUILD_288_DELIVERY.md)保留本地构建、207 项宿主测试、内部可安装、稳定 GitHub 安装包及 Feather 回读证据。公开 TestFlight 尚未提交：API 审核说明写入返回 403，网页路径等待 Apple 验证；这不是外部可安装状态。当前反馈涉及的真实语音链路和模型内存问题进入上述修复批次。The delivery record separates internal availability, unsigned publication and the unfinished external submission; current microphone and memory defects are being repaired in the active batch.

以下保留此前发布时的记录。The entries below retain earlier release records.

## 1.7.44（285）候选集成中，尚未交付 / Candidate integration, not delivered

签名快捷指令模板、计划结束清理、文件分享字节保留及 File Provider 修复已进入共同候选。实际系统导入、原生计划选择和稳定 ID 保存已有模拟器证据；完整 App 交接、异常与结束清理尚待本批复验。新反馈追加 Office 打印／PDF 导出真实预览和 Excel 设置闭环，已纳入同一候选，完成代码后集中验证。仅生成模板、提交代码或推进版本号均不代表 285 已可安装。The signed schedule template and system-file repairs are integrated; actual simulator import and stable plan selection are recorded. App handoff and cleanup checks remain pending. Office PDF/print preview and Excel page options are part of this candidate. Build 285 is not yet delivered.

## 1.7.43（284）内部可安装，无签名包与 Feather 已交付 / Internal and unsigned available

- 系统“运行定时任务”动作、计划选择、精确运行返回、实例去重和恢复已集成；完整 App／Swift 6 对象编译、45 项适用宿主用例及实际系统动作／中文摘要检查完成。模拟器模型不可用；时间触发器登记不能证明无人值守执行，设备边界见[验证记录](releases/repairs/FLOE_S4_SCHEDULING_20261021.md)。The selected-schedule action and recovery are integrated and qualified; physical unattended behavior is not claimed.
- [内部上传](https://github.com/JiangNanGenius/floe-agent/actions/runs/39587359107)及[独立 Apple 回读](https://github.com/JiangNanGenius/floe-agent/actions/runs/39589699551)成功：`VALID`、未过期、唯一 Floe QA／`IN_BETA_TESTING`。**内部可安装**。原 App、匹配符号和实际上传 IPA 已保存；云端没有重编 App。Internal availability is independently verified; the actual uploaded package and matching symbols are retained.
- [稳定 latest Release](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.7.43)及[同次 awaited Feather](https://github.com/JiangNanGenius/floe-agent/actions/runs/39589691700)独立回读通过，仅无签名 IPA、`.sha256` 与必要来源文件。IPA SHA-256 `53620fe9230c44fdacb4c198839321ed12e186a7fa970dc9d36b8e61bf0af2e6`，实际 801,604,177 字节；在线订阅的地址、版本、源码、大小与摘要全部匹配。The canonical unsigned trio and live feed match; installation outside TestFlight requires signing.
- 用户单次授权仅补中文发布说明标题并修正 `v1.7.43` 至 `a5042e27`；与实际编译源码 `8722c5cb` 的整个 App 树相同，原标签及失败记录保留。两份私有传输草稿、两份本地传输 ZIP 与重复展开的 App 已删除，实测外置卷净增加 3,290,484,736 字节（约 3.06 GiB）；保留当前包、11 份匹配符号、必要恢复和下一组明确复用的依赖缓存。没有启动中的模拟器。The approved copy-only correction reused the same App; staging and redundant outputs are cleaned, with recovery evidence retained.

## 1.7.42（283）内部可安装，无签名包已交付；公开送审一次等待审核 / Internal and unsigned available; one external submission waiting for review

- Office 自动保存、助手区域查看／真实导出、PDF／打印设置、Excel 荧光笔及手记冲突修复、S3-D 文件结果和联网内容来源已集成。本地实际 7 项最终相关用例全部通过；原表格颜色误差 0、网格保留率 100%，此前定向证据保留。
- [内部上传](https://github.com/JiangNanGenius/floe-agent/actions/runs/39552556058)成功，Apple `VALID`、未过期，现有 Floe QA／`IN_BETA_TESTING`。**内部可安装**。[稳定最新版 Release](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.7.42)及[同次 Feather](https://github.com/JiangNanGenius/floe-agent/actions/runs/39552615636)独立回读通过，IPA SHA-256 `bb69c39319d6d1eff2068c4f490045c70c4b636cb6d5c9cfd0e39cce5ce25f31`。
- `v1.7.42` 固定至 `c0d56124`；在用户授权下只补两份说明修正标签，App 树与本地归档源码 `e4d778c7` 一致，没有重建。源码合入 main，任务分支、私有传输草稿、一次性编译和展开副本已清理。2026-10-21 通过已认证 Safari 保存 283 专属审核备注、加入现有 `publictest1` 并送审一次，Safari 显示正在等待审核；[独立 GET-only 回读](https://github.com/JiangNanGenius/floe-agent/actions/runs/39566861939)确认构建 `3b67cbac…` `VALID`／未过期、`IN_BETA_TESTING`、外部 `WAITING_FOR_BETA_REVIEW`、群组已关联、恰有一条 `pending_review` 且 issues 为空。**外部可安装仍待 Apple 批准**；275 正式提交与已有 281／282 申请保持不变，未重复查询或提交 281／282。
- Physical Pencil feel and printer output remain device checks. The unsigned IPA requires signing; internal availability does not imply external approval. [283 交付与边界 / Delivery and limits](releases/testflight/BUILD_283_LOCAL_VERIFICATION.md)。

## 1.7.41（282）内部可安装，公测已送审，无签名包已交付 / Internal available; external review pending; unsigned delivered

- 不可变 `v1.7.41` → `268e21cb8aaaf13c92f3b35a07e57ae1071126ee`，本地 Xcode 27 设备归档及匹配符号已保存；同源包由云端只签名／打包，没有 App 重建。
- 当前 Office 页面的未保存笔迹进入助手请求；编辑器提交后可新增数字、求和、保存回读；移除永久魔棒命令，修复实时捏合及落笔预览。S3-A／B／C 的初始化、草稿队列和精确运行查询／文本已集成。文件结果和真实定时留 D／S4。Current Office ink and editing paths plus A/B/C are integrated; files and actual scheduling remain next.
- [内部上传](https://github.com/JiangNanGenius/floe-agent/actions/runs/39478307360)与[独立只读回查](https://github.com/JiangNanGenius/floe-agent/actions/runs/39482127761)成功：VALID、未过期、现有 Floe QA／IN_BETA_TESTING，**内部可安装**。随后按新增授权通过 Safari 向现有 publictest1 送审一次；[独立回读](https://github.com/JiangNanGenius/floe-agent/actions/runs/39493804095)确认为 `WAITING_FOR_BETA_REVIEW`、唯一一条 `pending_review`、群组已关联。外部可安装仍待 Apple 批准；275 正式提交及已有 281 申请未改，不重复送审。Internal installation is verified; one publictest1 submission is waiting for Beta Review. External installation awaits approval.
- [稳定最新版 Release](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.7.41)与[同次 Feather 发布](https://github.com/JiangNanGenius/floe-agent/actions/runs/39479921433)成功；仅无签名 IPA／校验及精简来源文件。SHA-256 `7fac824e544f0c75d52d69317e71616799c2ddfe090836eddc208cc6b50f0dff`，实时 Feed 的版本／源码／地址／大小／摘要独立匹配。Installation outside TestFlight requires the user's own signing.
- 原失败和通过证据保留，仅补验受影响用例；模拟器关闭，任务分支、私有 draft、缓存与展开副本已清理。真实 Pencil 手感／压力／手掌误触及联网手写识别准确率仍不以模拟器证明。[282 交付](releases/testflight/BUILD_282_LOCAL_VERIFICATION.md) · [Office 验收](releases/repairs/FLOE_OFFICE_ASSISTANT_LIVE_INK_20261021.md) · [C 验收](releases/repairs/FLOE_SHORTCUTS_S3C_20261021.md)。

以下 A／B 记录保留源码阶段当时的结果；现已随 282 集成，不再等待独立安装包。The dated source-stage records below are now integrated in build 282.

## S3-B 草稿队列源码已完成 / Durable shortcut drafts qualified

验收源码 `88dc1b71487a5906cbae96903d38504bfe536a4b`：连续草稿不覆盖、顺序领取、旧数据迁移、落盘回执及失败／重启恢复完成；真实存储探针 34 项通过，完整 App／测试宿主编译通过，原生 **62 通过、0 失败、0 跳过**。源码推送 main，S3-C 运行查询与文本结果已启动；安装包随后续集成，现有 281 不变。[验收记录](releases/repairs/FLOE_SHORTCUTS_S3B_20261020.md)。The source stage is qualified; hosted production Intent/Home paths are distinct from system Shortcuts/Siri dispatch and physical-device acceptance.

## S3-A 初始化源码已完成 / Shortcut initialization source complete

实现源码 `91269c602a01a2c5cdf926aad5759521741dc0b1`：修复 App／旧快捷指令的共享准备、并发、失败重试及取消；完整本地 App 编译通过，实际 App 宿主定向 9 项通过、0 失败、0 跳过，生产 helper 检查 25 项通过。本小包不改版本和已发布安装包，下一小包 S3-B 草稿队列。[验收记录](releases/repairs/FLOE_SHORTCUTS_S3A_20261020.md)。Source qualification is complete; it awaits a future integrated installable build. Hosted actual-intent entry is distinct from operating-system Shortcuts/Siri dispatch and physical-device testing.

## 1.7.40（281）内测可安装，无签名包已发布，外测待审 / Internal available; unsigned published; external review pending

- 不可变 `v1.7.40` 固定源码 `57ed0b78b9fa58c4dce140f45c6a359295b26dd1`，已合并 `main`。本地 Xcode 27 Release 归档成功，原始设备包、匹配符号和哈希已保留；同源包由云端仅做打包证明或签名上传，没有云端 App 重建。Immutable source is merged into main; the local Xcode 27 archive succeeded, and its original device package and matching symbols are retained. Cloud steps reuse that package without rebuilding the App.
- [稳定最新版 Release](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.7.40) 与 Feather 已交付无签名 IPA／校验文件；[同一次发布流程](https://github.com/JiangNanGenius/floe-agent/actions/runs/39380604459)成功。独立核对标签、源码、实际 arm64 设备包、远端摘要、来源证明、latest 指针及实时订阅全部通过，IPA SHA-256 为 `713e4bd59e3e829536888cb46af156998ac38520b44f5b2d89a5a98a450d72c5`。Stable latest Release and Feather carry the verified unsigned IPA and checksum; independent source, device-binary, digest, attestation and feed checks passed. Installation requires your own signing.
- TestFlight：[仅签名上传](https://github.com/JiangNanGenius/floe-agent/actions/runs/39381021373)成功；[独立只读回查](https://github.com/JiangNanGenius/floe-agent/actions/runs/39382971227)确认 281 为 `VALID`、未过期、`APP_STORE_ELIGIBLE`，现有 Floe QA 为 `IN_BETA_TESTING`，**内部可安装**。Independent readback confirms VALID, unexpired and available in the existing internal Floe QA group.
- 外测：API 在首个审核备注写入处返回 403，未关联或提交；随后通过已登录的 Apple 网页保存定稿备注并向现有 `publictest1` 送审一次。[独立回查](https://github.com/JiangNanGenius/floe-agent/actions/runs/39383590223)确认群组已关联、恰有一条 `pending_review`、`WAITING_FOR_BETA_REVIEW`、备注匹配且 issues 为空。外测等待审核批准，原正式 App Store 提交保持不变。The existing publictest1 group received one web submission after the API refused the first write; readback confirms one pending review and matching notes. External installation awaits approval; the formal App Store submission is unchanged.
- 2026-10-20 [再次只读回查](https://github.com/JiangNanGenius/floe-agent/actions/runs/39399876835)：281 仍为 `VALID`、未过期，`publictest1` 已关联，恰有一条 `pending_review`／`WAITING_FOR_BETA_REVIEW`，审核备注匹配且 issues 为空；保留现有申请，不重复送审。Latest readback confirms one existing pending external review; no duplicate submission was made.
- 本轮 Office 笔点及直接受影响边界共 12 项 App／真实引擎用例通过，0 失败、0 跳过；保留此前实时缩放、手记预览与音乐验收。本次公开 IPA 中原生组件、浏览器和四首音乐与验收产物一致。真实 Pencil 压感、防误触和设备手感继续由用户真机反馈确认。Twelve affected App/native-engine cases passed; prior zoom, Notes-preview and music evidence is retained. Physical Pencil acceptance remains with the user. [修复与验收](releases/repairs/FLOE_OFFICE_PENCIL_S1_20261020.md) · [发布说明](releases/notes/RELEASE_NOTES_1.7.40_BUILD_281.md)。

## 1.7.34（275）内部可用；未提交外部审核 / Internal available; no external submission

- `project.yml` 声明 **1.7.34 (275)**。2026-10-16 由冻结源码 `084ef9087fe50752a4ae2212a097a409cca02fdf`（标签 `v1.7.34`）完成本地 Xcode 27.0（27A266a）Release 归档，复用已核验的本地产物做最小云端签名上传（未重编 App，[运行 38848176447](https://github.com/JiangNanGenius/floe-agent/actions/runs/38848176447)）；独立只读回读 Apple：构建 `a75934ba…` `VALID`、未过期、`APP_STORE_ELIGIBLE`，现有内部 Floe QA 组 `IN_BETA_TESTING`（[38849845297](https://github.com/JiangNanGenius/floe-agent/actions/runs/38849845297)）——**内部可安装**。签名 IPA 已下载并独立校验（sha256 `f817b0f6…`；codesign 深度严格校验通过；内置重建 shell/text UUID 与归档一致；App、扩展与 16 个 framework 均带隐私清单）。
- 本轮完成首轮审核所需隐私清单闭环（App、Screen Share、16 个嵌入 framework；`shell`/`text` 以受审 patch 定向重建移除无理由的 statfs 调用），语言解析改用公开 Locale API，反馈图片字段与服务契约一致，存储文件系统门控改用公开 API。测试：打包隐私测试 20/20、App 宿主语言/存储 31 项与反馈回归 57 项通过；重建模拟器切片的 find/wc/tail 组件宿主冒烟如实记录（`tail -f` 取消不停止为 pinned 与 patched 共有的既有引擎限制）。详见[本地核验与交付记录](releases/testflight/BUILD_275_LOCAL_VERIFICATION.md)与[隐私修复与验证记录](releases/repairs/FLOE_PRIVACY_MANIFESTS_20261016.md)。
- 边界：未加入 publictest1、未提交 App Review、未发布 GitHub/Feather/官网/内容包、未恢复定时任务；正式审核提交、ASC 网页与账户法律动作仍在主协调/用户。实际审核与到期状态以 App Store Connect/TestFlight 为准。

## 1.7.33（274）内部可用；已送 publictest1 等待审核 / Internal available; submitted to publictest1, waiting for Apple review

- `project.yml` 声明 **1.7.33 (274)**。2026-10-15 由冻结源码 `0de810f08639315ba38ff82607e2da1fcf596f26`（标签 `v1.7.33`）完成本地 Xcode 27 归档，复用已核验的本地产物做最小云端签名上传（未重编 App，[运行 38805969523](https://github.com/JiangNanGenius/floe-agent/actions/runs/38805969523)）；独立只读回读 Apple：构建 `320f0efa…` `VALID`、未过期、`APP_STORE_ELIGIBLE`、现有内部 Floe QA 组 `IN_BETA_TESTING`（[38808283515](https://github.com/JiangNanGenius/floe-agent/actions/runs/38808283515)）——**内部可安装**。签名 IPA 已下载并独立校验（sha256 `2d54b5ad…`，codesign 深度严格校验通过，版本/SDK/UUID 与本地归档一致）。
- 该构建随后一次性加入现有外部组 `publictest1` 并只提交一次 Beta 审核（网页完成；[只读回读 38810115700](https://github.com/JiangNanGenius/floe-agent/actions/runs/38810115700)：`WAITING_FOR_BETA_REVIEW`、唯一 `pending_review`、组已关联、issues 为空）。**外部等待 Apple 审核，不能称为已公开可安装**；审核通过是后续独立状态。API 送审路径保持失败关闭：唯一一次尝试在首个 App 级元数据写入处收到 Apple `HTTP 403 FORBIDDEN_ERROR`，无部分写入；发布助手已按规范化文本比较已有审核备注（打包提交 `ba3f5c71`），仅有空白差异时不再尝试该写入。
- 本轮授权：完成质量门后新版本**可提交现有 publictest1 公测**，已执行；1.7.28（269）仍仅内部，不提升。更早记录（273、271 等）为本页历史，实际审核/到期状态以 App Store Connect/TestFlight 为准。详见[本地核验与交付记录](releases/testflight/BUILD_274_LOCAL_VERIFICATION.md)与[发布说明](releases/notes/RELEASE_NOTES_1.7.33_BUILD_274.md)。

## 1.7.32（273）内部交付（历史）/ Internal delivery (historical)

- `project.yml` 声明 **1.7.32 (273)**。2026-10-15 由冻结源码 `29937dc025267bacd89434cc092b3906c99b93ee`（标签 `v1.7.32`）完成本地 Xcode 27 归档，复用本地产物签名上传（未重编 App），独立回读 Apple `VALID`、未过期、现有内部 Floe QA 组 `IN_BETA_TESTING`；未提交 publictest1、未外审、未对外发布。详见[发布说明](releases/notes/RELEASE_NOTES_1.7.32_BUILD_273.md)与[273 修复记录](releases/repairs/FLOE_273_TEMPORARY_SUBAGENT_REPAIR.md)。Build 273 is the previous internal Floe QA build; no external submission or publication was performed.

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
