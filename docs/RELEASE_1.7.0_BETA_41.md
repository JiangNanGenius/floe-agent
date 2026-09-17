# Floe Agent 1.7.0 (184) — beta.41 candidate

**Preparation in progress; not tagged, built or uploaded.**

This candidate retains durable IDE GitHub Actions jobs, content covers for
Office/Notes/mind maps/CAD, and Node/Python/Lua lifecycle qualification. It
repairs the CAD cover bridge by normalizing the JavaScript reply to a Sendable
value before continuation transfer. Foreground cloud-job queries explicitly
revalidate remote responses instead of using URLSession's local response cache.

Build 183 / `v1.7.0-beta.40` remains immutable. Both real Xcode dependency
resolutions succeeded on the first attempt with pinned locks unchanged. Module
qualification passed. Both App targets then reported non-Sendable continuation
transfers in the CAD cover renderer; no device package or upload was produced.
[Original evidence](qualification/build183-release/cloud-failure.json).

The old renderer reproduces the same two errors during mandatory SIL checking,
while `-typecheck` alone misses them. The repaired production renderer passes
SIL and object compilation with a narrow dependency shim. This is focused
compiler evidence, not full-App or native UI acceptance. The Actions client, job engine/store and all 25 fixture / 23 IDE tests also pass
mandatory SIL and object emission with real source subsets; these checks do not
execute the tests. [Focused evidence](qualification/build184-release/focused-compiler-checks.json).
Complete two-SDK cloud
compilation and App/Notes UI gates remain required before internal TestFlight.

## 本轮验收

- 重开 App 后恢复 GitHub 构建记录并主动轮询；提交结果不明不重复触发，取消等待远端确认。
- Word、Excel、PPT、笔记、思维导图和 DXF／DWG 的内容封面；Office 摘要不替代真实缩略图验收。
- Node／Python 预览服务重启、停止和环境删除；Lua 安装、运行、卸载。
- 两套 SDK 的 App 编译、App 回归和 iPad／iPhone 手记界面；通过后交付现有内部 Floe QA 组。

## Delivery limits

Build 178 remains the last confirmed available internal TestFlight release.
Physical iPad local-model ordinary-chat stability and native Office/Pencil
operation remain separate checks. Rust/Swift cloud outputs run on the selected
CI platform, not on iOS. Local PHP, RDP App integration and the complete native
package/model catalogs are not claimed as delivered. Public Beta materials
remain drafts for user review; no developer-funded cloud AI key is included.

See [durable cloud jobs](IDE_GITHUB_ACTIONS.md),
[thumbnail acceptance](NOTES_OFFICE_THUMBNAIL_ACCEPTANCE.md),
[runtime lifecycle acceptance](RUNTIME_LIFECYCLE_ACCEPTANCE.md), and
[TestFlight delivery](TESTFLIGHT_1.7.0_BETA.md).
