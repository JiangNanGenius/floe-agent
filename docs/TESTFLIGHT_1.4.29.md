# Floe Agent 1.4.29 (Build 60) TestFlight Notes

## What to test / 测试重点

- **Downloaded MLX models:** On the M4 iPad, test Qwen 3.5/3.8 through a real tool call and its follow-up answer, then test Gemma 4 through a complete ordinary reply. Each run should remain alive after generation. The constrained profile now uses its actual 32-token prefill chunk, a quantized KV cache and per-generation cache release; only one model remains resident.
- **Apple Foundation Model:** Verify greetings and ordinary questions receive a natural answer without asking for a more explicit task. For an Apple tool request, the model must use only the native Foundation Models tool channel; raw `tool_call` JSON must remain text and must never be promoted into a real call. After a tool result, the final answer should follow the original prompt → tool call → tool output order.
- **R and Stata compatibility:** Use `exec.localNumerical` for R-compatible summary/quantile/correlation and Stata-compatible `generate`, `summarize`, `correlate` and one-predictor `regress`. Confirm unsupported full-runtime features say that licensed Stata or native Python packages require a configured SSH host rather than pretending a local package was installed.
- **Regression:** Recheck private-workspace mounting, task recovery without duplicate tools, archive/delete list updates, approval details inside tool steps, PiP, LAN discovery, Git/GitHub, image providers and long cloud conversations. Local-model prompt budgets must not reduce cloud-provider context or tool schemas.

## Reporting / 反馈要求

Include the TestFlight build number, device model, iOS/iPadOS version, selected model, exact prompt/tool, result and timestamp. For a process termination, upload the newest redacted diagnostics and current Xcode Organizer evidence if available. Do not send secrets, tokens, certificates or provisioning profiles.

请注明 TestFlight Build、设备、系统版本、模型、具体提示词/工具、结果和时间。若仍闪退，请上传最新脱敏诊断，并在 Xcode Organizer 有当前证据时一并提供；不要发送任何密钥、Token、证书或描述文件。
