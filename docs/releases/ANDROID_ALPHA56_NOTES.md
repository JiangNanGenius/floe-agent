# Android 0.1.0-alpha.56 / code 82

This is an intermediate Android preview. It continues the agreed N01–N08 work; it does not declare every feature complete.

这是本轮 N01–N08 的中间预览版本，不代表所有功能已验收。

## Changes / 改进

- The workspace's external-editor action asks you to select the actual file instead of reopening the previous document. Completed history is collapsed and the active edit's save/finish controls remain visible.
- New empty files can be handed to an external editor through a verified read-only snapshot. Failed preparation retains its bounded diagnostic code in Details.
- Linux graphical applications explicitly use the current project's software layer. New tasks can reuse project software while preserving their real task ownership and existing session limits. Existing task environments are retained.
- GitHub, GHFast and GH-Proxy download-source selection remains available from Alpha55, including full-package fallback.

- 工作区外部编辑入口先选择实际文件，避免误开上次文档。已结束历史默认收起，当前编辑的核对／结束操作保持可见。
- 新建空文件可以通过校验后的只读快照交给外部编辑器，准备失败可在详情查看简短诊断码。
- Linux 图形软件明确使用当前项目的软件层，同项目新任务可复用软件，保留真实任务归属及既有会话上限；已有任务环境保留。
- 继续提供 Alpha55 的 GitHub、GHFast、GH-Proxy 下载源切换及完整包回退。

## Qualification / 验证

This source checkpoint precedes its focused native/JVM compilation and Samsung acceptance. The delivery record will distinguish actual build, device and public-download evidence; no unchanged full regression or paid generation replay is required.

本源码检查点先于本批定向原生／JVM 编译和三星验收。后续交付记录分别记录实际构建、设备行为及公开下载证据，不重复未改组件全量回归或旧付费生成。

## Known issues / 已知问题

- Project software scope does not automatically copy packages from older per-task environments. Those environments and user files remain available. Install missing graphical software in the project when needed.
- Cross-App automation, unattended unlock, scheduled UI recovery and some professional editor/CAD paths still require further Samsung acceptance and repair. This release is not evidence that those scenarios passed.
- Mirror availability varies by network. Installers still verify the target package, version, signature and digest; a mirror is not an alternative trust authority.

- 新项目软件层不会自动复制旧任务环境里的安装包；旧环境和用户文件仍保留。需要时在项目中安装缺少的图形软件。
- 跨 App 自动化、无人值守解锁、定时界面恢复及部分专业编辑／CAD 路径仍需继续三星实测修复，本版本不表示这些场景通过。
- 镜像可用性取决于网络，安装仍校验目标包身份、版本、签名和摘要。
