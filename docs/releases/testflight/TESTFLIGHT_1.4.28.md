# Floe Agent 1.4.28 (Build 59) TestFlight Notes

## What to test / 测试重点

- **Apple Foundation Model:** On iOS/iPadOS 27, verify ordinary prompts return natural language. For a tool request, confirm the approved real tool output is continued through the structured Apple transcript and the final response is natural language rather than raw JSON. Cancellation during navigation must not show a workspace error.
- **Downloaded local models:** Test Qwen 3.5, Qwen 3.8 and Gemma 4 one at a time on the iPad. Qwen tool calls must not recursively invoke the same resident model for approval. Gemma should enter the emergency 2K-context/256-output profile near the logged memory limit instead of being rejected merely because other apps are using memory.
- **Workspaces and recovery:** A new no-project task must show its private workspace immediately. Opening an older task with missing ownership metadata must repair and mount its private workspace without replacing a real project workspace. Resume must preserve completed tool evidence and must not execute an identical successful call again.
- **Task list:** Archive and delete must remove the task from the active sidebar immediately, with rollback if persistence fails.
- **Approvals:** Pending controls, the decision and the reason must appear inside the matching tool-call disclosure. Safe Apple reads, image generation/inspection, OCR, PDF reads and LAN discovery must not invoke the approval model. A broad “test all tools” request may run ordinary diagnostics; automatic/disposable SSH-container tests and environment preparation must not request approval per command, while host/network-device mutation remains reviewed.
- **Local permissions:** Selecting a local model must remove the old warning strip and make Full Access unavailable in both draft and existing-task permission sheets.
- **Picture in Picture:** Start a task, leave Floe through the inactive transition, and verify PiP starts with a rendered progress frame rather than black. Close PiP, return to Floe, leave again and confirm the controller is rebuilt.
- **Regression:** Recheck long cloud conversations, step folding, final-answer order, OpenAI Images, Nano Banana Pro, editable image-provider Base URLs, Git/GitHub, fonts and Data Management. These cloud and workspace capabilities must not be reduced by the local-model context policy.

## Reporting / 反馈要求

Include the build number, device model, iOS/iPadOS version, selected model/provider, exact action, displayed error and timestamp. For any process termination or PiP failure, upload the newest redacted diagnostics and attach current Xcode Organizer evidence when available. Do not send secrets, tokens, certificates or provisioning profiles.

请注明 Build、设备、系统版本、模型/服务商、操作步骤、界面错误和时间。若仍有闪退或画中画异常，请上传最新脱敏诊断，并在 Xcode Organizer 有当前版本证据时一并提供；不要发送任何密钥、Token、证书或描述文件。
