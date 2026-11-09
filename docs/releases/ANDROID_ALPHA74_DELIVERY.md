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
