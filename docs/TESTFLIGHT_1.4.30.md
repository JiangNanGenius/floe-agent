# Floe Agent 1.4.30 (Build 61) TestFlight Notes

## What to test / 测试重点

- **Picture in Picture / 画中画：** Start a task with PiP background execution enabled, leave Floe both while the preview is still preparing and after it becomes ready, then return and leave again. PiP should start without a black frame, and a background transition must not cancel preparation or create a second competing controller.
- **Run status / 运行状态：** As soon as reasoning, answer tokens or a tool request arrives, the timeline must stop showing the stale “Preparing / 正在准备” launch row and show the live generation/tool state.
- **Apple Foundation Model:** Ordinary conversation must receive a natural answer. Requests requiring current information, such as weather or web lookup, must use the native Foundation Models tool interface; Floe now requires a native call for an action turn and reports schema conversion failures honestly.
- **Downloaded MLX models:** Qwen/Gemma receive a smaller reliable tool set for web search/fetch, workspace text operations, read-only document/image work, bounded local execution, memory recall and read-only Git. A common `browser.get` JSON call is normalized to `web.fetch` instead of leaking raw JSON. Switching from a cloud model explains these limitations before loading.
- **Workspace and files:** A task without a project must mount its private workspace automatically in the right inspector. An existing task should reopen the same workspace rather than briefly showing an empty inspector. Settings → Files opens the real file manager; storage/archive/cache cleanup remains under Data Management.
- **Bundled Python:** `dis` and `_opcode` must import in the signed app. Direct script-level pip remains unavailable; reviewed pure-Python packages continue through the managed `packages` argument.
- **Regression:** Recheck recovered tasks, duplicate-tool prevention, inline approval details, archive/delete list updates, LAN discovery, image providers, Git/GitHub and long cloud conversations. The local prompt policy must not reduce cloud-provider context or tool schemas.

## Reporting / 反馈要求

Include Build 61, device model, iOS/iPadOS version, selected model, exact prompt/action, result and timestamp. For PiP, include whether Floe was left during preparation or after readiness. Upload the newest redacted diagnostics and current Xcode Organizer evidence for any process termination; do not send secrets, tokens, certificates or provisioning profiles.

请注明 Build 61、设备、系统版本、模型、具体提示词/操作、结果和时间。画中画问题请注明是在准备期间还是就绪后离开 Floe。若进程退出，请上传本次最新脱敏诊断和当前 Xcode Organizer 证据；不要发送任何密钥、Token、证书或描述文件。
