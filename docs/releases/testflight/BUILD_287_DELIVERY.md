# Floe Agent 1.7.46（287）交付记录

冻结源码：`f6c1272e9b98f252414a509b282f6c6c3a4a3bc2`；标签 `v1.7.46`，标签对象 `8176c66f5be20b7f0cb667551df23bc1e6f948ea`。App 与四个扩展均为 1.7.46（287），本地 Xcode 27.1（27A9275）／iPhoneOS SDK 27.1 归档。

## 本地资格与产物

[本地资格记录](BUILD_287_LOCAL_VERIFICATION.md)保留分项结果：实际 PDF 自动预览、网格线与精确缩放、阅读模式后的保存、手记修订和笔迹封面更新、取消后的最终状态。原始失败与修正后的结果分别保留；未重复未改变的整套矩阵，也未把模拟器写成真实打印机或折叠屏验收。

归档成功后立即保存设备产物和符号，再校验五个 Bundle、App Intents、快捷指令模板、隐私清单、原生组件 UUID 与包摘要。后续签名和无签名发布复用这份本地产物，没有云端 App 重编译。

## 分发

| 渠道 | 已核验结果 |
| --- | --- |
| 内部 TestFlight | Apple `VALID`、未过期、Floe QA `IN_BETA_TESTING`；[签名与内部验证](https://github.com/JiangNanGenius/floe-agent/actions/runs/39741443738)、[独立只读回查](https://github.com/JiangNanGenius/floe-agent/actions/runs/39743949986) |
| 公开 TestFlight | 已向现有 `publictest1` 提交一次；Apple 为 `pending_review`／`WAITING_FOR_BETA_REVIEW`，仍等待审核，不代表外部已可安装；[最终回查](https://github.com/JiangNanGenius/floe-agent/actions/runs/39744965674)确认完整审核备注一致 |
| GitHub | [稳定且 latest 的 v1.7.46](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.7.46)，含无签名 IPA、`.sha256` 及最小 `PROVENANCE.json`；独立检查了标签对象、源码、远端摘要和下载后的实际 arm64 iOS 设备可执行文件 |
| Feather | [同次发布流程](https://github.com/JiangNanGenius/floe-agent/actions/runs/39744068547)等待 Feather 下游结束；[公开订阅源](https://raw.githubusercontent.com/JiangNanGenius/floe-agent/main/feather.json)的最新版本、安装包地址、大小、源码和摘要均已读回一致 |

无签名 IPA：`Floe-Agent-1.7.46-build287-unsigned.ipa`，809,633,905 字节；SHA-256：`45d777861e1a5fbf2632eda2d52114a09955f5039e5bff4dc7654a86d3c77ae7`。

## 合并与清理

源码已通过 [PR 17](https://github.com/JiangNanGenius/floe-agent/pull/17)合并 main。云端预检测试因夹具缺少辅助脚本及三个输入而失败；补齐夹具后本地 19 项通过、0 失败、0 跳过。该修正仅改测试文件，冻结 App、版本、标签和产物均不变。

已移除本轮完成后的模拟器构建缓存、设备构建缓存、重复生成的 App 和归档副本，保留已校验设备包、符号、原始失败证据及必要回滚。两个分发消费者均完成后，已删除临时私有传输 Release／标签；公开标签保持不变。

正式 App Store 提交及历史构建保留各自原状态；本次未自动发布正式 App、部署网站或恢复外部定时器。

