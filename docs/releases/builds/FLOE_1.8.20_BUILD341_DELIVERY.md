# Floe Agent 1.8.20（341）交付记录

2026-11-13 完成内部交付。冻结源码为 `d0c085f9ddda28e1d9a125389a020f618892d408`，不可变标签为 `v1.8.20`，annotated tag object 为 `cd117dc6150827a71c4fd124d2830cfde490f5ce`。

本次包含旧环境多批恢复记录接续、遗漏迁移盘的无损整理入口、同次录音的持久分组与连续回放、素材及录音按钮布局，以及目标模式使用“引导”发送时的原生目标保存和输入模式复位。录音原片保留；连续回放不等于另生成一份合并导出的音频文件。

## 实际交付

| 渠道 | 核验结果 |
| --- | --- |
| 内部 TestFlight | Apple `VALID`、未过期，既有 Floe QA 为 `IN_BETA_TESTING`；另一个只读核验任务独立确认 |
| GitHub | normal unsigned producer、attestation及严格发布读回通过；stable/latest为 `v1.8.20` |
| Feather | normal发布流程实际等待feed任务成功；在线当前条目及旧客户端头部与341的源码、摘要、大小和下载地址一致 |
| 提供的M4 iPad | 经TestFlight实际更新到1.8.20（341），独立安装信息和实际首次启动界面均确认 |

签名上传使用[原产物签名任务](https://github.com/JiangNanGenius/floe-agent/actions/runs/43412518939)，没有重新编译App。[正常发布任务](https://github.com/JiangNanGenius/floe-agent/actions/runs/43416301156)完成unsigned发布及awaited Feather。

[公开unsigned安装包](https://github.com/JiangNanGenius/floe-agent/releases/download/v1.8.20/Floe-Agent-1.8.20-build341-unsigned.ipa)为918,213,318字节，SHA-256为 `37ebb2bb108ad016eff97008047b0fd43a0f2ca7e0e8c79b9d4a7f752ef31794`。公开文件实际下载并通过严格校验。

## 构建与验证边界

使用本机Xcode 27.2（27B52）及iOS SDK 27.2（24B8118）。实际App对象编译、链接和Release归档通过；App及19份符号在后续分发前保存。实际设备归档包含一次相关C源编译，原生对象证据已绑定。签名安装包的版本、工具链、App UUID、现有Wi-Fi授权及production推送配置均从实际产物核验。

实际通过31个不同的相关方法：录音8、迁移盘8、恢复2、历史接续4、Goal 9。沿用18项源码未变的成功证据，并对受影响13项完成实际复测；原中断轮次及5个失败保留，未把该轮整体改记为通过。完整App启动和横屏首页已观察；Goal引导和录音素材的完整设备交互、麦克风及说话人质量未在本次记为通过。

首次上传在远端源标签尚未推送时被前置校验拒绝，尚未创建transport；推送并读回不可变源码／标签后复用同一个已核验安装包完成上传，没有重建或重复上传Apple版本。

## 容量问题尚未完成

341的M4实测中，整理前App显示约208.14GB文件占用估算。维护注册已成功，识别两批历史、两项未完作业，并取得原生维护闭包；随后恢复校验以 `identity-changed`／`handler_unresolved` 停止。本次唯一一次手动整理结果为 `blocked`／`recovery-pending`，0项优化、0文件分配减少，不能记作回收成功。

新的有界小型恢复记录已取回继续调查。现有证据不足以断言是哪一项文件属性变化；不以改写旧摘要或放宽身份校验恢复执行。全部原盘、资料、软件和恢复分支保留，338此前已回收的约124.85GB不重复计算。遗漏迁移盘的净可回收量和设备最终占用仍未验收。

已按用户需要归还iPad，确认停止屏幕共享并关闭键盘捕获。未使用用户的物理iPhone。

本次未提交公开TestFlight或正式App Store。已撤回331及原315安排保持，340和既有不可变标签不改写。后续容量修复另用新版本，不替换本次产物或回执。
