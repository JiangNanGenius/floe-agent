# 1.6.1（136）发布核验

用于替代未上传成功的 1.6.0（135）。应用功能代码保持不变，修正旧测试把普通文本当成 PPTX 的假样本；测试改用实际 `OfficeDocumentBuilder` 生成的文件，仍逐字节检查两次保存、工作副本及显式丢弃。

- 生产源码隔离检查：`DocumentWorkspaceTests` 与 `OfficeNativeSaveValidationTests`，15/15 通过。测试直接链接仓库源码及锁定 ZIPFoundation / swift-crypto，没有替代保存实现。
- [回归日志](evidence/workflow-upgrade-20260909/document-save-release-regression.log)。
- 生产代码 CI 34359227808 的应用回归 **127/127 通过**，包含聊天重连缺页与生图目录完整性。SwiftPM 实际失败仅为旧 PPTX 假样本；修复版以新标签检查为准。见[原始日志摘录](evidence/workflow-upgrade-20260909/ci-34359227808-focused-results.json)。
- 标签 `v1.6.1` 对应源码 `342f668e28e1be793318ca0e7881dd98f66a1d82`；版本、四目标一致性、生成工程与发布预检通过。
- 默认分支 `main` 已快进到同一提交，GitHub 介绍及截图索引已同步；[正式 push CI 34362667080](https://github.com/JiangNanGenius/floe-agent/actions/runs/34362667080) 已触发。
- [发布流程 34362444246](https://github.com/JiangNanGenius/floe-agent/actions/runs/34362444246) 的 Swift 测试已于 2026-09-09 14:28:34 UTC 通过，iOS 模拟器构建于 14:47:11 UTC 通过；应用回归、设备构建与签名上传门槛尚待完成。
- 同一源码的主分支 CI 34362667080 应用回归于 14:49:07 UTC 通过，正在执行 SwiftPM 检查；Linux 构建已通过，App Store SDK 构建尚在执行。
- 签名上传、Apple VALID 和 Floe QA 内部组可见性：尚未完成。
- [代码审计](RELEASE_CODE_AUDIT_20260909.md)、[发布说明](RELEASE_NOTES_1.6.1.md)及 [Office 截图](OFFICE_SCREENSHOT_INDEX.md)。

完整 Office 功能、复杂布局和物理设备验收仍保持开放。

发布后须将 GitHub 说明更新为本分支最新双语说明，包含冻结后补查确认的 Office 保存入口差异和独立 Mac WebContent 异常；不移动标签，也不把后续代码修正冒充已包含在 1.6.1 中。
