# Android 0.1.0-alpha.60 / code86

This intermediate preview continues N01–N08. Whole-App acceptance remains in progress.

- Execution Location refreshes the available environments when opened, includes the current target and labels project-shared software clearly. Existing task pins remain unchanged until an explicit migration. Replies from an older task, request or released controller cannot replace the current list.
- Background phone-control cleanup now follows the actual run-state transition, without waiting for the task list or conversation to return to the foreground. Delayed cleanup cannot clear a newer task's controls.
- Linux graphics reports the real disconnected or failed session and provides bounded diagnostic details. A refused transcript export displays a message instead of silently returning.
- New workspace output paths resolve existing symbolic-link components before the workspace and explicit-mount checks, including when the output does not exist yet.

Focused JVM and Swift host checks passed, including Full/Play Kotlin compilation. ARM64 production, exact APK and Samsung behavior are recorded separately; compilation does not prove device behavior.

Known limits: model use of the project graphical session, background phone-control cleanup and intermittent export failure still need the new package's device acceptance. The preceding scheduled external-edit case completed after manual system unlock; unattended automatic unlock is not accepted. Other editor, preview and UI work continues. Existing originals, failures and recovery copies are preserved.

---

本版是N01–N08的中间预览，整轮验收继续。

- 打开执行位置时重新读取可用环境，显示当前目标并区分项目共享软件。已有任务目标只有显式迁移才改变；旧任务、旧请求及已关闭控制器的回执不会覆盖当前列表。
- 后台手机控制直接跟随实际运行结束收尾，不再等待任务列表刷新或返回聊天。旧任务延迟收尾不能清除新任务的控制入口。
- Linux图形界面显示实际断连／失败状态，并提供有界诊断详情；任务导出被拒时给出提示，不再静默返回。
- 工作区新输出在边界检查前逐段解析已有符号链接，覆盖尚不存在的输出文件，同时保留明确授权的挂载目录。

相关JVM和Swift宿主检查及Full／Play Kotlin编译通过；ARM64生产、精确APK与三星行为另行记录，编译不代替实机验收。

已知限制：模型使用项目图形会话、后台手机控制收尾及间歇性导出故障仍需新包实测。上一条定时外部编辑在人工系统解锁后完成，不代表无人值守自动解锁通过。其余编辑器、预览和界面功能继续推进，原件、原始故障及恢复副本保留。
