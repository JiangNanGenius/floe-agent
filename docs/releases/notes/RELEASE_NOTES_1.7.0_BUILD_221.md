# Floe 1.7.0 (221) — Build 220 App 编译失败修复 / Build 220 App compile repair

Status: delivered to the authorized private internal Floe QA TestFlight, the
matching unsigned-only GitHub prerelease and the Feather source. Immutable tag
`v1.7.0-beta.78` binds source `20253e67` after the Build 220 compile-repair
commit `2ce4f763` on `main`. Release run 35678610685 built with the accepted
SDK, retained recovery artifacts, signed and uploaded the package. Apple build
`387e2282-0814-4384-88a8-5a756d46a5ef` is VALID, unexpired and IN_BETA_TESTING
in the sole private internal Floe QA group. Simulator/UI qualification was
waived by the user's expedited request; physical-device acceptance remains
with the user.

## Why Build 221 exists

The cloud accepted-SDK Release/device App compile for build 220 (accepted-SDK
rebuild run `35673428023`, Xcode 26.6 / iPhoneOS 26.5 SDK, whole target
`FloeAgent`) stopped at the App target Swift compile with **14 diagnostics in 3
files** and no artifact, signing or upload:

- `FloeApp/Platform/BackgroundRunCoordinator.swift` (9 diagnostics): the
  background/notifications integration named `LinuxGuestMetricsSampler`,
  `TaskNotificationDecision` and `NotificationAuthorizationState` without
  importing the modules that publish them, so the types and the
  `.terminal`/`.approval` event members were not in scope.
- `FloeApp/Terminal/LinuxImageInstallCard.swift` (4 diagnostics):
  `environmentIDHint ?? await services.firstLinuxEnvironmentID()` put an
  `async` call inside the non-async autoclosure of `??`, and
  `CancellationToken` (FloeTools) was named without an import.
- `FloeApp/Workspace/OfficeDocumentEditorView.swift` (1 diagnostic): the
  visible-render watchdog referenced `awaitingVisibleRender`, a property that
  does not exist; the gate's real property is `awaitsVisibleRender`. This was
  latent since the render gate landed and only compiled once the rebuilt,
  re-pinned presentation host made `canImport(FloeOfficeNative)` true in
  device builds.

## 简体中文

Build 221 不增加新功能，它是 Build 220 集成源码（`9e83fcfa`）经 `main`
上编译修复提交 `2ce4f763` 后的 App 编译修复候选：功能范围与
[Build 220 版本说明](RELEASE_NOTES_1.7.0_BUILD_220.md)相同（每环境 ext4 磁盘与
`/floe/env` 可写缓存、9P `ls -l` 语义修复、权威安装状态与合并下载、显式
「在后台保持运行」开关与只上报实测值的指标、统一的任务完成通知与深链、PPTX
可见渲染门禁与编辑入口修复），区别只是让这些源码通过 App 目标编译并把版本号推进到
1.7.0（221）。

本轮修复对应云端失败构建的全部 14 条诊断，且没有用条件编译隐藏代码：

- `BackgroundRunCoordinator.swift` 补上 `import FloeExecution`
  （`LinuxGuestMetricsSampler`）与 `import FloeModels`
  （`TaskNotificationDecision`、`NotificationAuthorizationState`）；新文件仍在
  原有 App／SPM 目标中（App 源按目录自动纳入，SPM 目标按路径自动纳入）。
  同文件的通知响应路由另修复一处 Swift 6 严格并发错误：此前把非 `Sendable`
  的原始通知字典 `[AnyHashable: Any]` 直接送进 `MainActor` 闭包；现在跨越隔离
  边界的只有从深链身份重建的 `Sendable` 字符串负载（`BackgroundWorkDeepLink.userInfo`），
  路由读取的键与行为完全一致。
- `LinuxImageInstallCard.swift` 把 `hint ?? await …` 改写为显式分支后再
  `await` 回退查询，并补上 `import FloeTools` 以使用 `CancellationToken`。
- `OfficeDocumentEditorView.swift` 的渲染看门狗改用门禁真实属性
  `awaitsVisibleRender`。

四个出货目标（App、Screen Share、Share、Widgets）统一为
`MARKETING_VERSION 1.7.0` / `CURRENT_PROJECT_VERSION 221`，并已用 xcodegen
重新生成 `FloeAgent.xcodeproj`（8 处 `CURRENT_PROJECT_VERSION`，无其他差异）。

验证边界：本轮在本机用 Xcode 27 对修复后的源码做了 Debug **真机 SDK
（iphoneos / generic iOS device）**无签名编译，并使用与云端门禁相同的固定
Office 宿主工件（run 35668651442，`engine.lock.json` 的 `archiveSHA256
cd423813…542ca`），因此 `#if canImport(FloeOfficeNative)` 内的设备路径（包括
可见渲染看门狗）同样参与编译；编译、链接与宿主哈希校验嵌入全部成功，App 与
Screen Share 扩展的版本均为 1.7.0（221）。另运行了发布契约脚本测试与
FloeCore/FloeModels/FloeExecution 的定向 Swift 测试。随后发布 run
35678610685 完成云端验收 SDK App 编译、工件留存、签名与上传；Apple build
`387e2282-0814-4384-88a8-5a756d46a5ef` 已核实 VALID、未过期、位于唯一私有
内部 Floe QA 组并处于 IN_BETA_TESTING。`en-US` 与 `zh-Hans` 测试说明已读回；
GitHub 未签名预发布和 Feather 源均已发布。没有进行模拟器 UI 与真机验收；首次
下载、磁盘持久化、`ls -l`、后台停止／重启、完成通知与 PPTX 保存退出仍由用户
在真机上验收。

## English

Build 221 adds no new features: it is the App-compile repair candidate for
the integrated Build 220 source (`9e83fcfa`) after repair commit `2ce4f763`
on `main`. Its functional scope is identical to the
[Build 220 release notes](RELEASE_NOTES_1.7.0_BUILD_220.md) (per-environment
ext4 disks with writable `/floe/env` caches, the 9P `ls -l` semantics repair,
authoritative install state with coalesced downloads, the explicit keep-running
switch with measured-only metrics, unified task-completion notifications with
deep links, and the PPTX visible-render/edit-entry repair). The only difference
is that this source compiles in the App target and carries version 1.7.0 (221).

The repair resolves all 14 diagnostics of the failed cloud build and does not
hide code behind conditional compilation:

- `BackgroundRunCoordinator.swift` now imports `FloeExecution`
  (`LinuxGuestMetricsSampler`) and `FloeModels` (`TaskNotificationDecision`,
  `NotificationAuthorizationState`); the new files stay in their existing
  App/SPM targets (App sources are picked up by directory, SPM targets by
  source path). The same file also fixes a Swift 6 strict-concurrency error in
  notification-response routing: the raw non-`Sendable` notification dictionary
  (`[AnyHashable: Any]`) no longer crosses into the main-actor closure; only
  the `Sendable` string payload rebuilt from the parsed deep-link identity
  (`BackgroundWorkDeepLink.userInfo`) crosses, with the same keys and behavior.
- `LinuxImageInstallCard.swift` replaces `hint ?? await …` with an explicit
  branch that awaits the fallback lookup, and imports `FloeTools` for
  `CancellationToken`.
- `OfficeDocumentEditorView.swift` uses the gate's real property name,
  `awaitsVisibleRender`, in the visible-render watchdog.

All four shipping targets (App, Screen Share, Share, Widgets) declare
`MARKETING_VERSION 1.7.0` / `CURRENT_PROJECT_VERSION 221`, and the regenerated
`FloeAgent.xcodeproj` matches (eight `CURRENT_PROJECT_VERSION` entries, no other
changes).

Validation boundary: on the local machine the repaired source completed an
unsigned Debug **device-SDK** compile (iphoneos / generic iOS device) with
Xcode 27 against the same pinned Office host artifact the cloud gate uses (run
35668651442, `archiveSHA256 cd423813…542ca` in `engine.lock.json`), so the
device-only `#if canImport(FloeOfficeNative)` path — including the
visible-render watchdog — was compiled too; compilation, linking and the
hash-verified host embedding all succeeded, and both the App and the Screen
Share extension report 1.7.0 (221). The release-contract script tests and
focused FloeCore/FloeModels/FloeExecution Swift tests were also run. Release
run 35678610685 then completed the cloud accepted-SDK App build, artifact
retention, signing and upload. Apple build
`387e2282-0814-4384-88a8-5a756d46a5ef` is verified VALID, unexpired and
IN_BETA_TESTING in the sole private internal Floe QA group; `en-US` and
`zh-Hans` notes were read back, and the unsigned GitHub prerelease and Feather
entry are published. It has no simulator/UI or physical-device acceptance;
first-download, disk persistence, `ls -l`, background stop/restart, completion
notifications and PPTX save-on-close remain for the user to accept on a device.
