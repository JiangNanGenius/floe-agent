# Android Alpha50 / Android Alpha50

- 补接 Office 关闭前的文档状态回执，等待对应引擎进程结束后核对文件，再结算本次关闭。缺少证据时保留恢复副本。
- Office 页面内的关闭按钮与返回键共用保存／放弃提示；关闭后拒绝后续页面输入。
- 手记 Office 返回也核对关闭回执与进程退出；选择放弃时不会导入此前的另存副本。
- Office close now carries a sealed document snapshot. The host waits for the exact engine process to exit and verifies its owned file before reconciling recovery state. Missing evidence preserves recovery data.
- The Office page Close action follows the same save/discard guard as Back; closing mounts reject further page input.
- Notes Office handoff also verifies the close receipt and engine exit. Discard never imports an earlier Save Copy result.

## 已知问题 / Known issues

这是持续迭代的中间版本。Office 保存、放弃、手记文件返回和来源引用释放仍需按实际场景逐项确认；部分手机观察失效、系统条件任务、专业软件及整体界面精修仍在原计划中推进。本版不代表全应用验收完成，安装前请保存正在编辑的文件。

This intermediate build does not represent full-app acceptance. Office save/discard, Notes handoff and source-reference retirement still need scenario-specific confirmation. Intermittent phone observations, conditional schedules, professional software and broader UI refinement remain under iteration. Save open documents before updating.

## 更新 / Updating

完整 APK 支持跨版本升级。增量更新失败时，可选择完整安装包；保留现有应用数据，系统仍会要求安装确认。

The full APK supports upgrades across versions. Use the full package if a delta fails; Android still asks for installation confirmation.
