<!-- docs-updated: 2026-11-12 -->
# iOS 发布版本依据

本文是 iOS／iPadOS 下一版版本选择的唯一维护入口；各渠道实际交付状态见[当前状态](CURRENT_STATUS.md)与[逐版交付记录](releases/README.md)。Android 版本独立管理。

**最近已核验交付为1.8.10（332）：内部TestFlight可安装，GitHub stable/latest与awaited Feather独立读回通过。** 冻结源 `22f8c31e7cbe86febe150c24284d9fd2fdf50ee8`／`v1.8.10`，详见[332交付记录](releases/builds/FLOE_1.8.10_BUILD332_DELIVERY.md)。公开publictest1已提交一次，2026-11-11保留读回为 `WAITING_FOR_BETA_REVIEW`／`pending_review`；此处未刷新审核状态，不称公开可安装。331的外部访问和审核保持撤回，315既有安排不动；后续源码修复不属于332的不可变安装包。GPU／新增Linux加速继续独立研发，当前稳定小修不以它为交付门；不得从未交付的较高标签推算版号。

## 依据与判定

读取顺序为：最新用户指令 → 本文记录的版本决定 → 各渠道真实读回。用户后续明确指令优先；各渠道是否交付始终须由该渠道读回确认，文档不能替代实际状态。

标签、源提交、候选目录、版本说明、构建／归档成功和签名流程启动，都不能单独证明上传、审核通过或可安装。不得从最高标签自动推算下一版，也不得把未交付尝试称为上一已交付版本。

## 本轮版本记录

下一稳定小修候选拟用 **1.8.11（333）**：2026-11-12悉尼时间的只读 Apple 全页构建／上传核对均未占用；这是当时快照，不是远端预留。主 App 与四个扩展的源码版本已一致，当前仍待工程生成、编译、验收、冻结和分发，不称已交付。正式上架由用户看过后在另一线程处理。

| 版本／构建 | 已确认状态 | 交付边界 |
| --- | --- | --- |
| 1.8.6（326） | 此前已交付基线：GitHub、Feather 与内部 TestFlight | 保留原始交付记录；GitHub 未签名 IPA 需自行签名，公开 TestFlight 状态须独立核实。 |
| 1.9.0（327），标签 `v1.9.0` | 本地归档成功；正常封装因隐私校验被拒，未上传 | 保留为未交付尝试，不作为可安装版本或下一版号依据。 |
| 1.9.1（328），标签 `v1.9.1` | 归档与正常封装成功，签名流程已发起；按用户更正不再继续后续分发 | 签名作业已确认取消；Apple 接收与可安装状态尚未确认，不计为已交付。 |
| 1.8.7（329），标签 `v1.8.7` | 此前内部 TestFlight 可安装；交付时 GitHub stable/latest 与 Feather 已核验；公开 TestFlight 当时等待审核 | 冻结源 `1f7fa8889a8e7bac26e4484ae2aafac5c54c51c0`。原独立读回为 Apple `VALID`、未过期，Floe QA `IN_BETA_TESTING`；publictest1 一次 `pending_review`／`WAITING_FOR_BETA_REVIEW`，本次未刷新其审核状态。详见[329交付记录](releases/builds/FLOE_1.8.7_BUILD329_DELIVERY.md)。 |
| 1.8.8（330），标签 `v1.8.8` | 内部 TestFlight 可安装；GitHub stable/latest 与 awaited Feather 已交付；未提交公开 TestFlight | 冻结源 `b5bf026b16e734a6a1923c2416a687ee274fce41`，标签对象 `6d661c7af6f946b8dc82bb1e6eee8704b4281289`。独立 Apple GET 为 `VALID`、未过期、Floe QA `IN_BETA_TESTING`；公开包与实时 feed 严格读回通过。不含新增 Linux 视频硬件解码。详见[330交付记录](releases/builds/FLOE_1.8.8_BUILD330_DELIVERY.md)。 |
| 1.8.9（331），标签 `v1.8.9` | 内部TestFlight可安装；GitHub／Feather已交付；公开组和审核已撤回 | 冻结源 `8dcf7c38f77d43a76575e10f96be72807c1c6f47`。撤回后的独立GET为 `VALID`、未过期、Floe QA `IN_BETA_TESTING`；外部 `READY_FOR_BETA_SUBMISSION`、无审核提交／独立测试员。用户要求重点修好后发布新公测，不再续推331；315不动。 |
| 1.8.10（332），标签 `v1.8.10` | 内部TestFlight可安装；GitHub stable/latest及awaited Feather已核验；公开审核保留待审快照 | 冻结源 `22f8c31e7cbe86febe150c24284d9fd2fdf50ee8`，标签对象 `9510c947b92534a3ad1e53bac1d9e3d8b49f6ab0`。交付时独立读回 Apple `VALID`、未过期、Floe QA `IN_BETA_TESTING`；publictest1仅提交一次，2026-11-11 `WAITING_FOR_BETA_REVIEW`，未刷新其当前审核状态。详见[332交付记录](releases/builds/FLOE_1.8.10_BUILD332_DELIVERY.md)。 |

正式 App Store 构建 315 及其既有安排保持不变；本轮版本纠正不授权替换它。

新版本交付后，按对应渠道真实结果更新本文和[当前状态](CURRENT_STATUS.md)。保留历史标签、版本说明、归档与原始失败记录；后续证据另行追加，不移动旧标签或把旧产物改标成新版本。
