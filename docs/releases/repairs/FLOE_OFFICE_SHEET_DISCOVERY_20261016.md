# Office worksheet discovery / 工作表发现修复

Date: 2026-10-16. Source-only follow-up after the immutable 1.7.34 (275) submission; **not included in build 275**. No new version, upload, submission or publication.

## 简体中文

- 问题：工作簿已包含真实表名，但 `document.office.inspect` 只给出 `Sheet 1` 等字段分区。模型猜测表名后，`document.readSheet` 的缺表错误也没有提供可选名称。
- 两个读取工具现在输出统一的 `worksheets=` JSON 目录：真实表名、对应字段分区、工作表文件和可见状态。目录放在单元格内容之前，最多 32 张表、16 KiB，明确返回 `total`、`shown` 和 `truncated`；不截断名称来冒充完整名称。
- `inspect` 复用现有 `workbookPreview`；两个路径共用工作簿 XML 名称解析，正确处理中文、引号、XML 实体和字符引用。元数据无法可靠解析时明确说明，不把字段分区当作表名。
- 明确请求不存在的表仍失败，并返回有界目录；不会静默改读第一张表。未指定名称时仍读取第一张表。目录截断不限制读取已知的其他真实表名。
- 字段 ID、修订哈希、工作区权限、保存与重开校验保持原有路径。已验证按真实表名定位到字段、修改后重开，其他表内容不变。

## English

- Both read tools now expose the same bounded `worksheets=` JSON catalog: actual names, stable field sections, worksheet parts and visibility, ahead of cell content. It retains at most 32 sheets and 16 KiB, with explicit total/shown/truncated fields; it never returns a shortened name as an exact name.
- Inspection reuses the existing workbook preview metadata. Both readers share XML tab-name parsing, including quoted names and numeric character references. Unresolvable metadata is reported rather than guessed.
- A missing explicit name still fails with the available bounded catalog; it never falls back to another sheet. An omitted name keeps the documented first-sheet behavior. Catalog truncation does not prevent an exact read of an omitted sheet.
- Existing field IDs, revision checks, workspace authorization and verified-save services are retained.

## Verification

- Baseline: `3a5a7870f14c70979363d63fdf11811c3da7f7f9`. Local Xcode toolchain, Apple Swift 6.4 (`swiftlang-6.4.0.34.1`), arm64 macOS 27.0.
- A focused local qualification package compiled the **production** FloeCore, FloeModels, FloeTools, FloeWorkspace and FloeDocuments sources with the package's Swift 6 concurrency settings and the existing pinned dependency checkouts. It ran the canonical `DocumentReadSheetToolTests.swift` and `OfficeDocumentTests.swift`: **16 tests / 3 suites passed**. This is macOS component verification, not full-App, Simulator interaction or physical-device acceptance.
- New regressions cover Chinese names, reversed tab/part order, hidden/very-hidden sheets, quotes/backslashes/XML entities/control-character references, missing names, 40-sheet catalog truncation, byte limits, exact-target update/reopen and unchanged sibling sheets. Existing document creation, package preservation, revision rejection and workspace-boundary cases also passed.
- The initial special-character test exposed a real difference between regex attribute decoding in preview metadata and the XML parser used by readSheet. The original failure is retained; the fix reuses the XML parser rather than weakening the assertion. The final run passed.
- Command: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path Local/Scratch/office-sheet-discovery-20261016 --scratch-path ~/Library/Caches/CodexBuild/Floe/0dd039b5b74b/xcode27/office-sheet-discovery-20261016 --jobs 6`.
- Qualification manifest and original/final logs are retained under the Git-ignored `Local/Private/app-store-274-20261016/office-sheet-discovery/`. Task-only build and harness scratch are removed after verification; dependency checkouts, filming assets, existing Simulator sessions and the other task's uncommitted guide edits are preserved.
