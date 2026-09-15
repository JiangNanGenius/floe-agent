# Real Floe Agent demonstration — Build 175

[Watch the 52-second review clip](floe-real-agent-demo-build175.mp4). This is the actual full Floe App on iPad Simulator, using Volcengine Ark `deepseek-v4-1-flash-260910`. Source: `8958d8f1482c3236f73172076b76adc83da86f5f`. [Successful cloud run](https://github.com/JiangNanGenius/floe-agent/actions/runs/34949317123).

The model created `review-demo.md`, received the actual write result, read the saved file through `workspace.readFile`, and completed its response. Both tool results are `ok`; there are no recorded run errors. The saved UTF-8 Markdown is 538 bytes, with SHA-256 `42b75d3126cdae2c0023f0eb2803790ad7dee0850b1dcc6851554437afb7947c`.

[Generated Markdown](review-demo.md), [durable run evidence](live-agent-evidence.json), [video validation](review-video-validation.json), [same-run document preview](live-agent-output-preview.png).

The clip removes initial simulator startup waiting and trailing test-runner app termination, and holds its actual completion frame for four seconds. The original 94.878333-second recording is retained privately. No response or tool result was substituted. Credential entry took place outside the recording. The temporary GitHub credential was removed and its absence verified. Generated image/video API use remains zero.

This Build 175 clip demonstrates the ordinary Agent path. It does not claim that the later Build 176 Notes interface or physical devices passed validation. Reviewers receive no developer API key or cloud credits; their own configured provider is needed to reproduce the cloud call interactively.

## 中文

这段视频来自真实 Floe App：火山引擎上的 DeepSeek 实际调用创建文件、读取文件工具，并成功结束任务。产物及哈希已独立核对。视频为 Build 175 的 iPad 模拟器录屏，不冒充后续手记界面或真机验收。凭据配置未录入视频，临时凭据已删除；不向 Apple 提供 Key 或云端额度。没有调用生图、生视频接口。
