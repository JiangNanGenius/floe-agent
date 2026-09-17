# Floe Agent 1.7.0 (183) — beta.40 candidate

**Tagged candidate; cloud qualification running, not uploaded.**

Immutable source: `0b7f7903c9fd851b9d9e278249766c39d5069cf1` / `v1.7.0-beta.40`.
[Release run 35284117684](https://github.com/JiangNanGenius/floe-agent/actions/runs/35284117684)
runs the complete two-SDK qualification.

This candidate retains the durable IDE GitHub Actions jobs, document content
covers and runtime lifecycle qualification introduced in builds 179–182. It
corrects the App integration defects discovered by build 182: GitHub type
imports, optional workspace file-service handling and cloud-job ownership.
The release pipeline separately resolves Xcode dependencies with at most three
network-only attempts, retains failures, and verifies the actual workspace lock
against the committed pins. Equivalent lock formatting does not count as drift.

Preflight: 186 selected release-script tests passed, including 38 new dependency
recovery fixtures. Shell syntax, shellcheck and actionlint passed. The real
Actions module positive probe and IDE parsing passed; full App compilation
remains a cloud gate. [Evidence](qualification/build183-release/dependency-recovery.json).

Build 182 / `v1.7.0-beta.39` remains immutable. Its accepted-SDK App compilation
failed on IDE integration types; SDK 27 separately failed during GitHub package
fetch/submodule resolution. [Original failure evidence](qualification/build182-release/cloud-failure.json)
is retained. Neither a failed build nor the passing module checks establish
App UI acceptance or TestFlight availability.

## 本轮验收

- 重新打开 App 后恢复 GitHub 构建记录，并主动轮询未完成任务；提交响应不明不重复触发，取消等待远端确认。
- Word、Excel、PPT、笔记、思维导图和 DXF／DWG 分别检查内容封面；Office 摘要不冒充原布局缩略图。
- Node／Python 预览服务重启、停止和环境删除，以及 Lua 安装、运行、卸载。
- 两个 SDK 的 App 编译、App 回归与 iPad／iPhone 手记界面验证；通过后上传既有内部 Floe QA 组。

## Limits

Current internal TestFlight availability remains build 178. Physical iPad
local-model chat stability and native Office/Pencil operation remain separate
checks. Rust/Swift cloud outputs target the selected runner, not iOS execution.
Local PHP, RDP App integration and the complete native package/model catalogs
are not claimed as delivered. Public Beta materials remain drafts for user
review; no developer-funded cloud AI key is supplied to reviewers.

See [durable cloud jobs](IDE_GITHUB_ACTIONS.md),
[thumbnail acceptance](NOTES_OFFICE_THUMBNAIL_ACCEPTANCE.md),
[runtime lifecycle acceptance](RUNTIME_LIFECYCLE_ACCEPTANCE.md), and
[TestFlight delivery](TESTFLIGHT_1.7.0_BETA.md).
