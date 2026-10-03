# Floe Agent 1.4.25 (Build 56) TestFlight Notes

## What to test / 测试重点

- **Apple Intelligence:** On an eligible iOS/iPadOS 27 device, open **Settings → Local Models** and confirm Apple Foundation Model reports the real system state. Run a text request and a tool request. If unavailable, capture the displayed reason; there is no separate Floe download or API-key setting.
- **Downloaded local models:** Load Qwen 3.5, Qwen 3.8 and Gemma 4 one at a time. Verify that a memory rejection is recoverable, a failed/unloaded model releases its cache, and Qwen can see and call the intended bounded tools. Export the newest device/Xcode or uploaded diagnostic log after any process termination.
- **Task continuity:** Start a multi-step task, let several tools succeed, background or interrupt it, then resume. Completed identical tool calls must not run again; context, plan, files and progress must remain present.
- **Approvals:** Expand a tool step and verify the approval result/reason is shown there. Image generation/inspection, OCR, read-only PDF, bounded reads and LAN discovery should not wait for an approval model. A broad “test all tools” request may run safe diagnostics but must still exclude destructive and credential tests.
- **SSH:** Prepare a normal environment on an explicitly selected host. Matching bounded operations should reuse approval rather than asking for each command; deletion, credentials and broad mutation must still stop for review.
- **Workspaces and source control:** Create a task with no project and confirm its private workspace appears immediately. In the Files inspector, initialize Git, review a diff, stage, commit and create/switch a branch. Connect GitHub with a fine-grained token, then list or clone a permitted repository. The token must remain device-Keychain only.
- **Remote workspace payload:** Inspect or bootstrap an authorized SSH host, then provision and reopen a private cloud workspace. The bundled remote-agent and updater sources must be found without a missing-resource error.
- **Images:** Add OpenAI `gpt-image-2` and Google Nano Banana Pro (`gemini-3-pro-image`) as dedicated image providers. Test generation/editing through both their default API URL and an editable compatible proxy Base URL.
- **Local network:** Permit Local Network access and run LAN discovery on the same network. It should return declared Bonjour services or a clear permission/network result without approval-model delay.
- **Picture in Picture:** Keep Floe foregrounded until the task-progress preview is ready, leave the app, return, and repeat with a new task. The PiP surface must show real progress instead of a black frame and must be recreated after a prior session closes.

## Reporting / 反馈要求

Include the build number, device model, iOS/iPadOS version, selected model/provider, exact action, displayed error, and timestamp. For local-model termination or PiP failures, attach the newest Xcode/device crash evidence or the app's uploaded redacted diagnostics. Do not send API keys, tokens, certificates, provisioning profiles or private host credentials.

请同时注明 Build 号、设备型号、系统版本、所选模型/服务商、操作步骤、界面错误和时间。遇到本地模型退出或画中画异常时，附上最新 Xcode/设备崩溃证据或 App 已上传的脱敏诊断；不要发送 API Key、Token、证书、描述文件或主机凭据。
