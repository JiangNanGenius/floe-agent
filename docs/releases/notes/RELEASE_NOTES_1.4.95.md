## Floe Agent 1.4.95 (Build 126)

### 简体中文

- **交互式远程 shell（新能力）**：新增 `ssh.shellOpen` / `ssh.shellExchange` / `ssh.shellClose` 三件套——模型获得与人用 UI 终端等价的交互式 SSH 能力。executionMode=direct 走直连 SSH PTY；executionMode=host 走 Floe 守护程序新增的 `/v1/shell` 通道（guardian 升级至 1.4.4，旧守护程序会得到明确重部署指引）。会话 run 级隔离、30 分钟过期、输出有界并经 SecretRedactor 脱敏。一次性命令仍用 ssh.execute（durable taskID），指引已写明分工。
- **system prompt 大幅精简**：ssh/telnet/串口/tcp 四族合并为一段「Terminal toolkit」常驻块（按族细化规则），VNC 段压缩约 70%、保留全部关键禁令（partialSuccess 不重放、状态机、凭证规则），cloud-workspace 压至两行；浏览器/VNC 交互策略同样压缩并指向领域 skill。
- **9 个领域 skill 随包内置**：标准 skill 包结构、与 skill.create 同构校验安装。office / pdf / network 三个**暴露到 skill hub**（可见、可启用/禁用、随版本升级）；python（localPython 基座契约）/ apple（苹果能力全家桶）/ data-code / browser / files-vcs / crypto 六个**内置隐藏**（hub 不显示、仅 skill.read 按需读、防删除、内容仅跟随软件更新）。默认全部 disabled，不占上下文。
- **苹果能力指引收编**：原先分散注入的能力说明块合并进 floe.apple；能力开关对工具的过滤逻辑不变。
- **职责澄清**：network.http（原始请求控制）vs web.fetch（读页面内容）、image.generate（独立图片）vs canvas.generate（画布谱系）、office.inspect（可编辑字段 ID）vs readSheet（只读表格）、skill.create（带 Python 脚本先读 floe.python 契约）。
- 受影响九个 target 全部测试通过（含 shell 双后端与 guardian /v1/shell 本地 PTY 往返冒烟）。

这是内部测试版本，不开放外部公开 Beta。先完成自动测试、CI、签名上传，再分别核验 Apple VALID 与 Floe QA 可见性；真机验收项：ssh.shell 双环境交互会话、hub 三个暴露 skill 的启用/升级、PDF/office/network 任务前模型主动 skill.read、VNC/terminal 任务规则仍每轮可见。

### English

- **Interactive remote shell (new capability)**: new `ssh.shellOpen` / `ssh.shellExchange` / `ssh.shellClose` — the model gains interactive SSH on par with the human UI terminal. executionMode=direct rides a plain SSH PTY; executionMode=host rides the Floe guardian's new `/v1/shell` channel (guardian bumped to 1.4.4; older guardians get an explicit redeploy hint). Sessions are run-scoped, expire after 30 minutes, and all output is bounded and SecretRedactor-redacted. One-shot commands still belong to ssh.execute (durable taskID) — the guidance spells out the split.
- **System prompt sharply slimmed**: ssh/telnet/serial/tcp merge into one always-on "Terminal toolkit" block with per-family rules; the VNC section shrinks ~70% while keeping every critical prohibition (no replay after partialSuccess, state machine, credential rules); cloud-workspace is down to two lines; browser/VNC policies are compressed and point at domain skills.
- **Nine bundled domain skills**: standard skill packages, validated and installed through the same path as skill.create. office / pdf / network are **exposed in the skill hub** (visible, enable/disable, upgrade with releases); python (the localPython substrate contract) / apple (Apple capability pack) / data-code / browser / files-vcs / crypto are **hidden built-ins** (absent from the hub, readable on demand via skill.read, deletion-protected, updated only with app updates). All install disabled by default — zero prompt cost.
- **Apple guidance consolidated**: the previously scattered capability instruction blocks are merged into floe.apple; capability-gated tool filtering is unchanged.
- **Responsibility clarifications**: network.http (raw request control) vs web.fetch (reading pages), image.generate (standalone images) vs canvas.generate (canvas graph), office.inspect (editable field IDs) vs readSheet (read-only grid), skill.create (read floe.python first for script-carrying skills).
- All affected nine targets' tests pass, including shell dual-backend tests and a local PTY round-trip smoke of the guardian's /v1/shell.

Internal testing only; no public beta distribution. Automated tests and CI precede signed upload, followed by separate Apple VALID and Floe QA visibility checks. On-device acceptance: interactive ssh.shell sessions in both environments, hub enable/upgrade of the three exposed skills, the model proactively reading skills before PDF/office/network work, and VNC/terminal rules remaining visible every run.
