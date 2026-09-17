# Floe Agent 1.7.0 (181) — beta.38 candidate

**Preparing the corrected candidate; not uploaded.**

Release tag: `v1.7.0-beta.38` (source fixed when tagged). Build 180 was
cancelled before upload after real GitHub API validation found malformed query
URLs. This candidate preserves absolute API URLs and adds regressions that
reject the invalid relative requests previously accepted by the fixture.

## 简体中文

- IDE 增加 GitHub Actions 构建目标。提交前展示源码快照；仓库和工作流由用户选择。编译在 GitHub 运行，本机保留源码。
- 云任务由 App 持久管理。重新打开 App 后回读未完成记录并主动查询；退出 App 不会停止 GitHub 上的构建。不依赖模型轮询。取消需等待远端确认，提交结果不明时先查找原运行，不能自动重复触发。
- 手记封面区分真实 Quick Look 内容、明确标记的 Office 内容摘要与不支持状态。CAD 使用现有查看器生成封面；普通文档和思维导图保留各自的内容渲染。Office 摘要或格式图标不能充当真实缩略图验收。
- 新增 Node／Python 服务重启、删除环境停服和 Lua 安装执行卸载的 App 宿主验收用例。
- 发布流程为两个设备分别安排手记测试时间，并提前保留编译宿主与安装包以便恢复。

## English

- The IDE adds a GitHub Actions target with a reviewable source snapshot and an explicit repository/workflow selection. Compilation happens on GitHub; source files stay on the device.
- The App persists remote jobs and reconciles unfinished work after reopening. Remote builds continue while Floe is closed. Polling belongs to the App, not a model loop. Cancellation remains pending until confirmed; an uncertain submission is reconciled before any new dispatch.
- Notes covers distinguish real Quick Look content, explicitly marked Office summaries and unsupported results. CAD covers use the bundled viewer, while notebooks and mind maps render their own content. A summary or file icon cannot satisfy the real-thumbnail acceptance gate.
- App-hosted regression tests cover Node/Python service restart, environment deletion and Lua install/run/remove.
- Release qualification gives each device its own Notes test step and retains compiled hosts and packages before optional recovery work.

## Evidence and delivery

Focused source checks passed: 258 release-script tests (one skipped), asset
hashes, workflow lint, Notes Swift semantic checks, and the GitHub job engine/
transport harnesses. The corrected production GitHub client also passed real
read-only API requests, pagination and a digest-matched artifact download
([evidence](qualification/build181-release/github-actions/live-api.json)). The new App source has **not**
passed cloud compilation, simulator UI tests or upload validation yet. Component
or source checks do not establish full-App or physical-device acceptance.

Build 179 / beta.36 remains immutable at `a510ea6d`; its retained unsigned IPA
must not be relabelled as build 181. Build 178 remains the last confirmed internal
TestFlight release. No public Beta review has been submitted by this change.

Remaining physical checks include the reported iPad local-model ordinary-chat
crash, Pencil/Office interactions and native CAD rendering. Rust/Swift cloud
outputs are Linux/macOS artifacts, not iOS executables. Local PHP and RDP are not
claimed as delivered.

- [Durable IDE cloud jobs](IDE_GITHUB_ACTIONS.md)
- [Office/CAD thumbnail acceptance](NOTES_OFFICE_THUMBNAIL_ACCEPTANCE.md)
- [Runtime lifecycle acceptance](RUNTIME_LIFECYCLE_ACCEPTANCE.md)
- [Source-bound release recovery](ACCEPTED_SDK_RELEASE_RECOVERY.md)
