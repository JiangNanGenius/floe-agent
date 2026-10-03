# Floe Agent 1.4.31 (Build 62) TestFlight Notes

## What to test / 测试重点

- **Picture in Picture / 画中画：** Start a task with PiP background execution enabled. The hidden source view must remain behind Floe's root content and never cover the composer buttons. Leave Floe during preparation and after readiness; PiP should start with rendered content rather than a black frame.
- **Run continuation / 继续执行：** Continue or steer a run just as it finishes. Floe must queue the input for the next run instead of showing `The target run is no longer active`, losing context, or replaying successful tool calls.
- **Apple Foundation Model:** Ordinary conversation must return natural language. Tool requests must be executed through the native Foundation Models integration, with stale preparing rows cleared as soon as generation or tool activity begins.
- **Downloaded MLX models:** Qwen and Gemma may call exact safe tools from the authoritative local directory even when a schema was omitted from the small native schema budget. After a tool result, raw JSON must not leak as the final answer. Device termination still requires current Organizer/device or uploaded diagnostic evidence; the Mac validation never maps model weights.
- **Provider and model switches:** Each provider and each individual cloud/local model can be disabled without deleting credentials or downloaded weights. Disabled entries remain editable in Settings but disappear from the task model picker, which groups Apple/local models separately from each cloud provider.
- **Workspace and files:** The home composer exposes workspace management again. Private task workspaces mount automatically in the inspector, and existing tasks reopen the same persisted root.
- **Bundled Python:** Approved declarative `pip` installs create their staging and target directories before download and retain the pure-Python-only quarantine/review boundary.
- **Usage:** Large token totals use K, M and B units. Cache-write values are no longer shown because most providers do not report them reliably.

## Reporting / 反馈要求

Include Build 62, device model, iOS/iPadOS version, selected model/provider, exact prompt or action, result and timestamp. For PiP, include whether Floe was foregrounded and whether the source view covered any controls. Upload only the newest redacted diagnostics and current Xcode Organizer evidence for a process termination; do not send secrets, tokens, certificates or provisioning profiles.

请注明 Build 62、设备、系统版本、模型/服务商、具体提示词或操作、结果和时间。画中画请注明 Floe 是否在前台、源画面是否遮挡按钮。若进程退出，只上传本次最新的脱敏诊断和当前 Xcode Organizer 证据；不要发送任何密钥、Token、证书或描述文件。
