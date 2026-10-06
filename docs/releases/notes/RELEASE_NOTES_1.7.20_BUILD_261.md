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

## Delivery verification / 交付核验 · 2026-10-06 UTC

- Immutable App source / 固定源码：`55061b66d294b7fc118d07b3441cd7f70bf503ef` (`v1.7.20`).
- Local Release device build / 本地设备构建：Xcode 27.0 (`27A266a`), iPhoneOS 27.0 SDK, passed. Cloud signing reused the exact local artifact without rebuilding.
- Signed artifact retained and SHA-256 verified / 签名产物已留存并校验：`2375fbb9e2da4902404c9f45c3925de552e4544d287d61b2c01962918301eae3`.
- Upload run `37502934952` uploaded successfully; its subsequent group association request returned HTTP 422. Independent read-only verification `37505606336` passed: Apple `VALID`, unexpired, existing internal `Floe QA`, `IN_BETA_TESTING`. The group page also showed Build 261 testing. No second upload was performed.
- 上传成功后分组请求返回 422；独立只读核验确认内部可安装，未重复上传。真机循环流程仍由用户复测，本轮未执行完整 CI 或外部送审。
- Task build caches, staging and redundant raw archive removed; current signed package, exact-source recovery package, symbols and failure/success evidence retained.
