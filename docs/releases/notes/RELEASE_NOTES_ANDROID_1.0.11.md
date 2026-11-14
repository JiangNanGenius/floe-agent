# Floe Android 1.0.11 (119)

## 简体中文

- 屏幕操作结束或停止控制后，立即收起悬浮球；后台任务继续运行时也不会留下一颗失效的控制球。
- 修复长任务中 Linux 终端连接反复注册、最终导致应用闪退的问题。连接按会话复用，并在关闭时释放。
- 终端遇到连续拒绝时降低轮询频率，保留真实错误，不重复提交结果不明的命令，也不把等待结束当作执行成功。

- 补齐长回复与思考记录的分页读取，保留任务和版本归属校验；未完整读回时明确显示部分记录。
- 修复 Markdown 队列丢弃旧解析后不清理等待状态的问题，减少长对话的无效重复刷新。

- 修复较旧系统阻止本机网页预览的问题，终端服务和文件预览可以访问设备本机地址。

GitHub Full 预发布，使用完整安装包升级。复杂跨 App 视频制作和日历保存、重开仍需独立验收；此前失败的任务不会自动继续，结果不明的付费生成不会自动重试。

## English

- Removes the floating control bubble when screen actions finish or control stops, including while the background task continues.
- Fixes repeated Linux terminal connection registrations that could eventually crash long-running tasks. Connections are reused per session and released on close.
- Backs off repeated terminal polling refusals while preserving the actual error. Commands with unknown outcomes are not resubmitted, and elapsed time never implies successful execution.

- Connects paged reads of long answers and reasoning to the native task-owned reader. Incomplete reads are labelled as partial records.
- Cleans up discarded Markdown parse requests and avoids unnecessary refreshes in long conversations.

- Fixes local web previews being blocked on older Android versions, enabling task previews and terminal services on the device loopback.

This GitHub Full prerelease uses complete-package updates. Complex cross-app video creation and calendar save/reopen require separate acceptance. Earlier failed tasks are not automatically continued, and unknown paid-generation outcomes are not automatically retried.
