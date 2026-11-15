# Floe Android 1.0.12

独立分发 Full 版，版本代码 121；GitHub 安装包及应用内更新。

## 简体中文

- 修复本地环境历史较多时，新项目任务可能读不到自己的执行环境、无法发现终端工具的问题。项目过滤在原生目录编码前完成，较大的原生目录按完整分页读取。
- 环境目录读取失败时，在诊断详情中保留具体原因，避免只显示笼统的不可用状态。
- 分页检查版本、目录快照、项目和会话归属，目录变化、取消或超限时明确失败，保留现有权限与执行边界。

已知限制：特别大的全局环境目录仍可能影响计划任务的环境选择及容器清理；这些全局读取继续受现有接口大小上限约束。本次修复重点为项目所属任务的执行通路。

## English

Full edition for independent distribution, build code 121, with GitHub and in-app updates.

- Fixes new-project tasks losing their local execution target and terminal tools when the accumulated environment catalog is large. Project filtering now happens before native serialization, with complete bounded native pages.
- Retains specific catalog failure codes in diagnostic details instead of a generic unavailable state.
- Checks snapshot continuity and project/session ownership across pages. Changes, cancellation and size limits produce explicit failures under the existing execution and permission boundaries.

Known limitation: very large global environment catalogs can still affect scheduled-task environment selection and container cleanup, whose complete global responses retain their existing size ceiling. This update focuses on project-owned task execution.
