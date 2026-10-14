# Temporary chat qualification / 临时会话验证

Date: 2026-10-15. Toolchain: Xcode 27.0 (27A266a), iOS Simulator 27.0, deployment target iOS 26. The candidate source includes the temporary-chat changes after `6dea64e7`; this record is not a release or device acceptance claim.

## Behaviour / 行为

- Compact toggle after New Chat; no creation-time mode chooser. A populated saved conversation starts a separate temporary chat.
- Text-only composer; only configured public web search/fetch tools are available. RAM stores exclude history, drafts, running-input queues, notifications and credentials from durable storage.
- Background/inactive/lock preserves the same live temporary session and route. Actual conversation/destination change or New Task immediately fences and cancels the temporary work, even during launch or saving. Rotation and presentation changes are not navigation.
- Keep saves once through the existing transaction, includes queued inputs and unsent drafts, and makes the conversation discoverable in ordinary history. Workspace ownership is committed atomically with saved content; a failure remains retryable. Late callbacks cannot mutate a replacement session.
- App termination does not restore temporary content. Provider retention is governed by that provider.

新建聊天不弹模式选择；顶部开关发起临时会话。后台往返保留同一会话，实际切走立即取消并销毁；明确保留为正式会话后才写入历史。保存失败、重复操作和晚到回调均验证身份与修订边界。

## Actual checks / 实际验证

| Layer | Result | Scope |
| --- | --- | --- |
| Full App build-for-testing | Passed | Real App and Swift 6 objects, Xcode 27 |
| Temporary App tests | 49/49, 3.717 s | RAM/durable boundaries, launch/Keep/End races, cancellation, queue/draft preservation, workspace transaction rollback/retry, ordinary resource ownership, late attachment and pending-toggle cancellation/replacement |
| Persistence module | 184/184 | Atomic verified-empty removal; messages, workspace ownership, attachments, runs, queued inputs and saved metadata prevent destructive conversion |
| iPad UI | 7/7, 157.131 s | New Chat, Home toggle, populated-chat leave/history, End, Keep, rotation, background return; a temporary identity cannot inherit an ordinary files inspector |
| iPhone 17 Pro UI | 4/4, 93.421 s | Real compact layout, Home toggle, background return and separate-chat leave/history, no forced iPad traits |
| Notification App tests | 33/33, 3.659 s | Response bridge, route, background coordinator and gate |
| System notification UI | 2/2 | Real warm/cold OS taps, target title verified; received/routed/completion dispatch/delivery exactly once |

The background tests type a unique draft, press Home, verify a background state, then **activate the existing process** and verify the same draft, both messages and temporary badge. They do not relaunch a preset fixture to simulate persistence. Primary review inspected the iPad and compact iPhone screenshots.

Original failures are retained privately: SwiftUI parent identifiers masked banner children; user-message role grouping hid message text from accessibility; a saved fixture lacked ordinary workspace ownership; an asynchronous test asserted a follow-up remained pending after the runtime was released to consume it. Fixes preserve the real behaviours and deterministic assertions.

Final preservation checks also cover an ordinary chat with no messages but an existing workspace, staged attachment, queued input or run. Such a chat starts a separate temporary session. Only a blank, automatic, unarchived ordinary record with no owned resources may convert in place, and its database check and deletion are one transaction. A cancelled or superseded toggle cannot publish after navigation; restoration errors remain errors and do not clear the ordinary draft. Original failed tests and subsequent fixes are retained, including the late-attachment window and live-run cancellation path. UI helpers scroll the existing sidebar and activate verified native menu rows; they do not erase reused Simulator data or replace navigation with a fixture shortcut.

## Limits / 边界

Synthetic fixtures use no paid model and no real credentials. This proves the App paths above on Simulator, not physical-device performance, actual provider retention, or the original Build 271 device exception. The notification cold-launch gap was fixed; the original device Foundation exception was not reproduced. Linux App boot and internal TestFlight delivery have separate acceptance records.

Final rendered-layout review uses the original full-device screen recording for iPad landscape: the exported XCTest App-element PNG has an orientation/crop artifact. The recording shows the complete surface and the inspector disappearing after the temporary toggle; the original recording and element capture are both retained. Compact phone and portrait background-return screenshots were inspected directly.
