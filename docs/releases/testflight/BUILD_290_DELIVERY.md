# Floe Agent 1.7.49（290）交付记录

冻结源码 `fb0b76261950dfa76f67022e7200996badecf4d9`；不可变标签 `v1.7.49`，标签对象 `080d70b174a801d17247082a67bb891f72c9b19f`。App 与四个扩展均为 1.7.49（290）。

## 功能与验证

本轮仅完成后台位置短修复：首次前台授权、共享位置生命周期、任务按需调用位置／天气链路，以及授权、取消、超时和迟到回调保护。位置支持随已有后台功能启停，不新增独立开关；完成任务后释放，不保存位置轨迹。未扩大为全 App 审计。

[资格记录](../../FLOE_LOCATION_SHORTFIX_20261023.md)区分受控测试和实际设备效果。Xcode 27.1（27A9275）／SDK 27.1 的完整 Swift 6 App／测试对象编译通过，五组 80 项定向测试全部通过，0 失败、0 跳过、0 缺失。原首轮 78 通过／1 失败保留；修正的是端口转发测试替身对历史调用与当前映射的混淆，原精确断言未削弱，生产端口转发未改。

既有 iPad 模拟器显示首次中文位置授权、后台执行页的位置状态及不重复授权的重启行为，原草稿与附件保留。UI 对应代码与最终候选一致。未使用实体手机，不宣称真实 GPS、后台持续时长、在线天气服务或 Apple 审核通过。

资格源码 `b2b26eba` 至冻结源码仅增加资格文档；本地 Release 设备归档成功后立即保存原 App、标准传输包及 14 份 DWARF 符号。五个 Bundle、版本、原生组件、摘要、来源与恢复 ZIP 全量 CRC 检查通过；云端只签名／打包，没有重编 App。

## 分发状态

| 渠道 | 独立核验结果 |
| --- | --- |
| 内部 TestFlight | [签名上传](https://github.com/JiangNanGenius/floe-agent/actions/runs/39928706037)及[独立只读核验](https://github.com/JiangNanGenius/floe-agent/actions/runs/39931005241)成功：`VALID`、未过期、`APP_STORE_ELIGIBLE`、Floe QA `IN_BETA_TESTING`。内部可安装 |
| 公开 TestFlight | Safari 向既有 publictest1 提交一次；[提交后 GET-only 核验](https://github.com/JiangNanGenius/floe-agent/actions/runs/39931436458)确认群组已关联、`WAITING_FOR_BETA_REVIEW`、恰好一条 `pending_review`、双语说明及审核备注一致、issues 为空。外部可安装仍待 Apple 批准 |
| GitHub | [v1.7.49 稳定且 latest Release](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.7.49)，仅无签名 IPA、校验及最小来源文件；实际下载后验证源码／标签、大小、SHA-256、五个 Bundle 身份及真实 arm64 iPhoneOS 可执行文件 |
| Feather | [同次发布流程](https://github.com/JiangNanGenius/floe-agent/actions/runs/39930974198)及 awaited Feather 下游成功；[在线订阅](https://raw.githubusercontent.com/JiangNanGenius/floe-agent/main/feather.json)的当前版本、来源、下载 URL、大小与摘要和实际 Release 完全匹配 |

公开无签名 IPA 为 `Floe-Agent-1.7.49-build290-unsigned.ipa`，811,890,711 字节，SHA-256 `c3df076730556513994c68d40bee87a687a0958d720c9c40dad24506d78ef625`。无签名包需自行签名；内部可安装、公开送审与外部可安装分别记录，不宣称审核已批准。现有正式 App Store 提交未变。

Internal TestFlight is installable. The stable unsigned Release and live Feather feed are independently verified. Publictest1 has one submission waiting for Beta Review; external installability still requires Apple approval. The formal App Store submission is unchanged.

## 合并与清理

源码通过 `fb1616b6` 合并并推送 main，保留并行 Android 工作；本轮分支已在确认合并、无人占用后从本地及远端删除，发布标签未移动。

完成的模拟器缓存、发行编译缓存、展开 App／归档和传输暂存已清理。压缩恢复包、14 份符号、实际上传 IPA、来源和成功／失败证据保留；共享依赖有明确复用用途。两个分发消费者成功后，私有传输草稿已删除并独立回读 404；公开 Release 与不可变标签再次确认未变。


各清理边界观测的可用空间增量：模拟器缓存 6,804,406,272 字节，发行编译缓存 3,593,101,312 字节；外置卷归档／App 重复副本及传输暂存分别 1,372,160、2,117,632、2,000,076,800 字节。APFS 名义分配量不等于实测回收量；保留项均有当前分发、恢复或增量依赖用途。

最终没有启动中的模拟器，也没有 Device Hub、QuickTime 或 iPhone Mirroring 进程。本轮仅复用既有 iPad 模拟器；没有创建、克隆、重置或删除模拟器，未触及用户手机。GitHub 原只读日志下载发生 HTTP/2 stream CANCEL，原错误保留；改用 HTTP/1 下载同一已完成运行的日志成功，没有修改测试、TLS 或发布校验。
