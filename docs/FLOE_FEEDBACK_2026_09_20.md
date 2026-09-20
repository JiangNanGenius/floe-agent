# September 20 feedback repair and delivery

Status: build 207 compiled and uploaded successfully; Apple processing is still
pending. Build 208 was cancelled before upload after a Linux package-ownership
gap was found. That code path is being corrected for build 209. Physical-device
acceptance remains with the user. Integration starts from `b16cb18e` (the build 204
delivery record). The prior build remains independently recorded.

The user requested code-first delivery, focused checks and an expedited
TestFlight build. Simulator/UI regression is waived for this delivery; the user
will perform physical-device acceptance. Signing, bundle/profile validation,
Apple processing and internal-group availability remain required.

## Integrated changes

| Feedback | Change | Evidence and remaining limit |
| --- | --- | --- |
| Office close/load timeouts | Queue close until an in-flight native open settles, avoiding an early discarded close message. Failed opens settle their waiting close. Keep recovery copies on errors. | Code review and build 207 accepted-SDK App compilation passed; device use pending. A genuinely failed LibreOffice process still requires an App restart; a timeout is not proof the engine has stopped. |
| PDF/Office opened outside IDE or error 95 | Register native-document components in CodeBlitz internal editor tabs; overlay existing protected PDF and Office surfaces in the component rectangle. Maintain sessions across tab activation and close only when the editor is actually closed. | JavaScript parsing and 22 focused routing/visibility invariants passed. Parent IDE controls now observe Office session changes. Device interaction pending. |
| Git initialization | Local initialization no longer requires GitHub login. Preserve existing repository HEAD and configured identity; extend repository lifetime while consuming SwiftGitX borrowed collections. | Focused source checks; current device crash stack unavailable, so the exact physical crash cause is not established. |
| Mind-map controls and movement | Replace MindElixir with a native editor using shared Canvas geometry. Use icon controls; persist independent node positions, explicit relayout/reparent actions, undo, styles, links, images and export. | Nine focused model/layout cases and a FloeNotes object build passed. Existing data without positions remains readable. Visual/device acceptance pending. |
| Shell busy/no output and service errors | Serialize interactive and one-shot sessions on the actual native engine gate; retain ownership until the worker exits. Flush queued input before EOF, close failed input descriptors once, honor pre-cancelled opens. Validate service entry/cwd/runtime/port before persisting a job. | 71 native bridge host checks and 18 extracted SessionIO host checks passed. Their new defect cases fail against the earlier source. These are host harnesses, not iOS runtime proof. An uncooperative native command cannot safely be force-unlocked. |

## Runtime and package changes integrated in build 208

- Cross-task search/read pagination and final-response continuation: preserve
  cursor/source identifiers through bounded tool envelopes and compression,
  without skipping unread records. Cursor-true UTF-8 pagination and full stored
  message reachability are integrated, with 40 focused harness assertions passing.
  Cloud-provider empty completion now gets one bounded continuation after a
  successful history lookup. Empty budget/no-progress finalization is a
  recoverable failure, including when tools must stay disabled. App compilation
  and physical acceptance of these changes remain pending.
- Local-model recovery is integrated: native tokenizer overflow now reaches
  one compaction retry; existing low-memory rejection reaches bounded recovery.
  Prompt shaping accounts for selected tool schemas and mixed-script text with
  an approximate token estimate; the real tokenizer remains the final guard.
  The newest receipt keeps identifiers instead of being dropped whole. A 23-case
  pure Swift budget harness passed. Current process-memory measurement was
  already present and is preserved. No device crash root cause is claimed.
- Linux execution: qualify pinned TinyEMU against a usable guest, then connect
  environment-owned Shell, local Python and services. A legacy demo boot is
  insufficient to claim modern Linux/APT support. Existing native/WASM execution
  remains available until the replacement is qualified.
- Package responsibilities: Linux-only APT routing, separate Python/WASM agent
  tools, existing Python/Node UI entries, and a signed WASM download directory
  are integrated. Tool schemas and 34 new bilingual strings were checked.
  The Linux UI reads the real guest package database when a runner is available;
  a stopped Linux environment must not fall back to host package storage.
  The recommended Linux download list is integrated; backend integration is included in build 208. Shell and local Python in one Linux environment
  share a persistent venv and can use its distro site-packages. Linux ELF extensions are not
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

## Expedited build attempts

- Build 205 / beta.62 failed the required Office dependency pin check before App
  compilation. The native host was rebuilt in run35495484711 and its archive,
  executable, manifest and source hashes verified; no pin check was bypassed.
- Build 206 / beta.63 passed that dependency step but failed accepted-SDK App
  compilation on IDE/mind-map call sites. [Original evidence](qualification/build206-release/build206-compile-failure.md)
  is retained; no IPA or upload was produced.
- Build 207 / beta.64 uses corrected call sites at immutable source
  `41b03ad5` in [run35497153478](https://github.com/JiangNanGenius/floe-agent/actions/runs/35497153478).
  It is a first device candidate for Office, internal IDE documents, Git, native
  mind maps and Shell repairs. Runtime and new Linux/package changes are still
  being integrated separately. The accepted-SDK App compile passed; the workflow
  retained unsigned IPA artifact `10601633343` (803812105 bytes) and private symbols
  `10601593620` (134122129 bytes) before signing. Signing, validation and upload succeeded; signed TestFlight evidence is retained as
  artifact `10601950027`. Apple build processing and group availability are not yet claimed.

The Linux recommendation table includes the packages for all 13 missing command
names reported in the screenshots. This is a package mapping, not execution
acceptance. For example, Debian trixie riscv64 [7zip file contents](https://packages.debian.org/trixie/riscv64/7zip/filelist)
include `/usr/bin/7z`; the UI installs the real `7zip` package. Actual guest
installation/execution remains unverified until a usable Linux image is ready.

A source-only follow-up review caught a test-call argument-order error and an
empty forced-finalization branch; both are corrected in `01eca877`. The review
ran no builds, tests or UI. Newly added App and runtime behavior still needs
the accepted-SDK cloud build and the user's device acceptance.

The pinned TinyEMU engine and App backend base are now integrated. The real cloud
probe [35497742193](https://github.com/JiangNanGenius/floe-agent/actions/runs/35497742193)
passed Shell, fork/wait, pipes, signals, PTY and persistence checks, but APT HTTPS
failed with SIGILL; package installation, NumPy and Node did not pass. Its summary
JSON also failed serialization. Neither a successful probe process nor fixing
the summary is Linux package acceptance. Guest image distribution still requires
accurate corresponding-source and license records. Native execution remains the
default while those conditions are unresolved.

## Cancelled integrated candidate: build 208

[Run 35499610010](https://github.com/JiangNanGenius/floe-agent/actions/runs/35499610010)
was cancelled at immutable `v1.7.0-beta.65`, source
`37fe9864e16999bcbd55f93ad9bd36bb306a4b49`. This includes the original repair slice,
local-model and cross-task recovery, package entry split, actual guest runner,
App Linux services/PTY/shared Python routing and verified image import code.
The four target build numbers and generated project match; 1121 bilingual
localization entries passed validation. Full TinyEMU MIT/BSD notices are bundled
and readable in Settings. No extra UI regression was run.

Linux host-consumer checks passed 34 cases, with real native process exchanges;
the guest protocol harness passed 66 assertions. These do not qualify the
current Linux image. The catalog remains empty and native execution stays the
default while APT compatibility and the exact image source record are unresolved.
See [build 208 test notes](RELEASE_NOTES_1.7.0_BUILD_208.md).

### Follow-up found before build 208 upload

`EnvironmentLanguagePackageService` still read Python/Node metadata from native
layer paths and used the native Node installer even for a selected Linux guest.
Mapping a Python interpreter alone did not establish correct installer staging
and readback. Build 208 was cancelled before upload to avoid shipping that
new ownership mismatch. The original build 207 repair slice is unaffected.
OpenCode is closing install/remove/list/source handling across guest package UI,
tools and Shell before the next candidate.

The APT SIGILL was traced to TinyEMU rejecting FENCE.TSO in libapt-pkg. The
compatibility patch now also reaches the App's vendored engine; a read-only
pristine-plus-patches comparison passed. The real guest runner compiled and
executed in run35499020441, while package installation still failed there.
The corrected CPU is undergoing a separate targeted HTTPS/APT/NumPy/Node probe
in [run35500083112](https://github.com/JiangNanGenius/floe-agent/actions/runs/35500083112).
This is not yet a qualified downloadable image.
