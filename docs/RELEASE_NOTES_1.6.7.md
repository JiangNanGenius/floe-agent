# Floe Agent 1.6.7 (143) — 本地终端 / Shell / 包管理

> 开发草稿，未发布。功能验证与未完成项见 [实施记录](LOCAL_SHELL_IMPLEMENTATION_2026-09-12.md)。

本版本加入设备端 POSIX shell 基底、交互会话与 apt/pkg 能力目录，并把一批
重叠工具降级为工作流指南。本文件为发布候选说明；发布核验见
`docs/RELEASE_VERIFICATION_1.6.7.md`（待发布流程生成）。

### 简体中文

## 新增
- **本地 Shell**：`exec.shell` 一次性命令（管道、重定向、glob、变量、`&&/||`），基于 ios_system（BSD-3）命令总线；`jobs.submit` 支持后台执行（上限 600 秒）。
- **交互会话**：`shell.open` / `shell.exchange` / `shell.close` / `shell.signal`，最多 4 个会话、空闲 30 分钟回收，支持 Ctrl-C 与提示式脚本。
- **apt / pkg 能力目录**：`apt` 工具与壳内 `pkg`/`apt-get`/`dpkg -l` 查询；预置 35 个纯 Python 包（openpyxl、python-pptx 之外的常用数据/文本/文档工具），其余按需经审查安装；`dpkg -x` 仅解包数据型 `.deb` 并拒绝 ELF。
- **Floe 替换命令**：`python3`、`sha256sum`、`ping`、`traceroute`、`dig`/`nslookup`/`host`、`nc`、`apt`/`pkg`/`dpkg`，与 Agent 工具共用同一后端。
- **Linux 兼容边界**：BSD 版本的文件/文本命令（`sed -i` 需后缀等）、`sudo` 与原生 ELF 不可用，均已写入 `floe-shell` 指南与文档。

## 安全
- 所有 shell 工具强制审批；`CatastrophicActionGate` 叠加 shell 专用拦截（curl 管道进解释器、sudo、强推等）。
- 工作区隔离仍待完成引擎验证；网络命令保持 Floe 的公有目标校验；WASM 命令无 socket。
- 经确认放开的范围（外部命令可读工作区内全部文件、命令级风险粗化、签名目录的 WASM 命令包）在 `docs/ARCHITECTURE_LOCAL_SHELL.md` 中明确记录。

## 工具面
- 修复悬空引用（browser.upload / workspace.inspectMetadata / workspace.moveItem / document.pdf.save）；删除死工具 `exec.remotePython`；移除无来源的 `ownerSkillID` 元数据。
- 降级并删除 `image.process`、`image.svgDocument`、`crypto.hash`、`workspace.appendFile`、`workspace.replaceText`，由隐藏指南 `floe-image-edit`、`floe-svg`、`floe-text-edit` 与更新后的 `floe-crypto` 承接。
- 修正 `document.pdf.render` 的风险/效果声明；`canvas.generate` 显式声明内部状态效果；同义词与重命名别名统一到 `ToolAliasTable`。

### English

## Added
- Local POSIX shell substrate: `exec.shell` one-shot commands (pipelines, redirections, globs, variables, `&&`/`||`) on the ios_system (BSD-3) command bus, plus background execution through `jobs.submit` (600 s ceiling).
- Interactive sessions: `shell.open` / `shell.exchange` / `shell.close` / `shell.signal` with 4-session and 30-minute idle limits, Ctrl-C support and prompt-driven scripts.
- apt/pkg capability catalog: the `apt` agent tool plus in-shell `pkg`/`apt-get`/`dpkg -l` queries; 35 preset pure-Python packages (common data/text/document tools), reviewed on-demand installs for the rest, and data-only `.deb` extraction via `dpkg -x` that rejects ELF payloads.
- Floe replacement commands (`python3`, `sha256sum`, `ping`, `traceroute`, `dig`/`nslookup`/`host`, `nc`, package commands) backed by the same services as the agent tools.
- Documented Linux fidelity boundaries (BSD flag differences, no sudo, no native ELF) in the `floe-shell` guide and architecture doc.

## Security
- Every shell tool is approval-gated; the catastrophic gate gains shell-specific patterns (download-piped-to-interpreter, sudo, force-push, raw device writes).
- mini-root confinement to the task workspace; network commands keep Floe's public-target validation; WASM commands have no sockets.
- The explicitly approved relaxations (workspace-wide read access for external commands, coarse per-command risk, signed WASM command packages) are recorded in `docs/ARCHITECTURE_LOCAL_SHELL.md`.

## Tool surface
- Fixed dangling references, deleted the dead `exec.remotePython` tool, and removed the never-populated `ownerSkillID` metadata.
- Retired `image.process`, `image.svgDocument`, `crypto.hash`, `workspace.appendFile` and `workspace.replaceText` in favor of the hidden `floe-image-edit`, `floe-svg`, `floe-text-edit` and updated `floe-crypto` guides.
- Corrected `document.pdf.render` risk/effect, made `canvas.generate`'s internal-state effect explicit, and unified synonyms and rename aliases in `ToolAliasTable`.
