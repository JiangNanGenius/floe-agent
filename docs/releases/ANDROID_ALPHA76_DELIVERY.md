# Android Alpha76 / code102 — source preparation

This frozen-source preparation record precedes APK, physical-device and public-delivery evidence. Later results are appended without replacing the source tag or original failures.

## Changes / 更新

- Linux已安装但任务执行未就绪时，“重新检查”仅在仍有实际原生代际的前提下重连已有通道、重新测量前置事实。不会复活已停止环境、重装Linux或删除用户文件。
- 当前代际的启动拒绝原因不会再被统一失效摘要覆盖；组件不符、连接超时、握手拒绝分别保留。真实内部10秒Future超时和取消身份都有定向回归，原始异常因果保留。
- 自动解锁须先观察默认屏幕真正可交互且处于STATE_ON，并有可信SystemUI窗口，才执行一次揭示手势。超时不再当成就绪；已出现凭据界面时直接处理，不覆盖滑动。未就绪则在有界观察后返回人工处理，不重复手势或凭据。
- Rebind/recheck existing Linux lanes for the live accepted generation and preserve closed, current startup causes without reinstalling or deleting user files.
- Require observed default-display power and trusted native-window readiness before the single keyguard reveal; keep real gesture/keyguard outcomes, cancellation, ownership, wake cleanup and at-most-once credential entry.

## Qualification / 代码验证

Eighty-three phone readiness/unlock/wake/ancestor cases and ten affected graphics/protocol cases passed together, with actual Full/Play Kotlin compilation. Fifty-nine unchanged installed-runtime recovery cases are reused by exact input identity. The reused native34 inputs still require actual package/native/signature checks at candidate production; code compilation alone is not APK or device acceptance.

Review corrected a reference to a nonexistent DisplayManager method to the actual public getDisplay(...).getState() path, available below minSdk28. The initial storage preflight stopped before Gradle;445 inactive, old per-checkout output-cache objects were retired, measuring1,105,899,520 additional internal free bytes. Warm compiled outputs/dependencies, current/rollback packages, original failures and native symbols were preserved; the subsequent focused batch passed without a resource stop.

## Known issues / 已知问题

公开75已实测三星74→75真实增量重建／安装、原UID与5条任务2个项目保持，73→74完整包在线升级有独立证据。其原锁屏用例完成唤醒／滑动，却没有出现凭据界面；未输入密码、未完成计算或自动重锁。原34条最终记录及28条初始快照保留，后续清理的能力失效不能被误当作原始驱动根因。本版新包仍需实机验证。

Sony XZ/Android9具体启动原因尚未确认，不能宣称恢复或归因为系统版本低。重检和诊断修复针对已证明的源码缺口；新版设备诊断才用于决定下一步。全新下载计量、图形会话组合、其余N03／N05和全局UI精修继续，N01–N08总目标保持进行中。

The original75 lock-screen failure remains a failure. Fresh76 device acceptance and concrete Sony recovery are unverified at this preparation stage; remaining N01–N08 work stays open.

## Delivery policy / 发行边界

Publish one Full ARM64 APK and necessary checksums/update/source/optional-preview files from one immutable source. Verify75→76 reconstruction and exact public bytes/current and retained-client discovery, preserve iOS Latest, then record real Samsung upgrade and affected flows. Retire only completed, unused generated outputs after exporting artifacts/producer receipts; keep originals and required rollback.
