# Floe Agent 1.7.0 (184) — beta.41 candidate

**Cloud qualification failed; signing and upload skipped.**

Tag `v1.7.0-beta.41`, App source `8e0cf69f6387333e768b90d56372e587eb297375`.
[Run 35287358993](https://github.com/JiangNanGenius/floe-agent/actions/runs/35287358993).

This candidate retains durable IDE GitHub Actions jobs, content covers for
Office/Notes/mind maps/CAD, and Node/Python/Lua lifecycle qualification. It
repairs the CAD cover bridge by normalizing the JavaScript reply to a Sendable
value before continuation transfer. Foreground cloud-job queries explicitly
revalidate remote responses instead of using URLSession's local response cache.
A production-source CLI check on this commit passed 28 assertions: direct-run
association of the existing run `35247779223` in 0.42 s, and fresh-process
recovery to completed/success in 2.01 s with the stale error cleared and no new
dispatch. That is CLI evidence, not App relaunch or UI acceptance.
[Evidence](qualification/build184-release/live-recovery.json).

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

## Newly observed results

Both dependency resolutions passed on attempt 1. SDK 27 module gates and App
test-host compilation passed; the accepted SDK device build passed and its
[unsigned recovery archive](qualification/build184-release/device-recovery.json)
was retained with its hash and bundle metadata verified. Both SDK App regression
runs completed with 203/204 tests passing; the same Lua install/run test failed
on the old WASI environment limit. UI gates, signing and upload were skipped.

The separate [NativeNotes component run](qualification/build184-release/native-notes/README.md)
failed: 70 passed and 2 failed on iPad; iPhone was not reached. Office Quick Look
and direct CAD geometry cases supplied real images, but the cold CAD cover
service and bundled mind-map text case failed. Follow-up source `f4435d22` passed the subsequent development-SDK component
run [35290599088](https://github.com/JiangNanGenius/floe-agent/actions/runs/35290599088)
on both iPad and iPhone. That separate repair is not part of immutable build 184;
full release qualification remains required.

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
