# Floe Android 1.0.10 (118)

## 简体中文

- 修复停止一个任务后，新任务仍被误判为“用户已停止设备控制”的问题。
- 自动控制开启时，新任务使用自己的授权；旧任务的迟到收尾不会取消新任务的控制。停止后仍立即移除悬浮球和控制通知。
- 修正后台 Linux 依赖安装的审核上下文，与前台命令使用相同的真实执行环境；保留原生主机、远程操作和敏感动作的保护。
- Linux 收尾读取遇到临时错误后继续确认真实结束，不因读取失败或等待时间推定成功。

GitHub Full 预发布，使用完整安装包升级。复杂跨 App 视频及日历保存、重开仍需分别验证；此前失败录像不会计作通过，也不会自动重试结果不明的付费生成任务。

## English

- Fixes a stopped device-control task incorrectly blocking a new task.
- New tasks obtain their own authorization when automatic control is enabled. Late cleanup from an old task cannot cancel a newer owner's controls. Stop still removes the bubble and its notification immediately.
- Background Linux dependency review receives the same actual execution context as foreground shell work, while preserving native-host, remote-operation and sensitive-action safeguards.
- Transient cleanup-read failures no longer prevent a later real Linux completion receipt from being observed. Read failures and elapsed time never imply success.

This GitHub Full prerelease uses complete-package updates. Complex cross-app video and calendar save/reopen require separate acceptance. Earlier failed recordings remain failed; unknown paid-media outcomes are not automatically resubmitted.
