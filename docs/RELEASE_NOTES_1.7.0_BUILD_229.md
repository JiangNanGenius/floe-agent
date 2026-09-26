# Floe 1.7.0 (229) — release notes / 发布说明

**Status / 状态：云端构建、GitHub 预发布、TestFlight 上传及 Floe QA 内部可安装状态已核实；真机功能待验收。** 不可变标签 `v1.7.0-beta.86` 固定源码 `b06b0b0e42008e8ea5c6b402ab146c99e2bcf328`。[发布运行 36239956371](https://github.com/JiangNanGenius/floe-agent/actions/runs/36239956371) 使用 Xcode 26.6 构建并保留未签名 IPA（739,485,403 字节；SHA-256 `5cd022eb612d89f1d94b91594b747000404cec3f247b8508e89a83e88436124d`），随后完成签名上传及 [GitHub 预发布](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.7.0-beta.86)。Apple Build ID `3aecdb89-1cca-4192-9b32-1493d72ad3fe` 为 `VALID`；[测试说明运行 36242606863](https://github.com/JiangNanGenius/floe-agent/actions/runs/36242606863) 回读中英文本，[测试组核验运行 36242653374](https://github.com/JiangNanGenius/floe-agent/actions/runs/36242653374) 确认未过期、仅在私有 Floe QA 组且为 `IN_BETA_TESTING`。这些交付证据不能据此推断 PPT 或本地模型已在 iPad 上恢复。

## 简体中文

- Office 打开、关闭和保存的等待回执现在只会结算一次，迟到回调不能重启已关闭的会话。PPT 若在超时提示后才真正绘制页面，可恢复该会话；未验证的首帧不算打开成功。手记原文件写回失败时，编辑器保留副本和错误，不报告保存成功或退出。
- 本地模型在推理失败或成功回合的 MLX 收尾出现异常后，不再把受损容器作为下一轮的就绪引擎复用。最后一个聊天任务和临时测速租约都释放后才卸载；三轮普通与工具续轮、取消及测速共用租约有针对性测试。
- TinyEMU 双核心仍受发布资格门控制。界面中的显式双核请求不会被悄悄降为单核；只有真实 Guest 的正确性、持久化与可重复加速均通过后才开放。当前单核运行属于已知限制。

本地组件测试不能证明 iPad Metal 推理、PPT 可编辑首帧、保存重开或双核 Guest 可用。新包需由用户重点复测：PPT 在工作区、手记和 IDE 中打开、编辑、保存、关闭重开；Office 退出时的取消与写回失败；本地模型加载、测速、连续两轮以上普通与工具对话。

## English

- Office open, close and save acknowledgements now settle once; late callbacks cannot revive a closed session. A PPT session can recover if a real slide paint arrives after its bounded warning. An unverified first frame is never treated as a successful open. If Notes cannot write the original back, the editor keeps its working copy and error instead of claiming a successful save or dismissal.
- After an inference failure or an MLX teardown error on an otherwise successful turn, the next local-model turn no longer reuses the unhealthy container. It unloads after both the last chat claim and any temporary benchmark lease end. Focused tests cover three ordinary/tool turns, cancellation and benchmark ownership.
- TinyEMU's dual-core option remains gated. An explicit request is not silently downgraded to one core; the option will open only after real-guest correctness, persistence and repeatable speedup qualify. One-core operation remains a known limit.

Component tests do not establish iPad Metal inference, a visible editable PPT slide, save/reopen or a usable dual-core guest. Device retesting should cover PPT open/edit/save/reopen in Workspace, Notes and IDE; Office exit cancellation and write-back failure; local-model load, benchmark, and at least two ordinary and tool-enabled chat turns.
