# Floe Android 1.0.14

独立分发 Full 版，版本代码123。

## 简体中文

- 新增当前任务的后台作业面板，可查看真实状态、进度和结果是否可读取，并逐项取消。取消请求会保持“正在停止”，直到实际执行结束。
- 后台命令使用后台默认执行预算，并保留用户显式设置的短超时；超时原因传递到实际运行时，分别提示超时和主动停止。
- 补齐后台作业完成后的原任务接续，以及等待期间的停止入口。系统不允许后台启动时保留任务，供用户打开应用后继续；停止、旧回调和不确定的重启结果不会触发自动续跑。
- 修正停止控制、任务结束，以及控制服务断开后的浮球清理；操作面板继续自动收为小气泡。
- 改进工具参数发现和名称兼容，修正已经安装的 Linux 环境仍被旧状态提示需要重装的问题。
- 调整手机等待栏与作业弹窗，减少重复的继续入口和文字挤压。

已知限制：本版仍为预发布。复杂长任务、跨 App 成果验收和部分 Linux 常驻服务继续迭代；取消后的资源清理可能需要等待实际进程结束。未完成的长任务验收不计为通过。

## English

Full edition for independent distribution, build code123.

- Adds a background-jobs panel for the current task, showing durable state, reported progress, result availability and per-job cancellation. A cancellation request remains in progress until execution actually settles.
- Background commands use their background time budget by default while honoring explicit shorter limits. Timeout causes reach the real runtime so deadlines and user stops retain distinct results.
- Connects completed background work to the original waiting task and keeps Stop available while it waits. If Android refuses background execution, the task stays recoverable. Stop, stale callbacks and uncertain restart outcomes do not start an automatic continuation.
- Fixes floating-control cleanup after control stops, the task ends or its driver disconnects. The expanded panel continues to collapse into a small bubble.
- Improves complete tool-parameter discovery and name compatibility, and refreshes stale Linux-component status instead of incorrectly requesting reinstallation.
- Refines phone waiting controls and the jobs sheet, reducing duplicate Continue actions and cramped text.

Known limits: this remains a prerelease. Complex long tasks, cross-app output acceptance and some managed Linux services remain under iteration. Cancellation cleanup may need to wait for the real process to end. Incomplete long-task acceptance is not counted as passed.
