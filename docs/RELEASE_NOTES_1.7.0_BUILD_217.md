# Floe 1.7.0 (217) — device feedback repair / 真机反馈修复

Status: candidate for the existing private internal Floe QA TestFlight group and
the matching GitHub prerelease. Build, upload, Apple processing and group
availability are recorded separately after they occur.

## 简体中文

Build 217 集中修复本轮真机反馈：终端在 Linux 未安装时提供明确的下载并启动入口，模型也能通过受控的环境准备能力安装后继续原命令；下载任务在会话间共享，保留进度、取消、重试和具体错误。

Office 路径补充中文字体目录指纹与原生宿主重建，区分工作区独立 Office 编辑器和 IDE 内嵌标签，并修复 Pencil 批注输入门控，使手指继续浏览、Pencil 进入自由笔迹命令。IDE 增加源码管理侧栏和不依赖 Linux 的压缩包树形浏览。

本地模型每轮都会获得按预算精选且稳定保留的基础工具定义，不再依赖先调用 `tools.list`；同一执行链保留后续工具，并对“未执行却报告完成”进行一次有界纠正，仍失败时如实结束。

本轮按要求仅做定向代码、脚本和云端构建验证。Linux 下载、中文标题/正文/表格、Apple Pencil 跟手性及保存重开、Git 初始化、压缩包浏览和本地模型连续多轮调用仍由用户在真机安装后验收。

## English

Build 217 addresses the current device feedback. A missing Linux environment now
shows an explicit download-and-start entry, and models can use a controlled
preparation tool that resumes the original command after installation. Downloads
are shared across sessions with progress, cancellation, retry and specific errors.

Office now fingerprints the bundled CJK font catalog in the rebuilt native host,
keeps standalone workspace editing distinct from IDE-embedded tabs, and gates
annotation input so a finger can navigate while Apple Pencil uses the freehand
command. The IDE adds an integrated source-control sidebar and bounded archive
browsing that does not require Linux.

Local models receive a stable, budgeted base tool set on every turn instead of
depending on `tools.list`. Tools needed by the active chain remain available, and
an unexecuted completion claim receives one bounded correction before the run
ends honestly.

Validation is intentionally focused: source, script and cloud-build gates only.
Linux download behavior, CJK rendering, physical Pencil feel and save/reopen, Git
initialization, archive browsing and multi-turn local tool use remain for device
acceptance.
