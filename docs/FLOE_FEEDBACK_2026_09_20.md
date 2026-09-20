# September 20 feedback repair and delivery

Status: implementation in progress. This document does not claim a new upload or
physical-device acceptance. Integration starts from `b16cb18e` (the build 204
delivery record). The prior build remains independently recorded.

The user requested code-first delivery, focused checks and an expedited
TestFlight build. Simulator/UI regression is waived for this delivery; the user
will perform physical-device acceptance. Signing, bundle/profile validation,
Apple processing and internal-group availability remain required.

## Integrated changes

| Feedback | Change | Evidence and remaining limit |
| --- | --- | --- |
| Office close/load timeouts | Queue close until an in-flight native open settles, avoiding an early discarded close message. Failed opens settle their waiting close. Keep recovery copies on errors. | Code review; accepted-SDK App compilation and device use pending. A genuinely failed LibreOffice process still requires an App restart; a timeout is not proof the engine has stopped. |
| PDF/Office opened outside IDE or error 95 | Register native-document components in CodeBlitz internal editor tabs; overlay existing protected PDF and Office surfaces in the component rectangle. Maintain sessions across tab activation and close only when the editor is actually closed. | JavaScript parsing and 22 focused routing/visibility invariants passed. Parent IDE controls now observe Office session changes. Device interaction pending. |
| Git initialization | Local initialization no longer requires GitHub login. Preserve existing repository HEAD and configured identity; extend repository lifetime while consuming SwiftGitX borrowed collections. | Focused source checks; current device crash stack unavailable, so the exact physical crash cause is not established. |
| Mind-map controls and movement | Replace MindElixir with a native editor using shared Canvas geometry. Use icon controls; persist independent node positions, explicit relayout/reparent actions, undo, styles, links, images and export. | Nine focused model/layout cases and a FloeNotes object build passed. Existing data without positions remains readable. Visual/device acceptance pending. |
| Shell busy/no output and service errors | Serialize interactive and one-shot sessions on the actual native engine gate; retain ownership until the worker exits. Flush queued input before EOF, close failed input descriptors once, honor pre-cancelled opens. Validate service entry/cwd/runtime/port before persisting a job. | 71 native bridge host checks and 18 extracted SessionIO host checks passed. Their new defect cases fail against the earlier source. These are host harnesses, not iOS runtime proof. An uncooperative native command cannot safely be force-unlocked. |

## Work still being integrated

- Cross-task search/read pagination and final-response continuation: preserve
  cursor/source identifiers through bounded tool envelopes and compression,
  without skipping unread records. The first implementation is under correction.
- Local-model continuation and memory/compaction recovery: actual process budget,
  tool-catalog growth and recoverable checkpoint behavior. No current device
  crash stack is available; the screenshot alone does not establish a cause.
- Linux execution: qualify pinned TinyEMU against a usable guest, then connect
  environment-owned Shell, local Python and services. A legacy demo boot is
  insufficient to claim modern Linux/APT support. Existing native/WASM execution
  remains available until the replacement is qualified.
- Package responsibilities: APT manages Linux packages; Python, Node and WASM
  have separate entries. Shell and local Python in one Linux environment must
  use the same interpreter/package installation. Linux ELF extensions are not
  directly loadable by iOS CPython.

## Validation and delivery record

- Xcode 27 / Swift 6 syntax parsing passed for 29 changed App/module Swift files.
  This does not establish type/SIL compilation against the accepted upload SDK.
- An initial aggregate parse mistakenly included a standalone host script among
  module files and rejected its top-level statements. Restricting the input to
  App/module files corrected the check; no source assertion was weakened.
- The sanitized App Store Connect crash query returned HTTP 403 in
  [run 35492782697](https://github.com/JiangNanGenius/floe-agent/actions/runs/35492782697).
  No current crash report was obtained; this is not evidence of no crashes.
- Release route: one accepted-SDK App build, preserve the exact-source unsigned
  IPA and matching private symbols before signing, then validate/upload and
  verify Apple `VALID`, unexpired and availability in the existing Floe QA group.
  No production release is authorized by this repair task.

## 中文交付约定

本轮先完成代码和必要定向检查，通过云端完整 App 编译后上传 TestFlight。
不反复点界面，真机交互由用户验收。构建成功、工件保留、上传接受、Apple
处理完成和 Floe QA 可安装分别记录；尚未通过的 Linux 能力不会写成已可用。
