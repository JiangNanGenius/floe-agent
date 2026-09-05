## Floe Agent 1.4.91 (Build 122)

### 简体中文

- 修复结论已输出却误报失败：最终答案自检轮（复核 CONFIRM/修正）是可选项，现在该轮遇到上下文超限、输出超限或传输错误时不再拖垮整个运行，直接以已给出的结论正常完成。
- 修复 cloudWorkspace 参数污染：list/read/createDirectory 不再携带 contentBase64；gitStatus/gitDiff/gitLog/gitFetch/gitStage/gitInitialize/gitPull/gitPush 不再携带 message/name；每个工具只声明自己真正消费的字段，gitCommit 的 message 提升为必填。
- 新增 workspace.archive：正式的工作区 zip 能力（create/extract/list），解压限制条目数与总大小、拦截路径穿越条目，绝不覆盖已有目标。
- 新增 crypto.hash：可审计的 SHA-256/384/512、SHA-1、MD5 摘要（文本或工作区文件），不再依赖脚本兜底。
- 新增 image.qrGenerate：本地 Core Image 生成二维码 PNG（L/M/Q/H 纠错级），与 image.scanBarcode 解码方向互补。
- document.pdf.edit 的 rotationDegrees 在 schema 中限定 90° 倍数枚举；水印新增 watermarkFontSize（8-72）与 watermarkOpacity（0.05-1）可选参数。
- exec.localPython 描述补全真实内置的 zipfile/tarfile/gzip/shutil/hashlib/hmac/secrets/base64/binascii 标准库模块。
- 描述澄清：presentation.create（内联结果）与 presentation.createDeck（.pptx 文件）互相指引；document.createDocument 明确生成 Markdown 并指向 document.createWord；skill.manage 移除语义改为“保留文件系统备份、无自动恢复工具”。
- 自动化测试新增三组（压缩归档、哈希、二维码），受影响六个 target 共 409 项测试全部通过。

这是内部测试版本，不开放外部公开 Beta。先完成自动测试、CI、签名上传，再分别核验 Apple VALID 与 Floe QA 可见性；zip 大文件解压、二维码真机扫码、PDF 水印参数与长任务收尾在真机安装此包后验收。

### English

- Fix runs being marked failed after the conclusion was already delivered: the final-answer self-review pass (CONFIRM/correction) is optional, so context overflow, output-limit or transport errors during that pass no longer sink the run — it now completes normally with the delivered answer.
- Fix cloudWorkspace parameter pollution: list/read/createDirectory no longer carry contentBase64; gitStatus/gitDiff/gitLog/gitFetch/gitStage/gitInitialize/gitPull/gitPush no longer carry message/name. Every tool advertises exactly the fields it consumes, and gitCommit's message is now required.
- New workspace.archive: first-class zip capability (create/extract/list) in the workspace. Extraction caps entry count and total size, blocks path-traversal entries, and never overwrites existing destinations.
- New crypto.hash: auditable SHA-256/384/512, SHA-1 and MD5 digests for text or workspace files, replacing informal script fallbacks.
- New image.qrGenerate: local Core Image QR PNG generation (L/M/Q/H correction levels), complementing image.scanBarcode decoding.
- document.pdf.edit constrains rotationDegrees to 90-degree increments in the schema; watermarks accept optional watermarkFontSize (8-72) and watermarkOpacity (0.05-1).
- exec.localPython's description now lists the actually bundled zipfile/tarfile/gzip/shutil/hashlib/hmac/secrets/base64/binascii standard-library modules.
- Description clarifications: presentation.create (inline result) and presentation.createDeck (.pptx file) cross-reference each other; document.createDocument states it produces Markdown and points to document.createWord; skill.manage removal is described as a retained filesystem backup with no automatic restore tool.
- Three new automated test suites (archive, hash, QR); 409 tests across the six affected targets all pass.

Internal testing only; no public beta distribution. Automated tests and CI precede signed upload, followed by separate Apple VALID and Floe QA visibility checks. Large zip extraction, real-device QR scanning, PDF watermark parameters and long-run finalization are verified on device after installing this build.
