# Floe Agent 1.7.0 (184) / beta.41

Source: immutable tag `v1.7.0-beta.41`.
Delivery status and evidence: [beta.41 record](RELEASE_1.7.0_BETA_41.md).

## 简体中文

- 按运行编号直接回读 GitHub 任务；恢复查询后清除过期错误，避免成功任务仍显示旧错误。

- 修正真实 GitHub API 查询地址，确保工作流、运行进度和产物列表可读取。

- IDE 新增 GitHub Actions 云端构建。App 保存运行记录，重新打开后自动查询未完成构建；取消需等待 GitHub 确认，不依赖模型循环等待。
- 云构建快照固定到源码提交；模板可查看后安装。日志、产物下载和失败信息集中显示，下载失败不覆盖原文件。
- 手记为 Word、Excel、PowerPoint、笔记、思维导图及支持的工程图纸生成内容封面。系统无法提供 Office 原始布局缩略图时，明确标记内容摘要。
- 增加 Node/Python 服务重启、删除环境停服、Lua 安装与卸载，以及云任务恢复的回归覆盖。
- 发布流程分开安排 iPad/iPhone 手记验收，并提前保存可恢复产物。

这是测试候选版本。云端运行依赖用户自己的 GitHub 配置；Linux/macOS 产物不能直接作为 iOS 程序安装。本地模型 iPad 稳定性、原生 Office/Pencil 操作及完整包/模型目录仍需各自验收。RDP 未作为可用 App 功能交付。

## English

- Resolve known runs by ID and clear recovered errors so successful jobs no longer display stale failures.

- Fixed absolute GitHub API query URLs for workflows, run progress and artifacts.

- The IDE adds GitHub Actions builds. The App retains jobs and automatically reconciles unfinished builds after reopening. Cancellation waits for GitHub confirmation rather than a model polling loop.
- Snapshots are tied to source commits. Reviewable workflow templates, logs, bounded artifact downloads and actionable errors are available in the run panel; failed downloads preserve existing files.
- Notes generates content covers for Word, Excel, PowerPoint, notebooks, mind maps and supported engineering drawings. An Office content summary is labelled when the system cannot provide the original-layout thumbnail.
- Added regressions for Node/Python service restart and environment deletion, Lua installation/removal, and durable cloud-job recovery.
- Release qualification gives iPad and iPhone separate Notes gates and retains recoverable build products early.

This is a test candidate. Cloud execution uses the user's GitHub configuration;
Linux/macOS artifacts are not installable iOS programs. iPad local-model
stability, native Office/Pencil operation and the full package/model catalog
require separate acceptance. RDP is not delivered as a usable App feature.
