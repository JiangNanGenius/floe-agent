# 1.6.1（136）发布核验

用于替代未上传成功的 1.6.0（135）。应用功能代码保持不变，修正旧测试把普通文本当成 PPTX 的假样本；测试改用实际 `OfficeDocumentBuilder` 生成的文件，仍逐字节检查两次保存、工作副本及显式丢弃。

- 生产源码隔离检查：`DocumentWorkspaceTests` 与 `OfficeNativeSaveValidationTests`，15/15 通过。测试直接链接仓库源码及锁定 ZIPFoundation / swift-crypto，没有替代保存实现。
- [回归日志](evidence/workflow-upgrade-20260909/document-save-release-regression.log)。
- 最新生产代码 CI 34359227808 的应用回归步骤已成功，其 SwiftPM 旧样本仍会失败；修复版以新标签发布检查为准。
- 版本、生成工程与发布预检：准备中。
- 签名上传、Apple VALID 和 Floe QA 内部组可见性：尚未完成。
- [代码审计](RELEASE_CODE_AUDIT_20260909.md)、[发布说明](RELEASE_NOTES_1.6.1.md)及 [Office 截图](OFFICE_SCREENSHOT_INDEX.md)。

完整 Office 功能、复杂布局和物理设备验收仍保持开放。
