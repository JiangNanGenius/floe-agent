## Floe Agent 1.4.98 (Build 129)

### 简体中文

- 新增官方 Skill Hub：PDF、Office、网络三个公开内置技能集中存放在本仓库 `skill-hub/`，使用固定提交、签名目录和不可变 ZIP。更新需审核，支持回退和运行中快照；本地编辑、导入及应用启动不能绕过官方来源限制。原生引擎不通过技能包下载。
- 增加隐藏的远程运维指南，统一 VNC、SSH、Terminal、云工作区和分享的状态与 ID 复用规则。Python 与 SSH Executor 继续作为底层能力，交互 Terminal 保持独立，工具按任务分组发现。
- 修复 VNC 依赖发送队列的并发数组访问；保留点击/拖拽后的截图证据，并增加并发入队、出队和清空压力测试。
- PDF 引入原生 PDFium：真实文本对象替换、区域文字排版、图片编辑，以及页面、批注、表单、书签、元数据、OCR 和文本/JSON/图片导出。加密解锁使用凭据引用；修改签名文档和栅格化操作有明确限制与确认。
- 敏感信息删除采用明确标注的整页栅格重建，并检查输出不含原文字、附件或批注；不将视觉覆盖称为安全删除，不承诺保留原数字签名或任意 PDF 的无损重排。
- 增加原生 RAR/RAR5 列出与解压，以及独立的目录/文件目标参数。拒绝路径穿越、链接、超限、损坏、加密和分卷归档，失败时清理临时输出。
- 原生 pandas 3.0.5 随应用打包，运行时报告实际 Python/NumPy/Pillow/pandas 可用性。补齐 `_contextvars`、队列与多字节编码等标准库扩展。SciPy、matplotlib 仍需明确的 WebAssembly 或已授权远端路径。

仅内部 TestFlight，不开放外部 Beta。上传回执、Apple VALID、Floe QA 可见性和实体 iPad 验收分别记录。现有 PiP 行为不变；PDF 视觉效果、离线 pandas、大文件内存及技能更新/回退仍需实体设备验收。

### English

- Added an official Skill Hub for the three public bundled skills: PDF, Office and Network. Packages live in this repository's `skill-hub/` with pinned commits, a signed catalog and immutable ZIPs. Updates require review, support rollback and preserve running snapshots. Local edits, imports and launch-time seeding cannot bypass the official source. Native engines never arrive through skill downloads.
- Added a hidden remote-operations guide covering VNC, SSH, Terminal, cloud workspaces and sharing state/ID reuse. Python and SSH Executor remain execution substrates; interactive Terminal stays separate, with task-scoped tool discovery.
- Synchronized the VNC dependency's concurrent input queue, preserving post-click/drag screenshot evidence and adding concurrent producer/consumer/clear stress tests.
- Added native PDFium for actual text-object replacement, region text layout and image editing, alongside page, annotation, form, bookmark, metadata, OCR and text/JSON/image export workflows. Unlocking uses credential references; signed documents and raster operations have explicit safeguards and consent boundaries.
- Redaction explicitly rebuilds raster pages and checks that original text, attachments and annotations are absent. Visual covering is not represented as secure removal; signature preservation and arbitrary lossless PDF reflow are not claimed.
- Added native RAR/RAR5 listing and extraction with separate directory/file destinations. Traversal, links, excessive output, malformed, encrypted and multipart archives are rejected, with staging cleanup on failure.
- Bundled native pandas 3.0.5 and live Python/NumPy/Pillow/pandas availability reporting. Restored missing standard-library extensions including `_contextvars`, queues and multibyte codecs. SciPy and matplotlib still require an explicitly identified WebAssembly or authorized remote route.

Internal TestFlight only; no external beta. Upload receipt, Apple VALID, Floe QA visibility and physical iPad acceptance are separate gates. Existing PiP behavior is unchanged. PDF visual fidelity, offline pandas, large-file memory behavior and skill update/rollback require device acceptance.
