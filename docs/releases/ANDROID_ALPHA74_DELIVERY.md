# Android Alpha74 preparation — 2026-11-10

Planned version: `0.1.0-alpha.74` / code100. This source-stage record does not claim an APK, physical unlock or public release. The matching immutable release tag will identify the qualified source.

## Changes / 更新

自动解锁改为等待真实手势完成、原生凭据界面和锁屏状态，异步回调及输入前重新检查授权。确认按钮只使用实际观察到的 SystemUI 可点击控件或有界父控件；没有目标则保留手动处理。诊断只记录固定阶段，不记录密码、按键、节点内容或标识。

亮屏锁由真实任务持有，有界续期，并在失败、取消、结束、接管、主动熄屏及服务关闭时释放。解锁成功时立即交接任务阶段的超时，避免短超时先于第一次续期失效；旧回调不能操作替代任务的锁。

任务回答、恢复和运行状态变化后读取最新等待状态，避免结束后仍显示“等待你处理”。不按终态直接隐藏真实审批或提问，也不随每个流式文本片段重复读取。

Unlock now observes actual native completion, rechecks live authority and uses only observed native submit controls. A bounded task-owned wake lease follows cancellation, takeover, screen-off and service lifecycle; the successful handoff bridges the first renewal. Canonical waiting state refreshes on run/question transitions.

## Source qualification / 源码检查

- Forty-four focused cases and actual Full/Play Kotlin compilation passed on matching inputs: 21 retained unlock lifecycle cases, seven submit-ancestor cases and 16 wake-resource cases.
- A timeout-aware regression first reproduced the short-lease/first-renewal gap against the original worker result. The failed result remains recorded. Two newly authored fixture setup/counting errors were corrected without weakening the ownership or privacy assertions.
- The native34 runtime inputs have not intentionally changed. Actual candidate production still requires exact input matching, native binding, signature and package checks; Kotlin compilation is not that proof.
- App/runtime/optional preview versions and corresponding-source offers advance together. No new cloud/provider call was used during code qualification.

## Device evidence and limitations / 实机与限制

公开Alpha73的三星用例已在同一原始运行中恢复原提问：实际结束主程序进程后重开，回答后读到原指南快照及更新后的当前版本；六次工具结果成功，无重复创建或更新。原导出与进程记录保留，自己的任务及设备导出已清理；指南按既有可恢复移除规则保留恢复副本。

该用例暴露等待提示未刷新的界面问题，手动刷新后真实等待已清空；本版包含自动刷新修复，仍待新包实机确认。另一Alpha73用例的Linux命令有真实输出，但后续自动解锁进入手动等待，不能记为通过或用清理后的错误推定原根因。

The Alpha73 Samsung baseline passed same-run/question process recovery and guide snapshot pagination. Its separate automatic-unlock attempt reached manual fallback and remains a failure. New74 unlock/action/relock and banner behavior require fresh physical-device evidence.

Sony XZ/Android9 post-extraction startup remains unresolved. Existing received diagnostic metadata contained no Android9 event; this does not prove that every attempted upload reached the server or establish the startup cause. Fresh-download metering, remaining N03/N05 combinations and whole-App UI polish retain their open status. N01–N08 remains active.


## Delivery appendix / 交付补记 — 2026-11-10

[Alpha74/code100](https://github.com/JiangNanGenius/floe-agent/releases/tag/android/v0.1.0-alpha.74) is published from immutable source `322f6e3cefb3039922f821acd58ade79edfe96b1`. The preparation statements above are retained as the original source-stage record.

- Actual Full ARM64 APK: 164,688,671 bytes; SHA-256 `da7e9022f4a3814ae0c0acda3e84f6b8823750fd9b283c4e121ec63a4cfd4897`. Exact native34 input reuse, 58 package bindings, main/runtime API28/29 signatures and actual73→74 host delta reconstruction passed. These are not Sony hardware qualification.
- All seven allowlisted anonymous public asset bytes, immutable tag/source and current/retained65 production update discovery passed. iOS Latest remained `v1.8.6` at read-back.
- Samsung explicitly selected the complete update in public73, downloaded through its saved GH-Proxy choice and completed normal main/runtime confirmations plus Play Protect scanning. Both installed packages are code100 with exact public bytes and original UIDs; five baseline tasks and two projects remained visible. No ADB replacement, downgrade or Floe uninstall was used.
- A new same-run question answered successfully and its waiting banner cleared without manual refresh; the Linux command returned the actual expected marker. Its phone request preceded the tester's screen-off by 23.32 seconds and correctly reached the active-user confirmation. That original 41-record case was retained and retired; it is not an automatic-unlock attempt. Permission cleanup influenced the final discarded phone result, which does not establish a driver cause.
- A separate, timely locked case reached the actual unlock driver with continuously bound accessibility: wake lease acquired, reveal accepted/completed, then USER_REQUIRED because no credential surface was observed. No credential-input/submit stage or actual unlock was observed before cleanup. This is a real failed readiness boundary; active-root/window selection and display readiness remain hypotheses under repair, not confirmed hardware causes. No retry or successful calculator/relock is claimed.
- Twenty-three unused outputs/stages were retired after eight producer receipts and exact assets were exported. The internal-volume deletion window measured 3,177,918,464 additional free bytes; concurrent APFS activity can affect whole-volume measurements. Current74, required73 rollback/72 original failure, native34 raw libraries/symbols, original failures, SDK/AVD and useful warm classes/dependencies remain. Retired stage paths must not be blindly replayed.

公开完整包在线升级与原数据保持已确认；自动解锁仍未通过，后续只针对已观察到的凭据界面就绪断点修复。索尼XZ／Android9具体启动原因及其余N01–N08工作继续，不能据本轮要求用户刷机或宣布整轮完成。
