## Floe Agent 1.4.94 (Build 125)

### 简体中文

- **PDF 表单填写落地**：新增 document.pdf.fillForm——通过内置 pdf-lib（纯 JS、经 JSPackages 预装、JavaScriptCore 运行）列出/填写 AcroForm 交互字段。list 返回字段名与语义类型；fill 按类型校验（文本/复选框/下拉/单选/选项列表），非法选项与不存在字段逐字段如实报告，绝不静默应用。为此在 JS 包注入层补了 setTimeout 微任务垫片（JavaScriptCore 无计时器）。
- **7z 解压**：workspace.archive 新增 7z 读取（SWCompression 4.9.1，MIT），extract/list 与既有路径同样限额与路径净化；7z 创建与 rar 如实不可用（SWCompression 4.9 已移除 RAR，unrar 许可证不兼容）。
- **destination 语义澄清**：gz/bz2/xz 解压输出单文件、zip/tar/7z/tar.* 解压输出目录，schema 明确标注；destination 以 "/" 结尾时自动在该目录下按源文件名落盘。
- **exec.localNumerical 更名 exec.compatEvaluator**：名字不再暗示是 GNU R/Stata/MATLAB 运行时；描述本就如实，本次消除命名误导（引用全部更新，旧授权下次使用重新确认一次）。
- 新增 SWCompression 依赖（exact 4.9.1）与 pdf-lib 1.17.1 内置资源（SHA-256 锁定），供应链全部走既有 exact-pin 校验。
- 受影响九个 target 共 550 项测试全部通过。

这是内部测试版本，不开放外部公开 Beta。先完成自动测试、CI、签名上传，再分别核验 Apple VALID 与 Floe QA 可见性；表单读写真机交互、7z 互操作在真机安装此包后验收。

### English

- **PDF form filling lands**: new document.pdf.fillForm — lists and fills interactive AcroForm fields through the bundled pdf-lib (pure JS, pre-installed via JSPackages, running in JavaScriptCore). list reports field names with semantic types; fill validates per type (text/checkbox/dropdown/radio/option list), honestly reporting invalid options and unknown fields per field, never applying anything silently. A setTimeout microtask shim was added to the JS package injector (JavaScriptCore has no timers).
- **7z extraction**: workspace.archive now reads 7z (SWCompression 4.9.1, MIT) with the same caps and name sanitization for extract/list; 7z creation and rar remain honestly unavailable (SWCompression 4.9 removed RAR, and unrar's license is incompatible).
- **destination semantics clarified**: gz/bz2/xz extract to a single file while zip/tar/7z/tar.* extract to a directory, explicitly documented in the schema; a trailing "/" destination places the decompressed file under that directory using the source's base name.
- **exec.localNumerical renamed to exec.compatEvaluator**: the name no longer implies a GNU R/Stata/MATLAB runtime (the description was already honest; all references updated, saved approvals re-confirm once on next use).
- New SWCompression dependency (exact 4.9.1) and bundled pdf-lib 1.17.1 resource (SHA-256 pinned), all through the existing exact-pin supply-chain checks.
- 550 tests across nine affected targets all pass.

Internal testing only; no public beta distribution. Automated tests and CI precede signed upload, followed by separate Apple VALID and Floe QA visibility checks. Real form fill interaction and 7z interop are verified on device after installing this build.
