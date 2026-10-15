# Floe 1.7.31 (272) — internal TestFlight delivery

Verified on 2026-10-15 UTC. **Available for internal testing in the existing Floe QA group.**

| Item | Verified result |
| --- | --- |
| Immutable App source | [`v1.7.31`](https://github.com/JiangNanGenius/floe-agent/tree/v1.7.31), commit `a7e9a62317bb2776de0e4c506a4b518bdd4e3bd5` |
| Local device build | Xcode 27.0 (`27A266a`), `iphoneos27.0`, Release arm64, six compiler jobs; archive succeeded |
| Distribution | Existing cloud workflow signed and uploaded the verified local artifact; `app_rebuilt=false` |
| Apple processing | `VALID`, not expired |
| Internal availability | Existing **Floe QA** group only, `IN_BETA_TESTING`; no unexpected beta groups |
| Independent readback | GET-only run [38658651627](https://github.com/JiangNanGenius/floe-agent/actions/runs/38658651627), captured `2026-10-15T00:12:31Z` |
| Signing/upload evidence | [38656162329](https://github.com/JiangNanGenius/floe-agent/actions/runs/38656162329) |

The transport release remains an unpublished draft. This delivery is internal TestFlight only.

## 简体中文

- 临时会话在切后台、失活或锁屏时保留同一内存会话，返回仍显示它。真正切换聊天、新建任务或明确结束时立即取消并丢弃，包括运行或准备中的任务。
- 右上角可明确保留为正式会话，包含排队追问和未发送草稿，不重复请求模型。已有工作区、附件或任务的普通会话保持独立，不因开启临时模式丢失原数据。
- 临时内容不写入 Floe 历史；进程终止后不恢复。模型提供方的数据保留政策独立适用。
- 本轮包含模型添加、个人工具、执行型子助手、Office／媒体自动处理、Brave 元数据、通知路由及 Linux 更新，详见[双语版本说明](../notes/RELEASE_NOTES_1.7.31_BUILD_272.md)。

## English

- Backgrounding, inactivity and locking preserve the same in-memory temporary chat and route. Switching chats, starting a new task or explicitly ending it immediately fences, cancels and discards its work, including preparation.
- Explicit Keep saves the chat, queued follow-ups and unsent draft without resending. Existing ordinary workspaces, attachments and tasks remain independent and intact.
- Temporary content is excluded from Floe history and is not restored after process termination. Provider retention policies apply separately.
- This round also includes model setup, personal tools, executing subagents, authorized Office/media automation, Brave metadata, notification routing and Linux updates; see the [bilingual release notes](../notes/RELEASE_NOTES_1.7.31_BUILD_272.md).

## Artifact and qualification evidence

- Normalized local signing transport SHA-256: `8892e04dd51e7ec42ed5af430ebf17ab7bf42509cb438a4e0ea4fdd40252c354`.
- Retained signed IPA SHA-256: `8644e96229148b9c4814ae1ff20dd73fb0b88ce590517c169fc42c83dee56d4e` (755,208,246 bytes).
- App and matching dSYM UUID: `01185B5F-2186-3D1C-B31C-9AC21001BFFF`. Original unsigned archive, ten dSYMs, normalized transport and final signed IPA are retained for recovery.
- The archive, transport and signed IPA contain the pinned Linux **6.18.56 / OpenSBI 1.9** pair; its manifest, hashes and license notices were checked against source. Dependency pins were preserved.
- Round evidence includes **49/49 temporary App tests**, **184/184 persistence tests**, **7/7 iPad UI** and **4/4 compact iPhone UI**. Actual guest Shell/Python/file-hash and browser-ownership checks passed through the Simulator App. Final cancellation/selection module tests and the exact-source Release archive are recorded separately. See [temporary-chat qualification](../../qualification/20261015-temporary-chat.md) and [round qualification](../../qualification/capability-closure-20261014/LOCAL_QUALIFICATION.md).

## Limits and cleanup

Simulator and macOS component results do not establish physical-device performance or real-provider results. Office device roundtrip, embedded-editor/render and original-file writeback gates remain unproven by a device artifact. Native media processing needs supported hardware/models; unresolved-license model weights remain private qualification material and are not bundled. The original Build 271 device exception was not reproduced or attributed to Linux.

Finished device/Simulator build caches, packaging staging and temporary signed-IPA extractions were removed after artifact/evidence retention and reference checks. The release-phase observed free-space gains were approximately **13.81 GiB on the internal SSD** and **3.79 GiB on the project volume**; these are phase-level observations, not a sum of logical file sizes or a guarantee of uniquely released APFS blocks. Current delivery, one previous-version rollback and original failure evidence remain. Task simulators are shut down; their app data and other projects were preserved.

No scheduled follow-up was restored.
