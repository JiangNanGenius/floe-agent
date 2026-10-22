# Floe Agent 1.7.47（288）交付记录

冻结源码：`aaa262c541dad1483166dfafb9aae536a6f7019a`；不可变标签 `v1.7.47`，标签对象 `288f1c000968508464e615df6cfee3dc56c4f633`。App 与四个扩展均为 1.7.47（288），本地 Xcode 27.1（27A9275）／iPhoneOS SDK 27.1 归档。

## 功能与资格

本轮交付聊天模式、思考强度选择、连续语音与打断、最终正文朗读、语音输入首次启动恢复、九种音色和实时多语言试听、独立在线语音服务，以及按需添加和更新的搜索供应商目录。普通界面使用“增强语音识别”和“增强语音模型”；来源与许可证详情保留准确原名。

[资格记录](../../qualification/FLOE_CHAT_VOICE_SEARCH_20261023.md)保留实际证据和边界：207 项 App-hosted 测试全部通过，0 失败、0 跳过；完整设备目标编译、实际 iPad 模拟器常规与紧凑布局检查通过。端侧合成的 39 份实际音频来自 Mac 原生宿主，不冒充 iPad 真机结果；本轮未使用真实付费服务密钥进行在线验收。原始失败与修复后的成功记录分别保留。

资格源码 `49b76bfccf7dddc0061f3e77377d6437a6ff1444` 到冻结源码仅增加资格文档和索引。归档后立即保存设备产物及符号，再检查五个 Bundle、App Intents、快捷指令模板、隐私清单、原生组件和摘要。签名与发布复用同一份本地产物，没有云端重编译 App。

## 分发

| 渠道 | 已核验结果 |
| --- | --- |
| 内部 TestFlight | Apple `VALID`、未过期、Floe QA `IN_BETA_TESTING`；[签名上传](https://github.com/JiangNanGenius/floe-agent/actions/runs/39819660622)与[独立只读核验](https://github.com/JiangNanGenius/floe-agent/actions/runs/39823311446)均成功，内部可安装 |
| 公开 TestFlight | 尚未提交。[API 尝试](https://github.com/JiangNanGenius/floe-agent/actions/runs/39823446188)在写入审核说明时返回 `403 FORBIDDEN_ERROR`；[随后只读回查](https://github.com/JiangNanGenius/floe-agent/actions/runs/39823605120)确认 `READY_FOR_BETA_SUBMISSION`、提交数 0、未附加 publictest1。Safari 已用已保存账户恢复到 Apple 双重认证，待完成认证后继续网页送审 |
| GitHub | [稳定且 latest 的 v1.7.47](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.7.47)，仅无签名 IPA、`.sha256` 与最小 `PROVENANCE.json`。下载后独立验证了摘要、标签源码、真实 arm64 iOS 设备可执行文件和版本 |
| Feather | [同次发布流程](https://github.com/JiangNanGenius/floe-agent/actions/runs/39823267025)及 Feather 下游均成功结束；[公开订阅源](https://raw.githubusercontent.com/JiangNanGenius/floe-agent/main/feather.json)的下载地址、版本、大小、源码和 SHA-256 均已读回一致 |

无签名 IPA：`Floe-Agent-1.7.47-build288-unsigned.ipa`，811,530,577 字节；SHA-256：`abd685b0e49adbd459c7faa26fbe65eeaf1d64c04e928a002a6516a7a083682a`。

Internal TestFlight is installable. The stable unsigned GitHub Release and Feather feed are verified. External TestFlight has **not** been submitted: the API metadata write returned 403, and the web path awaits Apple two-factor authentication. Neither external approval nor a production App Store release is claimed.

## 合并与清理

本轮源码通过合并提交 `efcc3a7607ece375ce5f6a3f14b704ab8655cb1c` 推送 main，保留并行 Android 改动；[PR 19](https://github.com/JiangNanGenius/floe-agent/pull/19)已关闭。发布标签固定在通过资格验证的 iOS 快照；本轮分支已在本地和远端删除。

归档与发布收尾阶段实测释放约 8.55 GiB：移除已导出的构建缓存、重复归档、生成 App、传输暂存和已替代的 Debug／签名副本。保留已校验无签名安装包、14 份 dSYM 的校验归档、来源与 UUID 记录、原始成功／失败证据、试听音频及必要回滚。共享依赖缓存继续用于增量复用。两个分发消费者完成后，已删除私有传输 Release；公开标签不变。

当前仅余：完成 Safari 双重认证后，保存本版审核说明，向现有 publictest1 提交一次并独立回查状态。正式 App Store 提交及历史构建保持各自状态；本次未自动发布正式 App、部署网站或创建外部定时器。
