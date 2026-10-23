# Floe Agent 1.7.49（290）交付记录

冻结源码 `fb0b76261950dfa76f67022e7200996badecf4d9`；不可变标签 `v1.7.49`，标签对象 `080d70b174a801d17247082a67bb891f72c9b19f`。App 与四个扩展均为 1.7.49（290）。

## 功能与验证

本轮仅完成后台位置短修复：首次前台授权、共享位置生命周期、任务按需调用位置／天气链路，以及授权、取消、超时和迟到回调保护。位置支持随已有后台功能启停，不新增独立开关；完成任务后释放，不保存位置轨迹。未扩大为全 App 审计。

[资格记录](../../FLOE_LOCATION_SHORTFIX_20261023.md)区分受控测试和实际设备效果。Xcode 27.1（27A9275）／SDK 27.1 的完整 Swift 6 App／测试对象编译通过，五组 80 项定向测试全部通过，0 失败、0 跳过、0 缺失。原首轮 78 通过／1 失败保留；修正的是端口转发测试替身对历史调用与当前映射的混淆，原精确断言未削弱，生产端口转发未改。

既有 iPad 模拟器显示首次中文位置授权、后台执行页的位置状态及不重复授权的重启行为，原草稿与附件保留。UI 对应代码与最终候选一致。未使用实体手机，不宣称真实 GPS、后台持续时长、在线天气服务或 Apple 审核通过。

资格源码 `b2b26eba` 至冻结源码仅增加资格文档；本地 Release 设备归档成功后立即保存原 App、标准传输包及 14 份 DWARF 符号。五个 Bundle、版本、原生组件、摘要、来源与恢复 ZIP 全量 CRC 检查通过；云端只签名／打包，没有重编 App。

## 分发状态

[签名上传 39928706037](https://github.com/JiangNanGenius/floe-agent/actions/runs/39928706037)已获上传回执，Apple 网页显示正在处理。内部 Floe QA、公开 TestFlight、稳定无签名 Release 与 Feather 仍待独立回读；不把上传成功写作可安装。

Internal availability, external submission and unsigned publication are separate gates. Upload transport is accepted; installability is not yet asserted. The formal App Store submission is unchanged.

## 合并与清理

源码通过 `fb1616b6` 合并并推送 main，保留并行 Android 工作；本轮分支已在确认合并、无人占用后从本地及远端删除，发布标签未移动。

完成的模拟器缓存、发行编译缓存、展开 App／归档和传输暂存已清理。压缩恢复包、14 份符号、实际上传 IPA、来源和成功／失败证据保留；共享依赖有明确复用用途。最终渠道回读与私有传输删除记录将在分发完成后补齐。
