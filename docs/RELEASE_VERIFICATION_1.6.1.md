# 1.6.1（136）发布核验

最新状态（2026-09-09 16:28 UTC）：**发布流程全部成功，签名包已上传；Apple 仍为 PROCESSING，没有错误或警告，尚无 buildID，测试组可见性未验证。** 上传回执为 `1a3bc980-b852-4b50-9591-58f88c4b1789`，16:22:48 UTC 成功。见[机器可读回执](evidence/workflow-upgrade-20260909/testflight-136-upload-processing.json)。[GitHub 预发布](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.6.1)已公开，说明已同步本分支确认的保存与导出限制。

用于替代未上传成功的 1.6.0（135）。应用功能代码保持不变，修正旧测试把普通文本当成 PPTX 的假样本；测试改用实际 `OfficeDocumentBuilder` 生成的文件，仍逐字节检查两次保存、工作副本及显式丢弃。

- 生产源码隔离检查：`DocumentWorkspaceTests` 与 `OfficeNativeSaveValidationTests`，15/15 通过。测试直接链接仓库源码及锁定 ZIPFoundation / swift-crypto，没有替代保存实现。
- [回归日志](evidence/workflow-upgrade-20260909/document-save-release-regression.log)。
- 生产代码 CI 34359227808 的应用回归 **127/127 通过**，包含聊天重连缺页与生图目录完整性。SwiftPM 实际失败仅为旧 PPTX 假样本；修复版以新标签检查为准。见[原始日志摘录](evidence/workflow-upgrade-20260909/ci-34359227808-focused-results.json)。
- 标签 `v1.6.1` 对应源码 `342f668e28e1be793318ca0e7881dd98f66a1d82`；版本、四目标一致性、生成工程与发布预检通过。
- 默认分支 `main` 已快进到同一提交，GitHub 介绍及截图索引已同步；[正式 push CI 34362667080](https://github.com/JiangNanGenius/floe-agent/actions/runs/34362667080) 已触发。
- [发布流程 34362444246](https://github.com/JiangNanGenius/floe-agent/actions/runs/34362444246) 的 `build-verify-release` 已成功：Swift 测试 14:28:34 UTC、模拟器构建 14:47:11 UTC、应用回归 15:11:02 UTC、设备构建 15:27:12 UTC、IPA 与产物检查 15:27:56 UTC 均通过，已上传构建产物。仍不是 Apple 上传回执。
- 同一流程的 `Archive and upload the same commit to TestFlight` 已成功，完成 App Store SDK 构建、回归、签名与上传；GitHub 产物发布任务也已成功。
- 同一源码的主分支 CI **34362667080 全部成功**：应用回归 **127/127**，全部 SwiftPM 检查、Linux 构建、App Store SDK 构建及密钥扫描通过。修复后的真实 PPTX 连续保存测试也通过；见[日志摘录与源码标识](evidence/workflow-upgrade-20260909/ci-34362667080-results.json)。这不等于签名上传或 TestFlight 可见。
- 签名上传已完成；Apple VALID 和 Floe QA 内部组可见性尚未完成。
- [代码审计](RELEASE_CODE_AUDIT_20260909.md)、[发布说明](RELEASE_NOTES_1.6.1.md)及 [Office 截图](OFFICE_SCREENSHOT_INDEX.md)。

完整 Office 功能、复杂布局和物理设备验收仍保持开放。

发布后须将 GitHub 说明更新为本分支最新双语说明，包含冻结后补查确认的 Office 保存入口差异和独立 Mac WebContent 异常；不移动标签，也不把后续代码修正冒充已包含在 1.6.1 中。
