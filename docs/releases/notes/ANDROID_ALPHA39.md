# Android 0.1.0-alpha.39

修正 Linux／远程查看器在软件选择页与画面之间切换后的可见状态：使用界面提供的真实生命周期，进入查看器时立即同步当前前台状态，离开时继续暂停取帧并释放输入。修复手机应用选择窗口“完成”按钮占满标题栏，并更新无选择提示。

## Known issues / 已知问题

这是 N01–N08 中间版本。构建前尚未完成本次图形首次显示修复的三星复测；此前首次黑屏故障记录保留。手机模型已能实际启动和观察所选计算器，完整多步流程仍未通过；人工审批模式仍要求明确批准，不能把手机自动控制开关等同于任务自动审批。条件触发、专业编辑保存、跨项目隔离及按需组件生命周期继续验收。单条历史显示上限4MiB，完整导出保留。本轮未重放付费图片／视频生成。

## English

Linux and remote viewers now use the composition-provided lifecycle and synchronize foreground visibility on entry. Returning from the software picker resumes frame delivery; leaving still pauses frame reads and releases input. The app chooser keeps Done within a compact trailing button and updates its empty-selection hint.

This is an intermediate N01–N08 build. Samsung acceptance of this first-display repair is pending at source freeze; original black-frame evidence is retained. The model has launched and observed the selected calculator, but a complete multi-step phone workflow is still unverified. Human approval mode keeps its explicit decisions; phone-control consent does not change the task approval policy. Conditions, professional editor saves, project isolation and component lifecycle acceptance continue. Individual history display is bounded at4MiB with full export retained. No paid image/video generation was replayed.
