# Android 0.1.0-alpha.30 · code49

GitHub Full 中间预发布；本轮 N01–N08 继续推进，保留 iOS Latest。

## 本次更新

- 完整包升级包含 Linux 运行组件。Android 10 及以上在组件已安装、当前无执行工作且校验通过时，使用同一安装事务更新 App 和运行组件；较旧系统保留明确的组件更新入口。跨版本可直接下载完整 APK，不要求逐版安装。
- 专业文件默认交给 Android 默认应用；显式“选择其他应用”和 Linux 桌面软件入口保留。轻量文本、Markdown 和代码继续在 Floe 内编辑。
- Office 按需安装后可恢复此前选取的只读文档；预览不会建立未保存编辑。前置三星候选已验证组件安装造成 App 重启后的恢复和本地 DOCX 显示。
- 手机操作通知和可选悬浮控制增加暂停/继续；暂停阻止后续界面动作，接管/停止仍取消任务。继续需对应任务的有效用户操作。
- 修复条件触发队列满时无法排空，以及系统时间调整影响防抖和等待的问题；不确定的执行保留原事件身份，明确拒绝显示提示。
- 手动反馈支持四张截图，按整组预算压缩；显示上传进度、真实回执和可操作的失败信息。文字与附件分别限流，大图等待不再挡住纯文字发送。普通任务、工具和供应商错误不自动上报。
- Linux 准备失败保留具体阶段、错误类型和本机诊断；任务工具使用同一状态，不再统一误报为运行中。

## 已知问题与验证范围

- 这是允许存在故障的中间版本。新增代码通过相关编译和定向检查；当前包的三星升级、手机暂停/继续及条件触发仍需实际核对，不代表全部流程已验收。
- 四张约5MB图片的反馈在当前测试网络压缩后仍出现过超时，原故障保留；纯文字反馈已有三星及服务端接收回执证据。超时不会显示为上传成功，可查看状态后重试。
- 自动解锁需用户单独启用和配置，能力取决于锁屏方式、系统及权限；未验证的设备能力不保证无人介入。Root 仅在受控模拟器验证，真实笔与厂商差异保留反馈入口。
- 整体 UI 尚待集中优化，包含字号、信息密度、留白和开关/按钮比例。部分预览格式有能力边界，TIFF 仍未实现。
- 安装前保存正在编辑的文件；同步待完成或冲突时保留恢复副本，不删除项目数据。

---

Intermediate GitHub Full prerelease; the complete N01–N08 goal remains active and iOS Latest is preserved.

Changes: eligible Android 10+ installations update the main App and an already installed Linux runtime in one verified installation transaction; older systems retain an explicit runtime update route. Full APK downloads support direct cross-version upgrades. Professional editing uses the default Android app, with explicit alternate-app and Linux desktop options; lightweight editing remains in Floe. Office read-only previews survive on-demand component installation and App restart. Phone controls gain task-bound pause/resume while takeover/stop still cancels the task. Condition queues drain correctly when full, with monotonic debounce/waiting and honest clock-rejection notices. Manual feedback accepts four compressed screenshots, bounded uploads, progress, receipt/error handling and independent text/attachment lanes. Linux preparation exposes the actual failed stage and diagnostic state to both users and task tools.

Known limits: focused compilation/checks do not establish acceptance of every flow on this APK; Samsung upgrade, phone pause/resume and condition-trigger checks remain pending. Four large screenshots previously timed out on the test connection despite compression; a text-only report has a real Samsung/server receipt. Automatic reporting excludes ordinary task, tool and provider failures. Automatic unlocking requires separate consent/configuration and supported device permissions. A comprehensive UI pass remains pending; TIFF preview remains unimplemented. Save edits before installation and retain recovery copies for unresolved synchronization/conflicts.
