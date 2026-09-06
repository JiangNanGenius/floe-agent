## Floe Agent 1.4.92 (Build 123)

### 简体中文

- PDF 工具补齐高频能力：新增 document.pdf.merge（2-10 份按序合并）、document.pdf.split（按 "1-3,5,8-10" 页码提取）、document.pdf.fromImages（图片逐页转 PDF）；document.pdf.render 支持多页范围。
- document.pdf.edit 增强：rotations 按页分别旋转（不再绑定单一角度）；水印新增位置（居中/上/下/四角）与 watermarkPages 指定页；pageNumbers 页码戳（位置/起始号）；userPassword/ownerPassword 加密（写出后用密码解锁验证）；replaceText 批注层覆盖式替换（白底遮盖+新文本，明确标注不改写内容流，需 render 复核）。
- pdf-workbench 技能描述同步更新为真实能力；交互表单填写与内容流改写仍如实标注不可用。
- workspace.archive 增加 tar 支持（create/extract/list，format 参数或按扩展名识别），ustar 读写为零新依赖实现：读取兼容 GNU/BSD tar（pax path= 长名、GNU L 长名、AppleDouble ._ 元数据过滤）、路径穿越拦截不变；tar.gz/bz2/xz/7z/rar 如实引导至 exec.localPython（tarfile/gzip/bz2/lzma 已内置）。
- 新增 crypto.cipher：Keychain 命名密钥的 AES-256-GCM 加解密与 Ed25519 签名验签；原始密钥永不返回，generateKey 拒绝静默轮转，file 输出不覆盖。
- 新增 credential.manage：凭据卡片独立管理（list 仅元数据、create、update 改标签/换密钥、delete），返回稳定的 ⟨credential:id⟩ 引用，密钥只进不出；vault 新增 replaceSecret/updateLabel，保持引用不变。
- 修复 cloudWorkspace schema 实际为非法 JSON 的严重缺陷（fragment 拼接多出引号、required 未插值、pattern 反斜杠未转义）——此前模型端可能按开放 schema 理解；现在 13 个 schema 全部可解析且 additionalProperties=false 闭合，并有契约测试锁定。
- 修复 Apple 相机保存与新增文件写入中 atomic+withoutOverwriting 组合导致的 Foundation 崩溃（ latent，随本版一并排除）。
- 自动化测试新增 cipher/archive-tar/schema 契约三组，受影响八个 target 共 513 项测试全部通过。

这是内部测试版本，不开放外部公开 Beta。先完成自动测试、CI、签名上传，再分别核验 Apple VALID 与 Floe QA 可见性；PDF 合并/加密/批注层替换、tar 互操作、加密签名与凭据管理在真机安装此包后验收。

### English

- Complete high-frequency PDF capabilities: new document.pdf.merge (2-10 PDFs in order), document.pdf.split (page extraction via "1-3,5,8-10"), document.pdf.fromImages (one image per page); document.pdf.render now accepts multi-page specs.
- document.pdf.edit upgrades: rotations for per-page angles (no longer bound to one shared angle); watermark position (center/top/bottom/corners) and watermarkPages; pageNumbers stamping (position/start); userPassword/ownerPassword encryption (verified by unlocking after write); replaceText as annotation-layer cover-and-replace (white cover plus new text, explicitly not a content-stream rewrite — verify with render).
- The pdf-workbench skill text now matches these real capabilities; interactive form-filling and content-stream rewriting remain honestly unavailable.
- workspace.archive adds tar (create/extract/list via format parameter or extension) with a zero-dependency ustar implementation: reads GNU/BSD tars (pax path= long names, GNU L long names, AppleDouble ._ filtering), keeps path-traversal protection; tar.gz/bz2/xz/7z/rar are honestly routed to exec.localPython (tarfile/gzip/bz2/lzma bundled).
- New crypto.cipher: AES-256-GCM encrypt/decrypt and Ed25519 sign/verify with Keychain-held named keys. Raw keys are never returned, generateKey refuses silent rotation, and file outputs never overwrite.
- New credential.manage: independent credential cards (list metadata only, create, update label/secret, delete) returning the stable ⟨credential:id⟩ reference; secrets are write-only. The vault gains replaceSecret/updateLabel so references stay stable.
- Fix cloudWorkspace schemas being actually malformed JSON (stray quotes in fragments, uninterpolated required array, unescaped pattern backslashes) — clients may have treated them as open schemas; all 13 now parse with additionalProperties=false, locked by contract tests.
- Fix a latent Foundation crash from atomic+withoutOverwriting in camera capture and new file writes.
- Three new automated test suites (cipher, tar archive, schema contracts); 513 tests across eight affected targets all pass.

Internal testing only; no public beta distribution. Automated tests and CI precede signed upload, followed by separate Apple VALID and Floe QA visibility checks. PDF merge/encryption/overlay replacement, tar interop, cipher operations and credential management are verified on device after installing this build.
