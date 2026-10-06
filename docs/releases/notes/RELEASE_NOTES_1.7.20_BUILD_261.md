# Floe Agent 1.7.20 · Build 261

## 简体中文

- 修复 Linux 网络连接断开时 SIGPIPE 可能终止 App 的问题。
- 增加跨重启保留的 Shell 和服务启动/停止阶段记录，不记录命令正文、参数或输出。
- 诊断上传单独保留执行阶段记录，便于定位重复运行后的异常退出。

本次按用户要求采用内部 TestFlight 短流程，跳过完整 CI、模拟器矩阵及外部送审。定向测试通过不代表本次真机闪退根因已经确认，请复测服务反复启动、停止及会话恢复。

## English

- Prevent disconnected Linux network sockets from terminating the host through SIGPIPE.
- Retain bounded shell and service lifecycle checkpoints across launches, without commands, arguments or output.
- Include execution checkpoints as a dedicated diagnostics upload section.

Expedited internal TestFlight requested by the user. Full CI, simulator matrix and external review are skipped. Focused checks do not establish the cause of the reported device crash. Please retest repeated service startup, shutdown and session recovery.
