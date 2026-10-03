## Floe Agent 1.4.96 (Build 127)

### 简体中文

- **画布工具收归画布上下文**：`canvas.*` 工具（getState/applyOperations/generate 等）此前在每轮普通对话的工具目录中可见，现在仅在画布运行（runSurface=canvas）中提供。普通聊天不再暴露画布工具——既省目录空间，也杜绝了脱离画布绑定（canvasID）的误操作；画布运行内行为不变。
- 附带的普通聊天上下文收益：画布工作流指引行也只在画布运行中出现。
- 干净克隆完整编译验证通过（Xcode 26.3 beta 2 / iPhone 17e iOS 26.4 beta 2）。

这是内部测试版本，不开放外部公开 Beta。先完成自动测试、CI、签名上传，再分别核验 Apple VALID 与 Floe QA 可见性；真机验收项：普通聊天的工具目录不再出现 canvas.*（可问"列出可用工具"核验），画布运行内 canvas 工具照常可用。

### English

- **Canvas tools scoped to canvas runs**: `canvas.*` tools (getState/applyOperations/generate and friends) were previously offered in every ordinary chat's tool catalog; they are now provided only in canvas runs (runSurface=canvas). Ordinary conversations no longer see canvas tools — saving catalog space and ruling out canvas mutations without a canvasID binding; behavior inside canvas runs is unchanged.
- Side benefit: the canvas workflow guidance line now appears only in canvas runs as well.
- Clean-clone full compile verification passed (Xcode 26.3 beta 2 / iPhone 17e iOS 26.4 beta 2).

Internal testing only; no public beta distribution. Automated tests and CI precede signed upload, followed by separate Apple VALID and Floe QA visibility checks. On-device acceptance: ordinary chats no longer list canvas.* tools (ask "list available tools" to verify); canvas tools work as before inside canvas runs.
