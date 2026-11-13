<!-- docs-updated: 2026-11-14 -->
# iOS 发布版本依据

本文是 iOS／iPadOS 下一版版本选择的唯一维护入口；各渠道实际交付状态见[当前状态](CURRENT_STATUS.md)与[逐版交付记录](releases/README.md)。Android 版本独立管理。

**最近已核验交付为1.8.22（343）：内部TestFlight可安装，正常GitHub stable/latest及awaited Feather严格实际读回通过。** 冻结源 `53c3b83625ec5f8e94690ae15f5a0f3881f85589`／`v1.8.22`，见[343交付记录](releases/builds/FLOE_1.8.22_BUILD343_DELIVERY.md)。真实Darwin组件6方法及完整iOS归档、规范封装通过；M4已实际安装，启动识别修复已确认，但一次整理仍受旧作业原盘ctime检查阻断，新增回收0。208.31GB只是整理前文件分配估算，原盘、资料与13份恢复盘保留。未提交公开TestFlight或正式App Store，315／331安排保持。

## 依据与判定

读取顺序为：最新用户指令 → 本文记录的版本决定 → 各渠道真实读回。用户后续明确指令优先；各渠道是否交付始终须由该渠道读回确认，文档不能替代实际状态。

标签、源提交、候选目录、版本说明、构建／归档成功和签名流程启动，都不能单独证明上传、审核通过或可安装。不得从最高标签自动推算下一版，也不得把未交付尝试称为上一已交付版本。

## 本轮版本记录

**1.8.23（344）正在准备。** 本次Apple只读清点确认版本及构建未占用。仅修复S63：限定在保留原盘、结束旧作业的恢复路径，完整核对旧SHA-512并持续校验当前文件身份与持锁状态，再允许重新整理。真实Darwin编译／链接及8项定向方法通过（首次7项通过、1项夹具断言修正后单独通过，原失败保留）；完整App归档、渠道交付和M4实际回收尚未验证。343源与产物保持不变。

**1.8.22（343）已交付三条授权渠道。** [独立Apple GET](https://github.com/JiangNanGenius/floe-agent/actions/runs/43483085373)确认VALID、未过期及Floe QA内部可安装；[正常发布及awaited Feather](https://github.com/JiangNanGenius/floe-agent/actions/runs/43483448749)和实际安装包／在线源严格读回通过。M4经真实TestFlight更新，bootstrap成功接续两批历史、两项未完作业；唯一一次整理为blocked／recovery-pending，明确原盘ctime检查拒绝、尝试0项／分配减少0。原source、摘要、资料和恢复盘保留。后续修复另用未占用版本，不改343源、标签或产物，不把内容摘要存在等同当前盘已验证。

**1.8.21（342）已交付三条授权渠道。** Apple独立GET确认VALID、未过期、既有Floe QA为IN_BETA_TESTING；GitHub stable/latest实际IPA及在线Feather源严格匹配。实际macOS-Darwin生产组件编译／链接与6新＋2既有恢复方法共8项通过，跳过0；完整iOS Release归档和规范封装通过，App及19份符号已保全。342在M4实测启动历史识别受阻，未开始新的整理；208.22GB为界面文件分配估算，新增回收0。该启动问题在343实际修复，后续容量阻塞仍单独保留，不改342冻结来源和失败记录。

**1.8.20（341）已交付三条授权渠道。** Apple独立GET为VALID、未过期、Floe QA可安装；GitHub stable/latest及awaited Feather严格读回通过，M4已安装。31项相关方法通过不等于容量真机验收：一次实际整理为blocked／recovery-pending，收益0，后续恢复窄修进入342源码候选。341源、标签和产物保持不变。

**1.8.19（340）已交付三条授权渠道。** 实际App编译／6项App恢复方法与2项独立Core方法通过，真实设备归档与规范封装通过；Apple独立GET及实际signed／unsigned包、GitHub／Feather均匹配。M4已安装，但两批历史尚未安全统一恢复，旧339进度不能当340新结果；当前仅完成渠道交付，不称容量全量结项。后续不改340源、标签或安装包，下一版继续磁盘优先并行录音修复。

**1.8.18（339）已完成内部TestFlight、正常GitHub及Feather交付。** 实际App对象编译、14项定向行为、设备归档及规范封装通过；Apple独立GET确认有效、未过期且内部组可安装。M4原文件回执已实际验证，仅显示两个真实入口，TXT／HTML完整阅读通过。安装后实际数据目录UUID改变，新空authority目录未接续旧记录，后续窄修继续处理；不得写成容量整理全部完成。保留339原源、标签、产物和原始失败，不提交公开或正式App Store。

**1.8.16（337）已交付内部TestFlight、正常GitHub及Feather渠道。** 336实测暴露的换机后Linux清理绑定、来源恢复、进度和储存清点问题已纳入337修复，并追加计划卡、全文预览及工具发现修复。2026-11-13悉尼时间独立读回Apple `VALID`、未过期、Floe QA `IN_BETA_TESTING`，公开安装包及实时Feather源均匹配冻结来源。此前334的冻结预检失败及335的扩展隐私清单缺项保留；旧标签和原始失败不改。旧Linux资料和恢复盘保留，未声称用户iPad已释放容量。337不提交公开TestFlight，下一公开候选另行安排；正式上架由用户看过后在另一线程处理。

| 版本／构建 | 已确认状态 | 交付边界 |
| --- | --- | --- |
| 1.8.6（326） | 此前已交付基线：GitHub、Feather 与内部 TestFlight | 保留原始交付记录；GitHub 未签名 IPA 需自行签名，公开 TestFlight 状态须独立核实。 |
| 1.9.0（327），标签 `v1.9.0` | 本地归档成功；正常封装因隐私校验被拒，未上传 | 保留为未交付尝试，不作为可安装版本或下一版号依据。 |
| 1.9.1（328），标签 `v1.9.1` | 归档与正常封装成功，签名流程已发起；按用户更正不再继续后续分发 | 签名作业已确认取消；Apple 接收与可安装状态尚未确认，不计为已交付。 |
| 1.8.7（329），标签 `v1.8.7` | 此前内部 TestFlight 可安装；交付时 GitHub stable/latest 与 Feather 已核验；公开 TestFlight 当时等待审核 | 冻结源 `1f7fa8889a8e7bac26e4484ae2aafac5c54c51c0`。原独立读回为 Apple `VALID`、未过期，Floe QA `IN_BETA_TESTING`；publictest1 一次 `pending_review`／`WAITING_FOR_BETA_REVIEW`，本次未刷新其审核状态。详见[329交付记录](releases/builds/FLOE_1.8.7_BUILD329_DELIVERY.md)。 |
| 1.8.8（330），标签 `v1.8.8` | 内部 TestFlight 可安装；GitHub stable/latest 与 awaited Feather 已交付；未提交公开 TestFlight | 冻结源 `b5bf026b16e734a6a1923c2416a687ee274fce41`，标签对象 `6d661c7af6f946b8dc82bb1e6eee8704b4281289`。独立 Apple GET 为 `VALID`、未过期、Floe QA `IN_BETA_TESTING`；公开包与实时 feed 严格读回通过。不含新增 Linux 视频硬件解码。详见[330交付记录](releases/builds/FLOE_1.8.8_BUILD330_DELIVERY.md)。 |
| 1.8.9（331），标签 `v1.8.9` | 内部TestFlight可安装；GitHub／Feather已交付；公开组和审核已撤回 | 冻结源 `8dcf7c38f77d43a76575e10f96be72807c1c6f47`。撤回后的独立GET为 `VALID`、未过期、Floe QA `IN_BETA_TESTING`；外部 `READY_FOR_BETA_SUBMISSION`、无审核提交／独立测试员。用户要求重点修好后发布新公测，不再续推331；315不动。 |
| 1.8.10（332），标签 `v1.8.10` | 内部TestFlight可安装；GitHub stable/latest及awaited Feather已核验；公开审核保留待审快照 | 冻结源 `22f8c31e7cbe86febe150c24284d9fd2fdf50ee8`，标签对象 `9510c947b92534a3ad1e53bac1d9e3d8b49f6ab0`。交付时独立读回 Apple `VALID`、未过期、Floe QA `IN_BETA_TESTING`；publictest1仅提交一次，2026-11-11 `WAITING_FOR_BETA_REVIEW`，未刷新其当前审核状态。详见[332交付记录](releases/builds/FLOE_1.8.10_BUILD332_DELIVERY.md)。 |
| 1.8.11（333），标签 `v1.8.11` | 内部TestFlight可安装；GitHub stable/latest及awaited Feather已核验；不提交公开TestFlight | 冻结源 `d797b5ebb28cd91c1a83fe07f0fc42d57fd3076c`。交付时独立Apple GET为 `VALID`、未过期、Floe QA `IN_BETA_TESTING`；原安装包及符号保留。用户要求容量／QA修复放到下一版，不改333产物。 |
| 1.8.12（334），本地标签 `v1.8.12` | 未交付的本地预检尝试；许可证源代码提供说明仍指上一版，预检失败；未推送该标签、未归档／上传 | 保留源 `885f6e79e47b7fc8be2bc8b6d99641d26134eb4b` 和原标签，不替换为其他来源。 |
| 1.8.13（334），本地标签 `v1.8.13` | 未交付的本地预检尝试；许可证说明已补齐，但构建号未大于前序本地334标签，预检失败；未推送该标签、未归档／上传 | 保留源 `a6bce8a6e62f8f6a94ced4f246084f8d826484eb` 和原标签，不重写失败记录。 |
| 1.8.14（335） | 实际设备归档成功，原App及19份符号已保留；规范打包发现四个扩展缺少磁盘空间检查声明，未上传 | 原标签、源提交、归档证据和打包失败保留；不改写成已交付版本。 |
| 1.8.15（336） | 实际归档、规范打包、签名上传通过；Apple独立读回VALID、未过期、Floe QA内部可安装 | 冻结源 `166323e263ac1843016b2b82f2212407b795f7ef`／`v1.8.15`不改。原分组API422失败保留，后续独立读回内部权限已生效；无外部组、无公开审核提交。用户要求修清理问题后以新构建替代，GitHub／Feather后续渠道暂缓，不将其写成已完成。 |
| 1.8.16（337），标签 `v1.8.16` | 实际App编译、定向行为、Simulator流程、设备归档及规范打包通过；内部TestFlight可安装，GitHub stable/latest及awaited Feather严格读回通过 | 冻结源 `91c7cd935387f6d88bba2d660b282fb3a8dfa9bb`。独立Apple GET为 `VALID`、未过期、Floe QA `IN_BETA_TESTING`；未提交公开TestFlight。换机真机恢复／容量回收尚待验，315与331安排不变。详见[337交付记录](releases/builds/FLOE_1.8.16_BUILD337_DELIVERY.md)。 |
| 1.8.17（338），标签 `v1.8.17` | 内部TestFlight可安装，GitHub stable/latest与awaited Feather严格读回通过；M4已通过TestFlight安装 | 冻结源 `67d30edb3bcfc9fa674f2762f096de533e13b427`。独立Apple GET为 `VALID`、未过期、Floe QA `IN_BETA_TESTING`；未提交公开TestFlight。M4回放及新TXT／HTML原生阅读已验，实际回收124.85GB但整理未全部收束，339继续修。详见[338交付记录](releases/builds/FLOE_1.8.17_BUILD338_DELIVERY.md)。 |
| 1.8.18（339），标签 `v1.8.18` | 内部TestFlight可安装，正常GitHub stable/latest与awaited Feather严格读回通过；M4实际已更新 | 冻结源 `b1c062d75ffe07603a698e048109776a2d4707ba`。文件快捷入口和TXT／HTML完整阅读已验；升级导致数据目录地址变化的剩余恢复缺口继续修，不把既有回收量重复算为339收益。详见[339交付记录](releases/builds/FLOE_1.8.18_BUILD339_DELIVERY.md)。 |
| 1.8.19（340），标签 `v1.8.19` | 内部TestFlight可安装，正常GitHub stable/latest与awaited Feather严格读回通过，M4已装 | 冻结源 `ca7e39303404a3f6806006300165b248ad0cd967`。剩余多历史／迁移盘恢复尚未完成，不重复计算旧回收；录音素材和连续回放并行准备下一版。见[340交付记录](releases/builds/FLOE_1.8.19_BUILD340_DELIVERY.md)。 |
| 1.8.20（341），标签 `v1.8.20` | 内部TestFlight可安装，正常GitHub stable/latest与awaited Feather严格读回通过，M4已装并交还 | 冻结源 `d0c085f9ddda28e1d9a125389a020f618892d408`。容量实测blocked／recovery-pending，本次0优化、0文件分配减少；不重复计入旧回收量。见[341交付记录](releases/builds/FLOE_1.8.20_BUILD341_DELIVERY.md)。 |
| 1.8.21（342），标签 `v1.8.21` | 内部TestFlight可安装，正常GitHub stable/latest及awaited Feather严格读回通过 | 冻结源 `1d599f35e97b46ea5798ac07359074480fa463a5`。真实组件8方法与完整iOS归档通过；M4实测启动历史识别受阻，未开始新整理，仍保留资料与13份恢复盘。见[342交付记录](releases/builds/FLOE_1.8.21_BUILD342_DELIVERY.md)。 |
| 1.8.22（343），标签 `v1.8.22` | 内部TestFlight可安装，正常GitHub stable/latest及awaited Feather严格读回通过，M4已实际更新 | 冻结源 `53c3b83625ec5f8e94690ae15f5a0f3881f85589`。启动识别已修复；一次整理明确被旧原盘ctime检查阻断，新增回收0，容量继续修复。见[343交付记录](releases/builds/FLOE_1.8.22_BUILD343_DELIVERY.md)。 |

正式 App Store 构建 315 及其既有安排保持不变；本轮版本纠正不授权替换它。

新版本交付后，按对应渠道真实结果更新本文和[当前状态](CURRENT_STATUS.md)。保留历史标签、版本说明、归档与原始失败记录；后续证据另行追加，不移动旧标签或把旧产物改标成新版本。
