# Floe Agent 1.7.0 (178)

Build 178 passed the release workflow's complete verification: SDK 27 and the
App Store accepted SDK builds, focused App regressions (178/178), iPad and
iPhone Notes UI on both SDKs, Linux compilation, secret scan, SBOM and license
inventory. It was signed and uploaded to TestFlight from immutable source
`32acddd41f0f5735ac7f1cec2eb14feb1da28623`, tag `v1.7.0-beta.35`.

> **Correction · 2026-09-17:** The Lua/WasmKit 0.3.1 component work described
> below remained on `codex/wasmkit-eh-languages`; it was not included in source
> `32acddd41f0f5735ac7f1cec2eb14feb1da28623`. Build 178 retains WasmKit 0.2.2
> and has no registered Lua command. The original claim is retained below as
> history, not as a shipped capability.
>
> **更正：** 下文 Lua／WasmKit 0.3.1 的组件工作未合入 Build 178 的固定源码。
> 此版本仍使用 WasmKit 0.2.2，没有 Lua 命令；不能将独立分支的测试计作已交付。

### 简体中文

- 保留前一候选版的运行环境、包管理、手记助手隔离与实时刷新修复。
- Soul 与用户画像更新后，正在运行的任务在下一次模型请求时读取已激活的新内容；草稿不自动进入上下文，重试保持原请求。
- 工作区增加 IDE 全屏编辑入口及并发保存冲突处理；网页编辑器与图纸查看器跟随 Floe 的语言选择。
- DXF/DWG 提供基础图元编辑、保存、撤销和冲突保护；STEP、IGES、BREP 提供只读网格预览。复杂图纸和各格式的限制见兼容说明。
- 文件管理器中的图纸可以直接发起 AI 审图，不要求预先选中聊天；只有用户填写问题并发送后才创建审图任务。输入包括实际视口截图和有界图纸信息。
- 本候选同时修复：图纸审阅证据折叠面板在辅助功能下无法展开、手记标签页异步关闭竞态、IDE 自动化文本输入、以及工程 UI 在重载运行器上的若干稳定性问题。
- RDP 原生运行时已产出可打包的 FloeRDPNative.xcframework（真机与模拟器切片均通过链接验证）；App 内 RDP 接入仍未完成，本版不对用户开放 RDP。
- 新增 Lua 语言运行时路线（组件级证据）：WasmKit 升级至 0.3.1，锁定的 Lua 5.4.8 wasm 构建已通过 App 同款 WASI 命令运行时的执行、文件与错误恢复测试。App 内语言注册在后续版本开放。

### English

- Retains the preceding runtime, package, dedicated Notes assistant and live document refresh fixes.
- Active Soul/profile changes are read at the next model request. Drafts stay out of context and retries retain the original request.
- Workspace files open in the full-screen IDE with conflict-aware saving. Embedded editors and drawing viewers follow Floe's language selection.
- Basic DXF/DWG entity editing, undo, durable saving and conflict protection; read-only STEP/IGES/BREP mesh previews. Format limitations remain documented.
- Drawing review can start directly from files without an existing selected chat. A task is created only when the user sends a question, using a real viewport image and bounded drawing metadata.
- This candidate also fixes: the drawing-review evidence disclosure not expanding under accessibility, the asynchronous Notes tab-close race, IDE automation text entry, and several loaded-runner stability issues in engineering UI qualification.
- The RDP native runtime now packages as FloeRDPNative.xcframework (device and simulator slices link-verified); App RDP integration remains incomplete and RDP is not exposed in this build.
- New Lua runtime route (component-level evidence): WasmKit upgraded to 0.3.1, and the pinned Lua 5.4.8 wasm build passed execution, file and error-recovery tests through the app's own WASI command runtime. In-app language registration ships in a later build.

### Evidence and remaining work

Full verification runs: CI
[35083821490](https://github.com/JiangNanGenius/floe-agent/actions/runs/35083821490)
(same app source), release
[35106710878](https://github.com/JiangNanGenius/floe-agent/actions/runs/35106710878)
(signed upload, 178/178 focused regressions on both SDKs, Notes UI on iPad and
iPhone). Native Office remains device-only; simulator Notes tests do not verify
its engine. Qwen iPad acceptance, the complete native npm/WASI/APT catalog,
media-model acceptance, RDP App integration and log-service deployment are not
automatically completed by this candidate. See
[repair execution record](FLOE_172_REPAIR_EXECUTION.md) and
[engineering viewer matrix](FLOE_ENGINEERING_VIEWERS.md).

Public Beta review is not submitted automatically. No paid provider key is
included in review materials. The existing real Agent demonstration is
explicitly labelled Build 175 and is not a recording of this candidate.
