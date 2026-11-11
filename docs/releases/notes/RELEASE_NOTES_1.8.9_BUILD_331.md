# Floe 1.8.9 (331)

## 简体中文

- 修复打开气压计、指南针、陀螺仪等测量工具时的闪退，并修复同类声音采集回调问题。
- 自定义倒计时改用时、分、秒滚轮，支持上下滑动选择时长。
- 修复部分旧化学项目无法删除、提示“未授权”的问题。
- 修复部分生物项目无法从回收站彻底清理的问题，并保留删除失败后的继续清理能力。
- 修正部分完成按钮和本地终端屏幕错误提示的显示。
- 目标设置成功后，输入框返回普通 Agent 模式；保存失败时保留目标表单与草稿，便于修改重试。
- 支持 AI 为当前已授权任务设置目标，并提示目标暂停、继续和受阻状态。

本次为中间内测更新。请重点检查测量工具的打开和退出、倒计时设置，以及旧项目的删除、恢复和回收站清空。也请检查目标保存成功或失败后的输入框行为、AI 为当前任务设置目标，以及暂停、继续和受阻提示。Linux GPU 与新增视频硬件解码另行继续，后续完整版本再安排公开 TestFlight。

## English

- Fixes crashes when opening the barometer, compass, gyroscope and related measurement tools, and corrects the same callback issue in sound capture.
- Uses hour, minute and second wheels to set a custom timer by scrolling.
- Fixes an unauthorized error when deleting some older chemistry projects.
- Fixes permanent deletion of some biology projects from Trash while preserving recovery after an interrupted cleanup.
- Corrects some Done buttons and the local terminal screen's error display.
- Returns the composer to Agent mode after a goal is saved; a failed save keeps the goal form and draft for retry.
- Lets AI set a goal for the current authorized task, with clear prompts when a goal is paused, resumed or blocked.

This is an intermediate internal beta. Please check opening and leaving measurement tools, timer setup, deleting and restoring older projects, and emptying Trash. Also check the composer after successful and failed goal saves, AI goal setting for the current task, and paused, resumed and blocked prompts. Linux GPU and new hardware video decoding work continues separately; public TestFlight is planned for a later complete update.
