# Floe Agent 1.7.0 (201) / beta.58 — 冻结内部测试构建与 GitHub 预发布恢复 / frozen internal-testing build with the GitHub prerelease recovered from the retained artifact

> **状态：已交付内部 TestFlight（Floe QA）；GitHub 预发布与 Feather 源从保留工件恢复。**
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
> 内部 Floe QA 组可见性与双语测试说明的写入／读回已完成：Apple `buildID`
> `ea0f0b12-6fad-4a55-b1f2-ac2033328c74` 于 2026-09-19 17:44 UTC 核验为 `VALID`、未过期、
> 仅一个私有内部组 Floe QA（无公开链接）且 `IN_BETA_TESTING`
> （[prepare 35458929498](https://github.com/JiangNanGenius/floe-agent/actions/runs/35458929498)、
> [verify 35459030591](https://github.com/JiangNanGenius/floe-agent/actions/runs/35459030591)），
> 英文与简体中文说明均已保存并读回；Feather 源由发布事件触发的工作流
> [35458914062](https://github.com/JiangNanGenius/floe-agent/actions/runs/35458914062) 校验
> 发布资产与来源证明后写入（`feather.json` 提交 `e7f75620`）。模拟器／UI 资格按用户明确要求
> 跳过，因此这是内部设备测试而非完整验收；真机验收属于用户，Build191 的本地模型前台中断仍未
> 证实修复。本轮不含公开 Beta 提交或生产发布。
>
> **Status: delivered to internal TestFlight (Floe QA); the GitHub prerelease and the Feather
> source were recovered from the retained artifact.** The single accepted-SDK App build
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
> internal Floe QA group visibility and the saved/read-back bilingual test notes were completed:
> Apple `buildID` `ea0f0b12-6fad-4a55-b1f2-ac2033328c74` was verified `VALID`, unexpired, exactly
> one private internal Floe QA group (no public link) and `IN_BETA_TESTING` at 2026-09-19 17:44 UTC
> ([prepare 35458929498](https://github.com/JiangNanGenius/floe-agent/actions/runs/35458929498),
> [verify 35459030591](https://github.com/JiangNanGenius/floe-agent/actions/runs/35459030591)) with
> both English and Simplified Chinese notes saved and read back; the Feather source was written by
> the release-event workflow
> [35458914062](https://github.com/JiangNanGenius/floe-agent/actions/runs/35458914062) after it
> verified the published assets and their provenance (`feather.json` commit `e7f75620`).
> Simulator/UI qualification was skipped by explicit user request, so this is internal device
> testing, not full acceptance; physical-device acceptance belongs to the user and the build 191
> local-model abort remains unproven fixed. No public Beta submission or production release is
> included.

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

## 发布恢复执行记录 / Publication recovery execution record

- **GitHub 预发布**：2026-09-19 17:42 UTC 使用保留工件中的 IPA、`.sha256`、`TEST-SUMMARY.txt`、
  `DIRECT-PROVENANCE.json`、`bundle-normalization.json`、`pdfium-linkage.json` 与生成的
  `PUBLIC-ASSETS.json` 创建（`gh release create … --verify-tag --prerelease --latest=false`），
  与工作流发布步骤的资产组装完全一致；资产集合只包含一个未签名 IPA 与其校验和，不含任何签名
  材料。标签仍固定在 `be06cece`。
- **来源证明**：发布前用 `FloeAgent/scripts/verify_direct_unsigned_artifact.py` 对下载的发布工件
  重新做了完整校验（zip digest 与 GitHub 记录一致，IPA sha256 `e80ff0c5…`，上传接受证据
  `testflight-1.7.0-build201`，私有符号工件仍然有效），并以 Feather 使用的完全相同参数执行
  `gh attestation verify … --source-digest be06cece… --signer-workflow release-unsigned-ipa.yml`
  通过。
- **Feather**：发布事件触发的工作流
  [35458914062](https://github.com/JiangNanGenius/floe-agent/actions/runs/35458914062) 独立复算
  校验和、验证来源证明并提交 `feather.json`（`e7f75620`）。
- **重建免上传重试**：以 `reuse_direct_run=35453588806` 重跑发布工作流的复用路径
  （[run 35458919065](https://github.com/JiangNanGenius/floe-agent/actions/runs/35458919065)）在
  `testflight-direct.yml` 的 “Restore and verify the retained unsigned IPA without rebuilding” 步骤
  失败：该文件在冻结标签处仍先执行一次不带 `--artifact-zip/--extract-dir` 的元数据校验调用，而该
  脚本按设计拒绝这种调用（与 build 194 记录过的发布缺陷同类；当时只修复了
  `release-unsigned-ipa.yml` 的发布作业）。标签不可移动，因此冻结版本的嵌套工作流无法修复后重跑；
  本分支修复了该复用步骤（从 GitHub 工件负载解析唯一有效工件 id，只保留一次完整 zip 校验）并新增
  回归测试 `test_rebuild_free_retry_verification_passes_extraction_paths`；修复后的命令用真实 run
  负载在本地验证通过：工件 id `10587603014`、`testflightAccepted=true`（对应
  `upload_required=false`，不会重复上传）。该次失败的重试没有产生任何发布或上传副作用。
- **TestFlight**：prepare
  [35458929498](https://github.com/JiangNanGenius/floe-agent/actions/runs/35458929498) 写入双语
  说明并确认 Floe QA 可见性；verify
  [35459030591](https://github.com/JiangNanGenius/floe-agent/actions/runs/35459030591) 确认
  `VALID`、未过期、仅一个私有 Floe QA 组且 `IN_BETA_TESTING`。

- **GitHub prerelease**: created 2026-09-19 17:42 UTC from the retained artifact's IPA, `.sha256`,
  `TEST-SUMMARY.txt`, `DIRECT-PROVENANCE.json`, `bundle-normalization.json`, `pdfium-linkage.json`
  and the generated `PUBLIC-ASSETS.json` (`gh release create … --verify-tag --prerelease
  --latest=false`), matching the workflow's asset assembly exactly; the asset set holds one unsigned
  IPA and its checksum and no signing material. The tag remains fixed at `be06cece`.
- **Provenance**: before publication the downloaded release artifact was fully re-verified with
  `FloeAgent/scripts/verify_direct_unsigned_artifact.py` (zip digest matches GitHub's record, IPA
  sha256 `e80ff0c5…`, accepted-upload evidence `testflight-1.7.0-build201`, private symbols artifact
  still live), and `gh attestation verify … --source-digest be06cece… --signer-workflow
  release-unsigned-ipa.yml` passed with exactly the arguments Feather uses.
- **Feather**: the release-event workflow
  [35458914062](https://github.com/JiangNanGenius/floe-agent/actions/runs/35458914062)
  independently recomputed the checksum, verified provenance and committed `feather.json`
  (`e7f75620`).
- **Rebuild-free retry**: re-running the release workflow's reuse path with
  `reuse_direct_run=35453588806`
  ([run 35458919065](https://github.com/JiangNanGenius/floe-agent/actions/runs/35458919065)) failed
  in `testflight-direct.yml`'s “Restore and verify the retained unsigned IPA without rebuilding”
  step: at the frozen tag that file still made a bare metadata-only verifier call without
  `--artifact-zip/--extract-dir`, which the script rejects by design (the same defect class recorded
  for build 194, where only the `release-unsigned-ipa.yml` publish job was repaired). The tag cannot
  be moved, so the frozen nested workflow cannot be fixed and re-run; this branch fixes the reuse
  step (resolve the single live artifact id from GitHub's payload and keep exactly one full zip
  verification) and adds the regression test
  `test_rebuild_free_retry_verification_passes_extraction_paths`. The fixed commands were validated
  locally against the real run payload: artifact id `10587603014`, `testflightAccepted=true`
  (so `upload_required=false`, no repeated upload). The failed retry produced no publication or
  upload side effects.
- **TestFlight**: prepare
  [35458929498](https://github.com/JiangNanGenius/floe-agent/actions/runs/35458929498) wrote the
  bilingual notes and confirmed Floe QA visibility; verify
  [35459030591](https://github.com/JiangNanGenius/floe-agent/actions/runs/35459030591) confirmed
  `VALID`, unexpired, exactly one private Floe QA group and `IN_BETA_TESTING`.

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
