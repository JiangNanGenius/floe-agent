# Floe 1.7.0 (215) — stability follow-up / 稳定性修复

Status: release candidate for expedited internal Floe QA TestFlight. This file
describes the intended source; build, upload, Apple processing and group
availability are recorded separately after they occur.

### 简体中文

Build 215 根据 Build 214 的真机日志与实际反馈继续修复稳定性：本地模型只接收精选工具，并在第二轮工具续写时降低 GatedDeltaNet 预填充批量；跨任务检索会继续读取消息并形成最终答复；不同任务的终端会话可并行运行，卡住的命令可以取消和恢复；Git 初始化改用固定的 libgit2 运行时路径；PDF 与 Office 留在 IDE 标签中并跟随任务切换，支持普通保存命令和关闭前保存确认，中文字体元数据随包提供；思维导图改用紧凑图标并修正自由拖动坐标。

TinyEMU 继续作为主要本地运行环境。原生 Python、Node、Ruby 等语言载荷不会重新打进应用，语言和软件包在 Linux 客体中安装运行；WASM 保留为独立兼容路径。本版只要求定向代码检查与云端 App 构建，实际 Office 中文渲染、Git 与本地模型是否仍闪退、Linux 性能和真机交互由用户验收。TinyEMU 采用无宿主 JIT 的解释执行方式，但这一技术属性本身不等于 Apple 已批准。

### English

Build 215 follows the first TinyEMU delivery with fixes based on Build 214 device
logs and hands-on feedback:

- local-model tool calls use a small capability-selected schema, preserve exact
  provider context for cache reuse, and compact transactionally; the on-device
  GatedDeltaNet prefill batch is reduced after logs showed memory pressure during
  the second tool continuation;
- cross-task lookup continues from search results to readable messages and a
  final answer instead of ending after discovery;
- terminal work is isolated by task/session, supports concurrent guest commands,
  and exposes cancellation and recovery for a stuck command;
- Git repository initialization avoids the failing high-level repository-open
  path and initializes/configures the repository through the pinned libgit2
  runtime;
- PDF and Office documents remain inside the IDE tab workspace, follow task
  selection, use bundled Chinese font metadata, support the ordinary save
  command, and prompt when a dirty document is closed;
- mind-map creation uses compact icon controls and preserves free-position drag
  coordinates; and
- TinyEMU remains the primary local runtime. Native Python, Node, Ruby and other
  language payloads are not restored to the App bundle; language/package
  installation belongs to the Linux guest, while WASM remains a separate
  compatibility route.

Only focused source checks and the cloud App build are required for this internal
candidate. Physical-device behavior, Linux performance, actual Office font
rendering, Git crash resolution and local-model memory behavior remain for the
user's acceptance. TinyEMU is used as an interpreter without host JIT; that
technical property alone is not an App Review approval guarantee.
