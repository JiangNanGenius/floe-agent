# Floe Agent 1.7.0 (201) / beta.58 — 冻结内部测试构建与 GitHub 预发布恢复 / frozen internal-testing build with the GitHub prerelease recovered from the retained artifact

> **状态：冻结提交已构建、签名并上传；GitHub 预发布与 Feather 源从保留工件恢复。**
> 单次验收上传 SDK App 构建在冻结提交 `be06cece8646d5ce53a12c6bf7fcd68ce728c0b3` 上执行
> （[run 35453588806](https://github.com/JiangNanGenius/floe-agent/actions/runs/35453588806)，
> Xcode 26.6 / 17F113，iOS SDK 26.5），未签名设备 IPA
> `Floe-Agent-1.7.0-build201-unsigned.ipa`（sha256
> `e80ff0c56d4af35b7717b98cc704f1cb1131e67f8a0f15ebeaa12ec09286dec3`，811,524,833 B）与其
> 匹配的私有符号包（`release-symbols-1.7.0-build201`，工件 id 10587443373）在签名前已保留，
> TestFlight 传输已接受上传。该运行的 `lean-publish` 作业随后在
> “Publish the attested unsigned prerelease without clobbering” 步骤失败：发布步骤要求本文件
> 位于冻结标签提交的检出中，而本文件当时尚不存在；按设计不变标签 `v1.7.0-beta.58` 固定在
> `be06cece`，不为补文档而移动。本次发布从 `expedited-unsigned-ipa-1.7.0-build201` 保留工件
> 恢复，**未重新构建 App、未重新上传 TestFlight**；经来源证明的未签名 GitHub 预发布
> `v1.7.0-beta.58` 与 Feather 源来自同一工件。Apple `buildID`
> `ea0f0b12-6fad-4a55-b1f2-ac2033328c74` 在上传处理查询中为 `VALID`
> （[discover 35457644985](https://github.com/JiangNanGenius/floe-agent/actions/runs/35457644985)）；
> 内部 Floe QA 组可见性与双语测试说明的写入／读回结果记录于
> [TestFlight 交付记录](TESTFLIGHT_1.7.0_BETA.md)。模拟器／UI 资格按用户明确要求跳过，因此
> 这是内部设备测试而非完整验收；真机验收属于用户，Build191 的本地模型前台中断仍未证实修复。
> 本轮不含公开 Beta 提交或生产发布。
>
> **Status: the frozen commit was built, signed and uploaded; the GitHub prerelease and the
> Feather source were recovered from the retained artifact.** The single accepted-SDK App build
> ran in [run 35453588806](https://github.com/JiangNanGenius/floe-agent/actions/runs/35453588806)
> from the frozen commit `be06cece8646d5ce53a12c6bf7fcd68ce728c0b3` (Xcode 26.6 / 17F113,
> iOS SDK 26.5). The unsigned device IPA `Floe-Agent-1.7.0-build201-unsigned.ipa` (sha256
> `e80ff0c56d4af35b7717b98cc704f1cb1131e67f8a0f15ebeaa12ec09286dec3`, 811,524,833 B) and its
> matching private symbols (`release-symbols-1.7.0-build201`, artifact id 10587443373) were
> retained **before** signing, and TestFlight accepted the upload. The run's `lean-publish` job
> then failed in “Publish the attested unsigned prerelease without clobbering”: the publish step
> requires this document in the frozen tag checkout, and it did not exist yet. By design the
> immutable tag `v1.7.0-beta.58` stays fixed at `be06cece` and is never moved to add a document.
> This publication was recovered from the retained `expedited-unsigned-ipa-1.7.0-build201`
> artifact — **no App was rebuilt and nothing was re-uploaded** — and the attested unsigned
> GitHub prerelease `v1.7.0-beta.58` and the Feather source come from that same artifact. Apple
> `buildID` `ea0f0b12-6fad-4a55-b1f2-ac2033328c74` reported `VALID`
> ([discover 35457644985](https://github.com/JiangNanGenius/floe-agent/actions/runs/35457644985));
> internal Floe QA group visibility and the saved/read-back bilingual test notes are recorded in
> the [TestFlight delivery record](TESTFLIGHT_1.7.0_BETA.md). Simulator/UI qualification was
> skipped by explicit user request, so this is internal device testing, not full acceptance;
> physical-device acceptance belongs to the user and the build 191 local-model abort remains
> unproven fixed. No public Beta submission or production release is included.

功能实现范围 / Implementation range：`5b27e472..be06cece`（build 199 版本准备、build 200 内部
Beta 准备、Office 组件锁定、两处 Swift 6 修复与 build 201 版本／说明准备）；对外功能与 build 198
内部交付（`1cff5665..11681a0f`）相同再加下列修复。内部 TestFlight、GitHub 开发者包与 Feather
是相互独立的交付物，均以同一冻结提交为准。

## Build 199 / 200 未上传与 Build 201 修复 / Builds 199 and 200 were not uploaded and the build 201 fixes

- Build 199（标签 `v1.7.0-beta.56`）只完成版本准备与说明文档，未进入验收上传构建，**从未上传**。
- Build 200（标签 `v1.7.0-beta.57`，提交 `455534236c9b37ab592f45f1a0a8e9030a4fa00b`）的发布运行
  [35451531085](https://github.com/JiangNanGenius/floe-agent/actions/runs/35451531085) 在
  “Rebuild the exact tag with the accepted App Store SDK” 步骤停止：没有产出 App 工件、没有签名、
  没有 TestFlight 上传，其步骤记录中 `Sign, verify, package, and upload to TestFlight` 全部跳过。
  该构建暴露的两处 Swift 6 诊断由提交 `3744103f`（`fix(build200): await route resolver and
  branch concrete label styles`）修复：媒体模型解析等待主线程路由（`RemoteImageTools.swift`），
  Office 紧凑／常规工具栏改用明确的标签样式分支（`WorkspaceIDEView.swift`）。
- Build 201 在 `be06cece` 冻结上述修复。只有验收上传 SDK 的云端 App 编译能确认修复：该编译已在
  run 35453588806 通过并产出签名上传与保留工件，本文不重复断言其它未执行的测试。
- `docs/TESTFLIGHT_1.7_WHATS_NEW_BUILD_201.json` 是本次内部测试的英文与简体中文说明来源，已按该
  文件写入 App Store Connect 并读回（见 TestFlight 交付记录）。

Build 199 (tag `v1.7.0-beta.56`) only prepared the version and notes and **was never uploaded**.
Build 200 (tag `v1.7.0-beta.57`, commit `455534236c9b37ab592f45f1a0a8e9030a4fa00b`) stopped its
release run [35451531085](https://github.com/JiangNanGenius/floe-agent/actions/runs/35451531085)
inside “Rebuild the exact tag with the accepted App Store SDK”: no App artifact, no signing and no
TestFlight upload occurred, and every later step including
`Sign, verify, package, and upload to TestFlight` was skipped. The two Swift 6 diagnostics
recorded for build 200 are fixed by commit `3744103f` (media model resolution awaiting its
main-actor route in `RemoteImageTools.swift`; compact/regular Office toolbar branches using
concrete label styles in `WorkspaceIDEView.swift`). Build 201 freezes those fixes at `be06cece`;
only the accepted-upload-SDK cloud App compile can confirm them, and that compile passed in run
35453588806 with a signed upload and retained artifacts. This document makes no claim about any
other unexecuted test.

## 简体中文

**测试重点（Build 201 内部真机测试）**

1. **画布**：手指或触控板拖动节点主体／标题可以移动节点；只有可见四角用于调整大小。
2. **视频／图片任务**：可选择正确模型，可主动刷新与对账；临时状态查询失败不会把任务误判为失败。
3. **Office**：不再停留在“正在关闭”；预览转编辑可重复使用；手记中已打开过的文档再次进入时默认
   编辑；Office 留在当前 IDE 标签内；文件管理器“放大”直接进入专用编辑器。
4. **本地 MLX**：每轮释放模型与 Metal 缓存；纯文字轮次释放无用视觉状态；加载／解码失败每轮只
   自动清理重试一次。
5. **Shell**：输出收尾有界；修复交互式 Dash 输入。

Build 198 的思维导图触摸新增节点、Apple Pencil 支持与妙控键盘固定等修复继续包含。本轮按要求缩短
验证：只做聚焦宿主／源码检查和一次云端 App 构建；完整 UI／真机验收由测试者完成。

**发布与恢复记录**

- 冻结源 `be06cece8646d5ce53a12c6bf7fcd68ce728c0b3`，标签 `v1.7.0-beta.58`（不可移动）。
- 保留工件：`expedited-unsigned-ipa-1.7.0-build201`（zip sha256
  `93dbe78eef629649b78f7b82f60e03c10fa572a9dffbba272d7110eb7c355584`），未签名 IPA sha256
  `e80ff0c56d4af35b7717b98cc704f1cb1131e67f8a0f15ebeaa12ec09286dec3`，app UUID
  `69627670-F83E-3B29-BCF9-57EBC5771426`，私有符号 `release-symbols-1.7.0-build201`。
- 上传接受证据 `testflight-1.7.0-build201` 保留于同一运行；发布检查使用该证据判定“已接受上传、
  不得重复上传”，因此本次恢复没有第二次上传。
- 发布失败原因：发布步骤在冻结标签提交中找不到 `docs/RELEASE_NOTES_1.7.0_BUILD_201.md`
  （`test -s` 失败），作业在创建预发布前退出，未产生任何 GitHub 资产。
- 恢复方式：用保留工件重建与工作流完全相同的公开资产集合并创建未签名预发布，随后运行发布工作流的
  复用验证路径（`reuse_direct_run=35453588806`）逐字节核验已发布资产并继续 Feather。**没有重新
  构建、没有重新上传、标签未移动。**

## English

**Testing focus (build 201 internal device test)**

1. **Canvas**: dragging a node body/title with a finger or trackpad moves it; only the visible
   corners resize.
2. **Video/image tasks**: correct model selection, explicit refresh and reconciliation; a
   temporary status-query failure is not reported as a failed task.
3. **Office**: no longer stuck on “Closing”; preview-to-edit can be repeated; documents already
   opened from Notes return in edit mode; Office stays in the current IDE tab; File Manager
   expand opens the dedicated editor.
4. **Local MLX**: releases model and Metal caches each turn, drops obsolete vision state for
   text turns, and performs exactly one clean automatic retry per turn for load/decode failures.
5. **Shell**: bounded output finalization and interactive Dash input.

The build 198 mind-map touch node creation, Apple Pencil support and Magic Keyboard fixes remain
included. Validation was intentionally short as requested: focused host/source checks and one
cloud App build; full UI/device acceptance is assigned to the tester.

**Publication and recovery record**

- Frozen source `be06cece8646d5ce53a12c6bf7fcd68ce728c0b3`, tag `v1.7.0-beta.58` (never moved).
- Retained artifacts: `expedited-unsigned-ipa-1.7.0-build201` (zip sha256
  `93dbe78eef629649b78f7b82f60e03c10fa572a9dffbba272d7110eb7c355584`), unsigned IPA sha256
  `e80ff0c56d4af35b7717b98cc704f1cb1131e67f8a0f15ebeaa12ec09286dec3`, app UUID
  `69627670-F83E-3B29-BCF9-57EBC5771426`, private symbols `release-symbols-1.7.0-build201`.
- The accepted-upload evidence artifact `testflight-1.7.0-build201` is retained in the same run;
  the publication check uses it to decide that the upload was already accepted and must not be
  repeated, which is why this recovery performed no second upload.
- Failure cause: the publish step could not find `docs/RELEASE_NOTES_1.7.0_BUILD_201.md` in the
  frozen tag checkout (`test -s` failed), so the job exited before creating the prerelease and no
  GitHub asset was produced.
- Recovery: rebuild the exact public asset set from the retained artifact, create the unsigned
  prerelease, then run the release workflow's reuse path (`reuse_direct_run=35453588806`) to
  re-verify every published byte and continue to Feather. **No rebuild, no re-upload, tag not
  moved.**

## 验证边界 / Verification boundary

本文件记录构建、上传接受、保留工件、发布恢复与 Apple 处理状态；内部 Floe QA 组可见性、说明读回
在完成后记录于 [TestFlight 交付记录](TESTFLIGHT_1.7.0_BETA.md)。模拟器／UI 资格按用户明确要求
跳过（`simulatorQualification: skipped_by_user_request`），因此本预发布**不是**完整验收，也不构成
公开 Beta 或生产发布。真机验收属于用户。

This document records the build, accepted upload, retained artifacts, publication recovery and
Apple processing state; internal Floe QA visibility and notes read-back are recorded in the
[TestFlight delivery record](TESTFLIGHT_1.7.0_BETA.md) once verified. Simulator/UI qualification
was skipped by explicit user request (`simulatorQualification: skipped_by_user_request`), so this
prerelease is **not** full acceptance and is not a public Beta or production release.
Physical-device acceptance belongs to the user.
