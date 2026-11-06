# Android 0.1.0-alpha.34

修复冷重开任务后执行历史不显示的问题：直接读取任务所属存储的有界历史页，显示已记录助手片段、推理及工具，支持更早记录。回放只用于展示，不恢复旧任务、不重新触发审批或工具。

更新成功后的完成／关闭操作会清理成功状态，下一次手动检查不再被旧回执禁用。完整包跨版本下载与已有增量失败回退保持可用。

这是 N01–N08 功能修复中间版。Full/Play Kotlin 编译、3项历史投影定向检查及 ARM64 原生对象／链接已有证据；本冻结版本的三星冷重开和更新状态验收将在构建后进行。原四张大图反馈上传超时、完整手机跨 App 任务、条件调度／Linux GUI 和组件生命周期等仍按原台账修复；未声明整轮验收完成。超出单条事件页预算明确报错，完整任务仍可导出。全局字号、控件密度与材质精修继续后置。没有新增模型／图片／视频调用。

Restores cold task execution history through bounded reads from the run's owned journal, including recorded assistant segments, reasoning and tools. Earlier history can be loaded without reopening a live stream. Replay never resumes the run, changes approvals or executes tools.

Completing or dismissing an installed-update receipt now clears its settled state so the next manual check remains available. Cross-version full-package download and incremental-failure fallback remain available.

This is an intermediate N01–N08 repair release. Targeted Kotlin checks and ARM64 production compilation are recorded; Samsung acceptance of this immutable candidate follows its build. The original four-image upload timeout and remaining cross-App, condition, GUI and component-lifecycle flows are not declared accepted. A single journal entry over the page budget fails explicitly; complete task export remains available. Global visual refinement is deferred until functional closure. No new model or media-generation call was made.
