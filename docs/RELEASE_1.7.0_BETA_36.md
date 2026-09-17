# Floe Agent 1.7.0 (179) — beta.36 internal candidate

> **Status: candidate only, not uploaded.** These notes describe the next
> internal candidate prepared from source `955e346a` (which adds verified Lua
> qualification fixtures on top of the SDK 26.6-qualified `59e24d61`, with no
> App-source difference). It has **not** been signed, uploaded or confirmed
> `VALID` / `IN_BETA_TESTING`. Build 178 remains the latest build recorded as
> available in the internal Floe QA TestFlight group. Do not treat this file
> as a delivery record. Cloud CI run `35202845926` failed in the IDE
> native-saves step (2026-09-17T10:14:09Z); the artifact is being retained
> and the primary agent is investigating. This candidate must not be called
> upload-ready.
>
> **状态：仅候选，未上传。** 本文描述基于源码 `955e346a` 准备的下一内部候选版
> （该提交在已通过 SDK 26.6 兼容验证的 `59e24d61` 之上仅增加 Lua 验证夹具，无
> App 源码差异）。它**尚未**签名、上传或确认为 `VALID` / `IN_BETA_TESTING`。
> Build 178 仍是记录在案的最新可用内部 TestFlight 版本。本文不是交付记录。
> 云端 CI 运行 `35202845926` 在 IDE native saves 步骤失败（2026-09-17T10:14:09Z），
> 正在保留产物并由主代理排查日志；本候选不得称为已就绪可上传。

Last updated: 2026-09-17. Working evidence:
[build 178 feedback repair record](FLOE_BUILD178_FEEDBACK_REPAIR.md).

### 简体中文

- 保留 Build 178 的全部功能与修复。
- 手记资料库封面不再只限 PDF：Word、Excel、PPT 使用系统 Quick Look 生成封面
  （生成有并发与重试上限，失败不缓存）；DXF／DWG 图纸可作为工程文档导入并以
  只读 CAD 预览查看，资料卡显示图纸文件名。
- 手记助手：`notes.read` 返回分页摘要并给出继续读取位置；`notes.edit` 的
  新增／移动文字支持指定页坐标；未知类型文档降级为只读摘要，不再使工具崩溃。
- Office：内嵌字体下拉等原生控件与显式保存桥接由宿主视图持有；外部刷新同时
  比对草稿与不可变原始资源的哈希，冲突决定保持可见；画笔批注的颜色、线宽、
  透明度按文档保存（见使用指南，0% 透明度为实心）。
- IDE：全屏编辑器可直接“运行”当前文件，先保存再运行、可停止、Rust／Swift／
  C/C++ 及 PHP／Ruby／Go 等远端语言走已配置主机；不声称本机编译。
- Shell 软件包：签名 WASM 能力目录已内置，Lua 5.4.8 作为 `floe/lua` 通过
  `apt install floe/lua` 安装，支持 `apt search/list/show` 与 `lua` 别名；
  混合 WASM 与 Debian 变更在安装前被拒绝。
- 本地 MLX 模型：编译轨迹（compiled traces）由进程级一次性策略关闭，减少
  宿主验证中观察到的引擎关闭后内存驻留；真实权重宿主推理已通过。iPad 普通聊天
  崩溃报告的真机复核仍待进行，**不能宣称已根治**。

### English

- Retains everything shipped in build 178.
- Notes library covers are no longer PDF-only: Word, Excel and PPT covers use
  system Quick Look generation (bounded concurrency/retries, failures are not
  cached); DXF/DWG drawings import as engineering documents with a read-only
  CAD preview, and the card shows the drawing file name.
- Notes assistant: `notes.read` returns paginated summaries with continuation
  positions; `notes.edit` add/move text accepts page coordinates; unknown
  document kinds degrade to a read-only summary instead of crashing tools.
- Office: embedded native controls (font dropdown) and the explicit-save
  bridge are owned by the host view; external refresh compares draft and
  immutable base-resource hashes and keeps the conflict decision visible;
  annotate color/width/transparency persist per document (0% is solid).
- IDE: the full-screen editor can Run the current file with save-before-run,
  stop, and remote languages (Rust/Swift/C/C++, PHP/Ruby/Go/…) routed to a
  configured host; no on-device compilation is claimed.
- Shell packages: the signed WASM capability catalog is bundled; Lua 5.4.8
  installs as `floe/lua` via `apt install floe/lua`, with `apt search/list/
  show` and the `lua` alias; mixed WASM and Debian mutations are rejected
  before changes.
- Local MLX models: compiled traces are disabled by a one-time process-wide
  policy, reducing buffer retention after engine shutdown observed in host
  qualification; real-weight host inference passed. The reported iPad ordinary-chat crash
  **remains unconfirmed as fixed** pending physical-device re-test.

### Evidence and remaining work

- Component and host verification includes: Notes module suite (42 tests),
  Office adapter Python tests, 106 IDE run-policy harness checks, 15 Lua
  routing tests, real-weight macOS inference diagnostics with four shutdown
  gates, and the SDK 26.6 full-App compatibility compile of `59e24d61`
  (≈32 min, no archive/upload).
- The same full-App SDK 27 run passed Notes on iPad and iPhone: three tests per device, with the native Office case skipped on each. [Original screenshots and provenance](qualification/build178-feedback/full-app-955e346a/README.md) are retained. This does not qualify native Office editing.
- Cloud CI run `35202845926` **failed** in the IDE native-saves step as of
  2026-09-17T10:14:09Z; the failing artifact is being retained and the primary
  agent is investigating the logs. Dual-device IDE saves therefore cannot be
  claimed as passing, and this candidate must not be described as
  upload-ready.
- The build-179 version bump (four targets in `project.yml` plus the
  regenerated project) exists only in the local working tree with focused
  preflight checks passing; it is **not committed and not tagged**, and no
  release workflow has been dispatched against it.
- Not complete: full-App simulator/device acceptance, release workflow,
  signing, upload and TestFlight availability for build 179.
- Explicitly not shipped: the PHP 8.4.1 browser prototype is a private Worker
  experiment and is **not** included; Rust/Swift local compilation is not
  valid — those languages route to a configured remote host; the iPad local
  model crash is not declared fixed.
- Public beta materials contain no user API key. See the
  [repair record](FLOE_BUILD178_FEEDBACK_REPAIR.md) for the full ledger,
  including retained original failures.
