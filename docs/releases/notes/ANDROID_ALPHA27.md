# Android Alpha27 — 中间预发布 / Intermediate prerelease

版本 / Version: `0.1.0-alpha.27` (`46`).

## 更新内容

- 外部文件回传前，区分编辑器短暂读取／选区刷新与真正的未保存编辑；冻结输入后有界等待，保留原有草稿、版本和冲突保护。
- Linux 图形会话重新打开时先检查已有基础组件；组件齐全时不重复访问软件源。首次缺少组件仍走安装路径。
- 项目内复用图形会话时，文件操作使用当前任务的真实工作区归属；终端读取继续携带原会话及运行代次。

## 已知问题

- 本包继续用于快速迭代。新增修复、图形文件保存回传、按需组件安装和真实完整／增量升级仍需三星实测；代码与编译结果不代表设备行为通过。
- 真正的未保存草稿仍会暂停外部回传。请先处理内置编辑器的修改，再核对外部副本；不会自动丢弃草稿或覆盖原件。
- 自动解锁未在本轮三星启用；定时、跨 App 操作及不同设备限制继续迭代。

## Changes

- Distinguish pending editor reads/selection refresh from real unsaved edits before an external return. Fence new input, wait within a bounded window, and retain draft/version/conflict protections.
- Reuse installed Linux graphical components without contacting package servers on every restart. Missing components retain the initial installation path.
- Attribute file operations to the current task when a project reuses a graphical session; guest reads retain the original terminal session and runtime-generation checks.

## Known issues

- This remains an intermediate iteration. New fixes, graphical file return, optional component installation and real full/delta upgrades still require Samsung use; source and compilation are separate from device acceptance.
- Real unsaved drafts continue to pause external returns. Resolve the built-in edits, then recheck the external copy. No draft is automatically discarded and no original is force-overwritten.
- Automatic unlock was not enabled in this Samsung round; scheduling, cross-app behavior and device-specific limits remain in iteration.
