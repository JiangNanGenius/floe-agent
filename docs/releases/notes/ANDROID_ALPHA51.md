# Android Alpha51 / Android Alpha51

- 定时任务改用可读的触发方式菜单；模型标明提供商，所有选择按真实编号保持，项目切换更新环境选择。
- 补齐计划环境的项目归属、状态和执行后端信息；环境列表仅显示当前项目可用的 Linux 目标，未就绪的原目标保留待处理。
- 新计划使用已有全局审批默认值；已有计划和明确选择保持。返回页面时刷新后台产生的执行回执。
- 网络条件按系统回调事件记录断开和验证状态；新增持久事件接续已有工作链，补充有限的传输诊断。
- Scheduled tasks use readable trigger menus, provider-qualified model labels and exact choice IDs. Changing projects updates the environment selection.
- Environment options carry actual ownership, state and backend metadata; the editor offers eligible project Linux targets and retains unavailable saved targets for repair.
- New plans use the existing global approval default while saved and explicit choices stay unchanged. Resuming the page refreshes background receipts.
- Network conditions record ordered callback states. Fresh durable edges continue the existing work chain, with bounded transport diagnostics.

## 已知问题 / Known issues

这是持续迭代的中间版本。上一版三星锁屏网络触发没有生成运行记录，原现场保留，本轮修复仍需按真实场景确认。手机观察间歇失效、跨项目图形隔离、专业软件保存及全局界面精修继续推进；本版不代表全应用验收完成。

This intermediate build does not represent full-app acceptance. The previous Samsung locked-screen network trigger produced no occurrence; its original evidence is retained and this repair still needs scenario-specific confirmation. Intermittent phone observations, cross-project graphics isolation, professional editor saves and broader UI refinement remain under iteration.

## 更新 / Updating

完整 APK 支持跨版本升级，增量失败时可选择完整包。安装前请保存正在编辑的文件。

The full APK supports cross-version upgrades. Use the full package if a delta fails, and save open documents before installing.
