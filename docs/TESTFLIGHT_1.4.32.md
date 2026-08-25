# Floe Agent 1.4.32 (Build 63) TestFlight Notes

## What to test / 测试重点

- **Apple Foundation multi-turn / 多轮：** Complete an ordinary first reply, then send a second request in the same task, including one that needs drawing or another tool. The second run must leave “preparing”, preserve prior user/assistant context, and either stream content or show a bounded error instead of spinning indefinitely.
- **Local context / 本地上下文：** Qwen and Gemma now use an 8K minimum dynamic context, 12K under balanced pressure and 16K when roomy. Confirm a tool round-trip no longer consumes most of the advertised window. The uploaded diagnostic should include the selected tier, context, batch size and available memory before/after each local inference.
- **MLX stability / 稳定性：** Exercise one Qwen tool call and one completed Gemma reply on the iPad. Floe must clear completed-turn scratch/KV cache without unloading the active model, and must not exit after the tool result or final answer.
- **Python and WASM / Python 与 WASM：** Install a small pure-Python wheel such as `marko` through the reviewed managed installer. Then request a NumPy/pandas calculation: the model should create a workspace HTML artifact and use visible-browser Pyodide/WASM with bounded JSON, not repeatedly attempt an incompatible native iOS wheel.
- **Picture in Picture / 画中画：** Enable PiP, start a task and leave Floe both during video preparation and after it is ready. A deferred start must survive the inactive transition, the PiP must show rendered progress instead of black, and no internal preview tile may cover foreground controls.
- **Browser and Settings / 浏览器与设置：** Open the browser inspector and verify sidebar, top status and Settings navigation remain tappable. Browser takeover is a compact address-bar action, not a floating overlay.
- **Search / 搜索：** With Bocha configured, both `web.search` and `web.searchAI` must be exposed simultaneously. Ordinary search returns sources without forced AI summary; AI search requests Bocha summary using the same editable endpoint.
- **Usage / 用量：** Apple Foundation and downloaded local models should show their real configured/system context window. Token totals remain formatted with K/M/B units and do not display unreliable cache-write statistics.

## Reporting / 反馈要求

Include Build 63, device model, iOS/iPadOS version, selected model/provider, exact first and second prompts, result and timestamp. For a local-model exit or Apple second-run stall, upload only the newest redacted Floe diagnostic and matching Xcode Organizer/device evidence. Do not send secrets, tokens, certificates or provisioning profiles.

请注明 Build 63、设备、系统版本、模型/服务商、第一轮和第二轮的准确提示词、结果及时间。本地模型退出或 Apple 第二轮卡住时，只上传本次最新的脱敏 Floe 诊断及对应的 Xcode Organizer/设备证据；不要发送密钥、Token、证书或描述文件。
