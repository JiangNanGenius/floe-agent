# Build 156 feedback repair — build 172 delivery tracking

## 2026-09-22 — Build 222 Runtime v2 and PPT recovery candidate

The 221 device feedback is addressed in the Build 222 source candidate: old Linux images migrate through verified staging and atomic registry switching; missing 9P host directories are created before boot; install state is derived from verified storage and the boot probe; persistent environments use a shared base plus CoW delta; Linux and MLX share one heavy-runtime arbiter; local-model tool continuations retain stable schemas and recover errors without crashing the app. PPT opening now has a bounded recoverable outcome rather than an indefinite spinner. Local evidence is compilation/policy testing only; device behavior remains unverified until TestFlight acceptance.

## 2026-09-20 — Shell gate/session recovery and background-service preflight (post-build 204)

User feedback after build 204: repeated `exec.shell` exit 75 not-started with the
same gate owner/quarantine owner; `shell.open` alive but `shell.exchange`
reporting `bytesWritten=0`/no output; `jobs.submit` → `exec.localService`
failing with a hard-to-understand missing-`port` error and discovering a
missing entry script only at run time.

Changes on `codex/feedback-shell-recovery` (no App-environment or UI redesign):

- Interactive sessions now share the process-wide engine run gate.
  `FloeShellOpenSession` acquires the gate (bounded, cancellation-aware),
  reports `Busy` instead of entering the engine alongside another worker, and
  the session thread's own teardown releases the gate exactly once after its
  engine call returns. A live session and a one-shot command can no longer use
  the engine concurrently; a session whose program never returns quarantines
  the gate exactly like a non-cooperative one-shot worker. Exit-75 diagnostics
  now name a quarantined owner and its consequence explicitly.
- Terminal input/EOF/cancel coordination: session input writes are serialized
  with EOF under the pump lock; exactly `\u{0003}` routes to cooperative
  interruption and exactly `\u{0004}` closes stdin (real EOF on the pipe);
  the pump wakes promptly on input so exchange counters no longer report
  `bytesWritten=0` for accepted input; a program that stops reading no longer
  kills output draining. Per-keystroke `ShellCommandPolicy` screening of
  exchange input is removed (it broke ordinary typing); the policy boundary
  stays on the session-opening command and one-shot runs.
- `jobs.submit` gains an optional per-tool workspace preflight:
  `exec.localService` rejects a missing/unreadable entry, a missing cwd, a
  bad runtime or an out-of-range port synchronously at submit time with
  actionable messages, before the durable job record exists. Decoding errors
  for missing required arguments now include the argument's schema
  description.

Local evidence: `FloeAgent/scripts/tests/run_feedback_shell_bridge_host.sh`
passes 58/58 host checks including the new session/one-shot gate-serialization
cases; `swift build --target FloeExecution` and
`swift build --target FloeExecutionTests` compile clean; `swiftc -parse` passes
on every touched app-target file. The new `BackgroundJobTests` preflight pins
compile but are deferred to cloud CI with the full test matrix. Device
verification of the exit-75 recovery, interactive input/EOF behavior and
submit-time preflight remains with the user's next TestFlight build.

## 2026-09-16 — Soul and profile changes apply to active runs

The settings path already saves active revisions, but an active Agent kept the
Soul/profile strings captured when `ConversationRunService` was constructed.
The shared run factory now supplies an atomic persisted snapshot before each new
logical provider request. Workspace overrides still precede global documents;
inactive automatic drafts remain excluded. A transient request retry preserves
its exact envelope. The anchored run-start clock remains stable.

The runtime replaces its explicitly owned system message rather than appending
another profile or overwriting a historical summary. The owner ID survives a
checkpoint, with conservative recognition of legacy app-generated contracts.
Context protection retains this message through compaction. Notes and Canvas
retain their own conversation/document context while using the same lookup.

[Native results](evidence/floe-1.7/live-personalization/result.json): three tests,
five cases passed using the current runtime and persistence sources. This is a
focused macOS module harness, not App or device acceptance. The original harness
setup failures and corrections remain recorded. The App integration call site
passes parsing; clean App compilation and UI validation remain separate cloud
steps. No new TestFlight upload is represented by these results.


This record tracks the September 14 feedback plan, delivered as internal build 172. Earlier checkpoints retain their original results; this is not a claim of complete device or feature acceptance.

Current delivered beta: **build 172**. The production open arc from `a266c0a` passed [all four SDK/device component paths](evidence/floe-1.7/release-167/above-arc-qualification.json) in [run 34846659384](https://github.com/JiangNanGenius/floe-agent/actions/runs/34846659384), including three anchors, movement without committing, explicit taps, toggling and blank dismissal. Original screenshots are retained privately. The subsequent user-requested changes add persistent above/upper-left/upper-right placement and eight native brushes with independent settings and native stroke previews. Before the build 171 expression-only refactor, brush UI and persistence checks passed across both SDKs and both devices: [12 UI cases](evidence/floe-1.7/release-167/brush-ui-qualification.json) and [20 native unit cases](evidence/floe-1.7/release-167/brush-unit-qualification.json). The refactored arc now passes [32 checks across all four paths plus both device Release compiler checks](evidence/floe-1.7/release-172/brush-qualification.json); original failed attempts are retained. The SDK 27 source run passed 1,270 Swift executions, 159 finalized full-App regressions and the Notes UI case on both devices. Accepted-SDK simulator qualification was waived for the direct upload; device build and signing/upload succeeded. Apple VALID / IN_BETA_TESTING and the existing internal Floe QA group were verified at 2026-09-14 17:52:18 UTC. [Build 172 availability](evidence/floe-1.7/release-172/TESTFLIGHT_AVAILABLE.json).

Build 166 (`82cccf4ead7e64e5d8600c476142a4a362a3282f`, `v1.7.0-beta.23`, [release run 34843027626](https://github.com/JiangNanGenius/floe-agent/actions/runs/34843027626)) was cancelled before upload. Its [component run 34842984634](https://github.com/JiangNanGenius/floe-agent/actions/runs/34842984634) passed iPad under both SDKs, but SDK 26 iPhone retained the wheel after repeated selection and SDK 27 iPhone did not finalize before the step deadline. Original screenshots also showed unwanted rectangular system chrome around the circle. These failures are not waived by the iPad passes.

Build 165 (`b80864f6fa566674a38e9b5924d9735137d597e4`, `v1.7.0-beta.22`, [run 34840920641](https://github.com/JiangNanGenius/floe-agent/actions/runs/34840920641)) was cancelled before upload when the user replaced its three-row palette with the radial interaction requirement.

Build 164 (`f150e888028aa20a0131240e0c3d259756cac304` / `v1.7.0-beta.21`, [run 34833194332](https://github.com/JiangNanGenius/floe-agent/actions/runs/34833194332)) passed SDK 27 module, App and dual-device UI tests. Its run was cancelled before upload to incorporate the new requested scope; it was not delivered to TestFlight or published as a GitHub Release. Its evidence and screenshots below remain valid only for that source.

Build 165 adds ordered document tabs with independent page/tool/zoom state, close-without-delete, persisted open tabs with the library remaining the initial screen, and Office save guards before switching. The document title/tab header can be hidden while writing tools remain accessible. Build 166 replaces the three-row palette: squeeze opens a circular wheel with fixed pen/highlighter/eraser/lasso/AI selection positions and current-tool highlighting. Selecting a tool immediately dismisses the wheel; center cancel preserves the current tool. Color and width remain in the writing toolbar. Native gesture delivery still requires the user's hardware check.

The release workflow now builds each SDK's simulator test hosts once and uses `test-without-building` for App regressions and both device UI cases. Debug test hosts retain the existing DEBUG-only UI fixtures; independent Release device builds remain mandatory under both SDKs. This removes the extra SDK 27 simulator Release build and separate UI host build requests. Both SDK jobs now start from a small immutable-source preflight and run independently. Signing/upload joins their successful results and restores the accepted-SDK app from a SHA-256-checked artifact with matching source/version/build; it does not recompile it. Actual wall-clock savings have not yet been measured.


Previous candidate: **build 163**, `7ef24846e87da67fe3f5b5db9fad545489dc7be8` / `v1.7.0-beta.20`, [release run 34823071123](https://github.com/JiangNanGenius/floe-agent/actions/runs/34823071123). This candidate includes the independently identifiable toolbar controls and full 44-point button hit regions. Its UI gate failed; archive, upload and GitHub publication were skipped.

Build 163 release source `7ef2484` passed [1,266 module executions](evidence/floe-1.7/release-163/swift-qualification.json), SDK 27 Release compilation and [157 finalized App regressions](evidence/floe-1.7/release-163/sdk27-app-qualification.json). Both devices passed the foreground editor/header checks. The UI gate then found a real iPad placement error: the palette marker was at y = -62, outside the window. A positioned transparent overlay supplied the wrong popover attachment bounds. The follow-up uses a normalized point on the actual canvas viewport and lets the system select the arrow edge. It also allows subpixel AX rounding in the 44-point hit-area checks; the iPhone failure was 43.999999999999986 versus 44. A small qualification host exercises the production presenter and button style at top, center and bottom anchors before full-App qualification.

Local palette qualification passed all three iPad anchors. The initial iPhone run reached and selected the palette but checked the underlying toolbar during its dismissal transition; the test now waits for the control to become hittable. Subsequent local attempts failed at simulator App launch or AX initialization, before validating the correction. Original results are retained privately. The focused cloud workflow now runs this production presenter on both devices under SDK 27 and the accepted SDK 26; these component results cannot replace the complete App UI gate.

The [cloud component evidence](evidence/floe-1.7/release-164/palette-component-qualification.json) confirms one passing iPad case under each SDK, with all three anchor positions, selection and dismissal. Its iPhone paths failed before menu assertions: SDK 27 timed out launching the App, and SDK 26 reached the step deadline before initialization. These results do not qualify iPhone behavior. The full Floe release workflow retains its mandatory dual-device Notes UI gate before archiving or uploading.

The fixed build-164 release source has passed [1,266 module test executions](evidence/floe-1.7/release-164/swift-qualification.json): 1,164 main, 12 JavaScript engine, 12 JavaScript tool, 61 platform and 17 Notes. The module result alone does not establish App or distribution acceptance.

Build 164 also passed SDK 27 complete App compilation, [157 finalized App cases](evidence/floe-1.7/release-164/sdk27-app-qualification.json) with normal driver exit, and the [complete Notes UI case on both devices](evidence/floe-1.7/release-164/sdk27-notes-ui-qualification.json). The latter covers import, the compact full-screen header, palette selection/dismissal and body search. [Twelve original screenshots](validation/floe-156-feedback/screenshots/full-app-build164-sdk27/manifest.json) are retained and selected images are used in both guides. Accepted-SDK and distribution gates remain open.

The user also explicitly requested a GitHub Release for this round. After successful qualification and verified TestFlight availability, publish the paired **prerelease** page with reviewed developer assets and bilingual notes; a Git tag alone does not fulfill that delivery.


Previous candidate: **build 162**, `07ff6ffef9dadd9d403db6e790cc646f5422d7cd` / `v1.7.0-beta.19`, [release run 34814479336](https://github.com/JiangNanGenius/floe-agent/actions/runs/34814479336). This includes the compact Notes header, native Pencil quick palette and corrected navigation/task-creation test selection. Build 156 remains the latest verified TestFlight delivery.

Build 162 has now passed [1,266 Swift/module executions](evidence/floe-1.7/release-162/swift-qualification.json), SDK 27 simulator Release compilation, and [157 full App cases in 13 suites](evidence/floe-1.7/release-162/sdk27-app-qualification.json), with a finalized xcresult, no failures/skips and a normal test-driver exit. Both home suites executed and satisfied their separate minimums. Its Notes UI step subsequently failed on `back.isHittable` on both devices, before the palette assertions, so it was not archived or uploaded. The video ends with the new full-screen editor visible. Source review found a duplicate `notes.back` in the covered library toolbar; build 163 removes this obsolete entry and waits for the single foreground back control to become hittable after presentation. It also retains an accessibility-tree attachment. These corrections require a new passing UI run; the video is not a passing test or a hardware Pencil result. Accepted-SDK qualification and distribution remain pending.


Build 163 source `575e3dd` then passed SDK 27 full-App compilation, the accepted-SDK compatibility build and [all 157 App regressions](evidence/floe-1.7/release-163/ci-575-app-qualification.json) in [CI 34819547461](https://github.com/JiangNanGenius/floe-agent/actions/runs/34819547461). Both Notes UI cases failed because `notes.back` was absent. The retained accessibility tree supplies the root cause: every header button inherited `notes.editor.header`, masking its individual identifier; several unselected glyphs also exposed only a small hit region. The follow-up removes shared identifiers from the header/palette stacks, puts a 44-point content shape inside the button label, and keeps the individual control identities. UI checks now also require 44-point return, palette-entry and marker targets, and retain the tree even when the return control is missing. The next release pipeline must pass both devices before archive/upload; this correction does not waive that gate.


## Previous qualification checkpoint — build 159

The previous candidate was `ce7b514ed792f3cd17936a5ba55934f27eadfd9e` / `v1.7.0-beta.16`. [Release run 34804583803](https://github.com/JiangNanGenius/floe-agent/actions/runs/34804583803) has passed 1,266 Swift test executions: 1,164 main, 12 JavaScript engine, 12 JavaScript tool, 61 platform and 17 Notes. These are executions across suites, not unique App or device cases. [Machine-readable evidence](evidence/floe-1.7/release-159/swift-qualification.json) retains counts, exit status and log hashes.

Full App regression, SDK 27 and accepted-SDK iPad/iPhone import UI, signing, Apple processing and private-group availability remain open. Build 156 is still the latest verified TestFlight delivery. Earlier checkpoint statements below are a chronological history, not the current qualification result.

## Node shutdown correction — replacement build 160

Prior runtime candidate: `8631ee9e1721e5cb5616a36d734f40951af1bfe4` / `v1.7.0-beta.17`, [release run 34810670478](https://github.com/JiangNanGenius/floe-agent/actions/runs/34810670478). It finalized 155 passing App cases and exited normally, but the home-suite coverage verifier rejected the run as detailed below. It did not reach UI, archive or upload.

The final build-159 attempt-1 log supersedes its stale live-log prefix: all 155 App tests passed in 92.111 seconds, but XCTest completion never returned. Disabling optional Xcode diagnostics did not fix this exit failure. Both release attempts were cancelled without archiving or uploading. A separate exact-source CI run, 34808379042, finalized passing full-App Notes import/full-screen/body-search results on both iPad and iPhone (one case each, no skips/failures). Eight original screenshots and hashes are retained in [the ce7 manifest](validation/floe-156-feedback/screenshots/full-app-ce7/manifest.json). Its separate App-unit runner timed out after assertions; overall CI failed.

A desktop reproduction using the actual host script also hung on `process.exit(0)` while its command pipe stayed open. The sampled main thread was in `uv__threadpool_cleanup` → `uv_thread_join`; a filesystem worker remained in blocking `read`. The native bridge now configures its own command read descriptor as nonblocking, and the JS host uses bounded reads with a 20 ms retry instead of a permanently pending filesystem read. Descriptor ownership remains with the native bridge. Eight host regressions pass, including actual process exit after a completed job with the command writer still open, repeated workers, cancellation, live stdin and pinned package-manager startup. The later build-160 finalized App result now supplies embedded-runtime exit evidence. Its release gate still failed on home-suite selection; dual-SDK distribution remains pending.

Release App tests now retain bounded stall diagnostics for both SDKs. Their compile phase remains outside the quiet-test deadline; after tests begin, a stalled runner is sampled and returns a failure instead of waiting indefinitely. Five diagnostic-runner tests pass. Neither completed assertions nor forced driver termination satisfy the xcresult verifier.

## Toolbar and Pencil follow-up — build 161 compile checkpoint

Candidate `178c89a2d6a7e08aeaeaa6fa47a414f7e5c3b902` / `v1.7.0-beta.18` ran [release qualification 34811854023](https://github.com/JiangNanGenius/floe-agent/actions/runs/34811854023). Its SDK 27 simulator Release compile passed; the run was then cancelled because it retained the incorrect home-suite gate, before UI or distribution. Its [1,266 Swift/module executions](evidence/floe-1.7/release-161/swift-qualification.json) passed (1,164 main, 12 JavaScript engine, 12 JavaScript tool, 61 platform, 17 Notes); full App and UI qualification remain pending. Build 160 also passed the same scoped counts and its SDK 27 simulator Release compile; its test-host shutdown evidence is recorded separately below.

The extra Notes navigation row is removed. Return, title/save state and document actions share the editor header; compact layouts put secondary document actions in a menu. Office keeps its own navigation toolbar. A native `UIPencilInteraction` receives ended squeezes and double taps, respects disabled/system-shortcut preferences, switches eraser/previous tool or presents a palette at the normalized hover position. The palette provides tools, ink color/width and undo/redo; a toolbar button exposes the same controls without Pencil Pro. Finger drawing stays opt-in.

The actual Pencil bridge and renderer passed SDK 27 Swift type checking against the existing native Notes module. Full-App iPad/iPhone UI coverage now checks the compact header height and changing tools through the palette, with a retained screenshot. These new UI assertions and physical Pencil gestures have not passed yet. The immutable build-160 run does not contain this later UI change.

## App shutdown finalized; home-suite gate corrected for build 162

Build 160 finalized its xcresult and exited normally: 155/155 App cases passed, zero failures/skips/expected failures, with `xcodebuild` exit 0. The release verifier then rejected the result because it expected eight cases inside `HomeChatSeparationTests`, while that suite contains six navigation cases. Two existing task-creation contract cases live in `HomeTaskCreationTests`, which the workflow had not selected. This is a rejected release gate, not a TestFlight delivery.

The corrected gate requires **both** six navigation cases and two task-creation cases, and selects both suites in CI and each release SDK. It does not reduce their combined minimum or waive missing cases. Four verifier regressions check both suites, either omission, and workflow selection. The next full App run must execute the two additional cases. The finalized build-160 result establishes the runtime exit correction, not acceptance of the later Notes toolbar.

Build 162 also ensures system color/ink-attribute shortcuts expose ink controls when an eraser or lasso was active, and dismisses the separate ink popover before opening the quick palette. New full-App UI and distribution remain pending.

## Changes under qualification

- Remove the app-level 100-tool-call cap; preserve runtime no-progress, per-call timeout and output protections.
- Preserve nonzero tool exit codes as failed tool and background-job results.
- Reconcile text/vision capabilities with persisted auxiliary-use flags without requiring a re-save.
- Add `browser.panel` requestUser/hide: ordinary navigation and previews stay in the background; an explicit reason hands control to the user and pauses automation. Hide cannot interrupt active user control or close another task’s panel.
- Keep browser/tool inspector presentation and dismissal independent of the main sidebar visibility, preserving the user choice.
- Track queued/running CPython work by environment until native completion; cancel trace/profile checkpoints after native calls and skip expired queued scripts.
- Fold prior timeline groups on the next group; reserve two lines for reasoning previews.
- Show “等待模型响应” before response content, without a redundant thinking row beside reasoning.
- Notes library grid and document full-screen route; eliminate simultaneous Office preview/editor hosts and await Notes commit before dismissing.
- Move one-shot native shell blocking work off the Swift cooperative executor; pass Node CLI options to the persistent host.
- Application-owned background URLSession Whisper transfers, persisted resume data, byte progress, relaunch restoration and verified-file reuse after interruption.
- Source add/edit/enable/disable/remove UI and environment-bound key verification; atomic managed source snapshots retain legacy source files for recovery.
- Pin certifi and configure embedded Python certificate paths at initialization.
- Repair optional checklist argument decoding; keep volatile runtime metadata after conversation/tool history without starting another user turn.
- Add persistent pen/highlighter color and width controls; include page images in Notes cover previews.
- Keep the Office editor mounted until the owning Notes resource commit succeeds.
- Remove per-frame PiP logging that displaced task diagnostics; export bounded durable run IDs, states and receipt counts without conversation content.
- Keep authorized shell schemas available at task start, describe POSIX command workflows and add Linux/Unix discovery synonyms. Unsupported command names are resolved at execution rather than rejecting quoted script data.
- Pass Python cwd, environment, dependency paths, argv and stdin into a serial native interpreter worker; restore state and remove project imports after execution. Support `python3 -m`, piped scripts and `printJSON`/shell exit codes.
- Bind managed Python install/remove/inventory to the selected environment and fix decoded-input handling in the removal entry point.
- Retain the one-shot shell execution lease, input file and native session until its worker really stops; queued calls remain cancellable and deadline-bound.
- Add actual iOS shell loops/pipelines/exported environment/Python/Node/repeated-run and stdin qualification cases.

## Evidence

- Both user JSONL exports inspected including final turns. Shell receipts contradict the self-report claim that Node is absent: a file printed v18.20.4. Timeout receipts were marked ok by the outer executor.
- Official-service read API verified using existing local credentials, without printing credentials. Latest report is version 1.7.0 build 156; 1,024 of 1,268 lines are PiP records and the relevant task run IDs are absent.
- The embedded Python runner script passed local two-project import/env/stdin/resultJSON/state-restoration checks. iOS host qualification remains pending.
- Existing Node host regression: 4 tests passed locally. This does not establish iOS bridge or App integration success.
- Changed Swift files passed parser checks; Whisper background coordinator passed a standalone Swift 6 type check with the local iOS 27 SDK. Full App acceptance remains pending.
- First checkpoint ebaa361 cloud run 34783445188 passed platform/Notes qualification, Linux build, native-host checks and App timeline/Canvas/PiP tests. The 135 selected App regressions passed. The package test stage exposed two obsolete JavaScript assertions requiring successful receipts for exceptions/timeouts; these now require failed receipts while retaining the error/exit code. Complete CI and the later edits still require qualification.
- Local package test attempt cancelled when SwiftPM planned an 11,129-step rebuild; heavy checks belong in cloud CI. Its incidental Package.resolved changes were reverted.

Second checkpoint e475212 qualification exposed a missing-leaf symlink escape in source writes and a concurrent AVFoundation cancellation teardown crash. Source resolution now checks each ancestor; media cancellation is idempotent. Both remain subject to cloud rerun. Package payload/removal tests passed locally (8); the shell C++ bridge passed SDK 27 syntax checking.

## Remaining gates

Latest open gates: complete App Shell/Python/Node/HTTPS and environment-isolation regression; iPad/iPhone complete App workspace import, fullscreen editing and screenshots; configuration hydration and stable-prefix/context replay review; official production apt source and package/model delivery; remaining Office/map interaction checks; signed TestFlight upload and availability; main merge and merged-branch cleanup. Native Whisper download/navigation/relaunch/cancel/process-interruption checks and native Notes OCR/search checks now have passing evidence below. Physical-device checks remain assigned to the user.

Do not equate this checkpoint, CI dispatch, source parsing or component tests with the finished plan.

Latest local targeted checks: seven Node host cases passed, including live stdin without EOF, async/sync input cancellation and execution after cancellation. A blocking-fd prototype failed cancellation, so the native bridge now pumps into a private nonblocking bounded pipe; descriptors remain owned until the pump and worker stop. SDK 27 C++ syntax checking with the real NodeMobile headers passed. The actual iOS bridge case has been added to the cloud App suite; it has not run yet. Node output is still collected until command completion, and Python interactive stdin/REPL remains an open gap.

Direct HTTP workflow check (`python3 FloeAgent/scripts/test_http_workflow.py`) compiles the actual Swift service and contacts a local HTTP fixture: HTML form endpoint, PATCH JSON, OPTIONS, final URL, pagination/retry headers, HTTP failure body and response cap passed without WebKit. Shared service cookies/credentials are disabled; scripts keep state explicitly in their workspace. This is macOS transport evidence, not iOS network or third-party-site acceptance. `network.http`/`web.fetch` now report HTTP errors as failed receipts. Short JSON/text and downloadable binary content do not automatically require browser rendering. Tool discovery teaches HTTP/API inspection before browser fallback.

Package payload entrypoint checks now total nine passing tests, including decoded dictionary input for Debian extraction. Extraction must produce an actual destination directory and a parsed file count; missing execution output no longer counts as an empty successful install.

Cache design reference: [DeepSeek context caching](https://api-docs.deepseek.com/guides/kv_cache/) specifies shared request-prefix reuse. Byte-stable prefix tests do not establish a particular server-side hit rate.


## HTTPS and search availability follow-up

- `FloeTLSEnvironment` resolves certificate paths from the current signed App bundle on each launch; Python/urllib/pip, curl and Node/npm use the same pinned certifi roots. Node extra roots are configured before its once-only initialization. The pip-vendored CA bundle is a recovery fallback. No certificate verification has been disabled.
- Local actual HTTPS requests to example.com passed through the Swift HTTP service, curl (verification result 0), Python's default verified SSL context and Node (authorized TLS socket). These host results do not substitute for the embedded iOS runtime; a three-runtime App test has been added.
- Search runners now have live availability checks at descriptor listing, lookup and execution. Required keys and endpoint fields are checked using the service's request contract. Disabled or incomplete providers are omitted from the runtime provider note as well. Bocha AI search requires an available Bocha configuration. A captured runner is rechecked when executed after settings change.
- Search settings loaded from iCloud are mirrored to local runtime defaults immediately, fixing one configuration path that previously needed another Save tap.
- Cloud 0c0f588 App run 34785833946 compiled but failed 13 assertions across shell integration and an obsolete MarkupSafe version probe. The shell failures began with Node command registration depending on apt initialization, then a missing pipeline consumer left an unpublished ios_system PID and blocked later commands. Node registration is now independent; literal missing consumers are rejected before opening a pipeline PID; command callbacks observe the shell deadline's cancellation flag. The MarkupSafe test uses distribution metadata. These changes require the next native/App rerun.

Local iOS 27 simulator NativeShell qualification passed with 11 command cases and interactive input after the pipeline repair. Machine-readable results are retained in [shell results](validation/floe-156-feedback/shell-results.json) and [interactive result](validation/floe-156-feedback/shell-interactive-results.json). This standalone target does not qualify the full App or its embedded Python/Node chain.

Cloud 4096d52 run 34787295524 passed platform qualification and all seven Node host tests, then exposed Python-version-dependent filtering in `importlib.metadata.files`. Managed removal now validates the literal RECORD before inspecting disk entries; nine payload/removal tests pass on local Python 3.9 and 3.14. The cloud App stage did not run in that checkpoint.

NativeNode qualification on the local iOS 27 simulator passed nine bridge cases and all seven adapter checks, including an authorized real HTTPS connection and live stdin cancellation. Evidence: [bridge results](validation/floe-156-feedback/node-results.json), [adapter results](validation/floe-156-feedback/node-adapter-results.json). Source files match 7099991; full App shell/Python/curl integration remains for CI run 34788348659. The earlier 0c0f588 App Store SDK compatibility build also succeeded; its App regression stage failed as recorded above.

### Language dependency management follow-up

Environment details now link to Python/PyPI and Node/npm pages with explicit selected-environment installation, owned versus inherited inventory, uninstall confirmation, persistent jobs and cancellation. These use the environment coordinator's management lease, so deletion must drain work. Python reuses the managed wheel installer and now accepts uninstall cancellation. npm installs stage an entire module generation with scripts and bin links disabled, reject native artifacts and lifecycle-script requirements, then commit with a recovery journal. The UI currently uses official PyPI/npm registries; it does not claim Linux native compatibility or install CLI shims.

Native Node on the iOS 27 simulator installed `is-number@7.0.0` over HTTPS into the selected layer, imported and executed it, preserved it when a nonexistent version failed, and uninstalled it. Evidence: `validation/floe-156-feedback/node-package-results.json`. This uses the production Node bridge and staged installer, not the complete App UI. Full App tests now cover Python and npm installation, import, cross-environment inventory isolation and removal; these are pending cloud results.

The Python installer now merges wheel files by RECORD ownership, removes old-version metadata during upgrades, preserves unrelated namespace files, checks installed dependency requirements and commits a recoverable package generation. Inventory and uninstall recover interrupted installation first. Thirteen payload/removal/upgrade/recovery checks passed on host Python 3.9 and 3.14, and a real PyPI colorama 0.4.5 → 0.4.6 upgrade succeeded in a temporary host environment. These are not embedded iOS Python results; the App regression includes actual install, downgrade/upgrade, import and removal.

### Expanded-command and pipeline cancellation follow-up

The native shell smoke now covers 22 cases plus interactive input. Literal and variable-expanded missing commands, a missing middle stage, successful variable-expanded consumers, and later commands all terminate. A newly reproduced `while :; do printf data; done | cat` timeout originally left the producer pipe open, wedging the consumer and later commands. The producer now closes/restores its streams on exception unwind before joining the consumer; the same test now exits 130 with its worker stopped and the next command succeeds. All 22 worker-stop checks and the interactive test passed on the iOS 27 simulator. Evidence replaces `validation/floe-156-feedback/shell-results.json` and `shell-interactive-results.json`.

The iOS shell still cannot safely execute builtin/function/compound consumers concurrently inside a pipe; these return explicit unsupported errors (exit 2), with script/file alternatives, instead of hanging. Native external consumers and compound producers remain supported. This is not a claim of complete desktop POSIX or native-process isolation. npm's global prefix now defaults to the selected environment's `usr` directory.


### Stable runtime identity and upgrade recovery

Ordinary App updates previously changed the environment base revision because it came from `CFBundleVersion`. The candidate uses an explicit runtime ABI revision instead. Build 156 is the sole legacy compatibility alias: its Python bootstrap, Node lock and dependency pins match this candidate. Migration retains the original registry and layer manifests as `*.pre-runtime-version-migration`, changes compatible metadata only, and preserves unrelated rebuild flags. Unknown runtime revisions still require rebuild without deleting dependencies. Migration rejects linked metadata paths.

The release workflow now selects the same home/chat and language-package regression suites as CI, so the TestFlight gate cannot omit the newly required package suite.

### Screenshot collection

Screenshots are retained under `validation/floe-156-feedback/screenshots/`, with device, source scope and observed state recorded in its manifest. Component fixtures are not presented as full-App or installed-package acceptance. The local NativeManagement build succeeded; XCTest failed to connect to the Simulator test runner before executing UI assertions. A separate browser mirror reached the real iPad fixture frame; navigation checks remain pending.

Environment durability qualification passed 16 tests locally with Swift Testing, including compatible runtime metadata migration, preserving unrelated rebuild flags, linked metadata rejection, management selection and deletion leases. Evidence: `validation/floe-156-feedback/environment-migration-tests.txt`. The new language-package suite is explicitly assigned to the App unit-test host, rather than the separate UI-test runner.


### Actual Whisper download and iPad component evidence

The NativeSpeech target uses production settings, installation and background URLSession code with the production pinned Hugging Face manifest. A real 490,671,464-byte installation succeeded on an iOS 27 iPad mini simulator. During a second download, leaving settings at 590 bytes retained the task; 35 subsequent running samples had settings hidden, and the download completed. Relaunch revalidated every installed file. A further test cancelled at 1,639,126 bytes, observed the task stop, retried and verified all 490,671,464 bytes. No inference was performed; system-initiated process restoration during an active transfer and physical-device suspension remain separate checks. Evidence: `speech-download-page-dismissed.json`, `speech-download-relaunch-verified.json`, `speech-cancel-evidence.json` under `validation/floe-156-feedback`. In the first recorder, `verified` retained the previous installation's value during reinstallation; the subsequent fresh process and cancellation test independently verified the completed generation.

Actual iPad component navigation reached selected-project details and Python management. Unaltered long/short reasoning screenshots have identical first-card background spans (156 native pixels at x=50); advancing to the next round hid the old tool cards. Screenshot source scope, dimensions and hashes are in `validation/floe-156-feedback/screenshots/manifest.json`. Automated iPad/iPhone component checks run separately in CI; these do not replace full-App acceptance.

### 用户补充范围（2026-09-14，尚未全部验收）

- 画布助手：统一面板尺寸与拖动边界，整理输入栏，更换语音图标；保留双端截图。
- 画布管理：修复删除后“最近／私人画布”残留，加入文件夹及内容搜索。
- 手记：外层全文搜索，显示文档内命中片段并定位；不能仅匹配标题。
- 会话整理及其他搜索：检查正文检索覆盖、结果片段及跳转；区分未索引与无结果。
- 交付结束后清理本轮临时构建与下载副本，保留源码、已归档证据和已有模拟器数据。

旧检查点 10d3443 的完整 App 回归没有通过：151 项测试报告 16 个问题。日志明确显示 shell 注册函数 `floe_shell_command_main` 无法被动态查找到，导致 Python/Node 命令未注册。另一个失败来自静态工具目录与已按配置过滤的运行时目录直接比较。正在修复，不能把独立运行时资格测试当成完整 App 通过。

新增验证：会话正文检索 3 项测试通过（中文片段、literal `%/_`、同会话超过 50 条消息、既有 FTS 排序与工作区范围）。手记 16 项存储测试通过，Office 文本缓存与不可变资源绑定，不改变编辑版本或撤销历史，替换资源立即使旧正文失效。Office 索引目前使用经过限制的 Open XML 读取器；不支持的旧二进制格式显示未索引，不能宣称所有格式均已可全文检索。扫描件与手写 OCR 的全库索引仍需补齐。

云端 NativeManagement 组件 UI：运行 34792006293，iPad 和 iPhone 各 4 项通过、0 失败。16 张原始截图已归档于 `validation/floe-156-feedback/screenshots/cloud-components`，具有来源与哈希清单。属于组件宿主，不是完整 Floe App 或真机截图。

本地已安全清理 `/tmp/floe-156-node-native-check`，逻辑大小 2,190,500,031 字节；删除前检查无打开文件，Node 运行/适配/包测试 JSON 已归档。未移除模拟器、安装的 App、其他构建缓存或源码。

最新源码继续补入逐页 Vision OCR（中文＋英语）与资源/笔迹版本绑定的缓存，过期结果不能覆盖新内容；这条真实识别链仍待原生样本验收。手记存储测试现为 17 项通过。增加“重新索引正文”恢复入口，扫描件、Office 失败或未完成索引数量在搜索时可见。

原生手记追加验证：iPad mini iOS 27 模拟器使用实际导入器、Vision、NotesSession 和持久索引，中文＋英文图片识别、检索、Word 自动索引及 Markdown 分页全部通过，耗时 9.95 秒。原始样本、JSON 和截图保存在 `validation/floe-156-feedback/samples/notes-search`、`notes-native-search-ipad.json` 与 `screenshots/ipad-notes-search-qualified.png`。这是独立原生宿主运行结果；本地 XCTest 未连接成功，不能将此结果写为 XCTest 或完整 App UI 通过。云端另增 iPad/iPhone 原生测试。

手记支持从 Floe 项目及聊天工作区选择文件，导入器复制原始数据后才释放来源访问权限；选择器关闭后再进入编辑器，避免与全屏编辑的呈现冲突。Agent 的限范围资料搜索也包含版本有效的 OCR 与 Office 正文缓存，保留来源类型。

shell 原生宿主新增动态注册回调的管道用例（索引 22），返回 `callback-resolved`、退出码 0 且执行线程停止。Debug 关闭可执行代码独立 dylib 后，该回调位于 ios_system 查找的主可执行文件。此结果不代替完整 App 的 Python/Node 注册回归。

Whisper 补充中断验证：在测试宿主安装进度为 1,639,126 / 490,671,464 字节时，对该宿主进程发送 SIGKILL。重新启动未传入开始下载参数，由生产恢复入口自动继续；56 秒后报告 490,671,464 字节完成、无错误、文件重新校验通过。证据为 `validation/floe-156-feedback/speech-process-interruption.json`。这是模拟器中的进程中断与恢复，不是系统触发的真机后台回收验收。


### 2026-09-14 native execution follow-up

Full App run [34793895830](https://github.com/JiangNanGenius/floe-agent/actions/runs/34793895830), source `a8b57c5`, built on the development SDK and passed the separate App Store SDK compatibility build. App assertions ran 153 tests and reported 13 issues; the test driver subsequently timed out, leaving an incomplete xcresult. This is a failed qualification, not a release result.

The actual failures identified argument re-parsing in `ios_execv` (JavaScript arrows became redirection), missing Dash exports at the runtime boundary, the upstream engine's PythonA/PythonB rewrite, missing cancellable sleep, and an empty dist-info directory left after uninstall. Dash now transports expanded arguments literally and passes exports through `ios_execve`; the production Python callback uses an internal command alias. Sleep is registered with cancellation. Uninstall prunes only empty parents of owned files; inventory tolerates empty remnants from older versions. Nonempty corrupt metadata still reports an error.

The persistent CPython host also reproduced a negative import-finder cache after first-time installation. Refreshing import caches at execution entry fixed the real install-then-import failure. The native iPad simulator host now passes colorama 0.4.6 → 0.4.5 → 0.4.6, imports 0.4.6, uninstalls, and verifies no remaining dist-info directories. Evidence: `validation/floe-156-feedback/python-native-package-results.json`. The package ownership/rollback host suite passes 13 tests. Native Shell now passes 26 cases, including literal punctuation/empty/CJK arguments, exported variables and repeated Python alias dispatch; that host uses callback stubs and is not a substitute for the full App Python/Node tests.

Cloud a633134 run 34798414773 executed 154 App tests in 12 suites, reporting 10 assertions in the shell Python/Node cases. Python package transactions and the remaining suites passed their assertions; the driver had not finalized its result bundle at this observation. The failure exposed a gap in the 26-case host fixture: upstream `concatenateArgv` adds another quoting layer to space-containing arguments, retaining 0x1e bytes in Python/JavaScript source. The follow-up serializes the literal command once and adds four argument cases covering spaces with neither, either, and both quote types. Full App requalification is required. Notes import UI acceptance remains pending; component screenshots are not presented as full App acceptance.

Cloud native Notes [34795345444](https://github.com/JiangNanGenius/floe-agent/actions/runs/34795345444), source `e7c8d23`, passes two XCTest cases on iPad and two on iPhone, using actual Vision OCR, Word indexing and persisted content search. Original OCR inputs and manifests are retained under `validation/floe-156-feedback/samples/notes-search/cloud`. These input images are not UI screenshots. Full App workspace-import UI and the repaired execution tests remain separate gates. CI now runs the built xctestrun directly to avoid re-resolving the package graph during test-without-building.

Finalized a633134 results: the App xcresult contains 154 cases, 151 passing and 3 failing (10 assertions in the shell Python/Node cases). The SDK 26 compatibility build passed. The iPad Notes UI case imported a workspace PDF, entered the full-screen editor and returned to content search, but exceeded its 180-second deadline after spending about 105 seconds waiting for the previous App process and starting the next one. Only three original PNGs were exported; the search capture logged after the deadline was not retained. The subsequent Xcode diagnostic collection timed out after 600 seconds, and the enclosing deadline prevented a valid iPhone result. This identifies a diagnostic-collection stall, not a demonstrated Node shutdown defect.

The UI test now terminates its previous App before changing orientation. Test invocations disable optional verbose diagnostic collection while retaining xcresults, logs, screenshot attachments and the bounded simulator sampler. Paper smaller than the editor viewport is centered with scroll insets, keeping its page-space origin aligned with PencilKit drawing and AI selection coordinates. The final candidate still requires passing App and dual-device import UI gates before TestFlight distribution.


### Build 157 gate outcome and replacement candidate

Build 157 / `b2ca8ee` / `v1.7.0-beta.14` was blocked before App archiving or upload by [34802882385](https://github.com/JiangNanGenius/floe-agent/actions/runs/34802882385). The Swift run executed 1163 cases across 18 target results; one case contained two obsolete assertions for private `os.makedirs` implementation lines. The installer now uses recoverable ownership-aware generations. The updated test checks that only the managed phase has installer privileges and adds an install-failure case proving user code never runs after failure. Actual payload and native package transaction evidence remains separate.

In parallel, a6a57e9 App run 34802103604 reported 155 cases with two issues in one newly added apt test. The test incorrectly applied the limited compatibility catalog contract to the full App’s registered `PackagesCLI`: `apt update` is valid there, but an unbound invocation correctly exits 100 with `no active container`. The corrected fixture tests unsupported `pkg update` separately from the unbound full apt command, including stderr and absence of success output. The previous Python/Node quoting and HTTPS failures did not recur in this run; its final xcresult and dual-device UI result remain pending.

The replacement candidate uses build 158 and preserves the failed 157 tag unchanged. No new build has been uploaded or marked available.


The a6a57e9 full-App iPad import case passed in 60.917 seconds: one case, zero failures/skips, four exported PNG attachments including the actual PDF body-search result. The iPhone case failed at its workspace-selection tap: a global title query selected the offscreen sidebar conversation (`sidebar.conversation.…`, x = -342) instead of the picker row with the same name. The test now scopes selection to the existing `workspace.import.source.` identifier and title. This is a locator failure, not evidence that the phone import succeeded or failed. Build 158 release run 34803874180 was cancelled before archiving/upload to avoid knowingly running that stale locator. Build 159 will qualify the corrected test; neither failed candidate tag is moved.

### Build 167 brush parameter follow-up

The `e5a42be` component run [34849747817](https://github.com/JiangNanGenius/floe-agent/actions/runs/34849747817)
failed overall. Its arc placement/tap/cancel/persistence UI case passed on all
four SDK/device paths, but native ink roundtrip and brush-canvas accessibility
checks failed. These failures are retained in private qualification evidence.
The revised checks compare the actual native tool's canonical stroke ink across
save/reopen (including identical rendered pixels), and read the fixture canvas
through its actual native tool rather than assuming its accessibility category.
A local runtime attempt could not connect to simulator testmanagerd; it is not
a passing test. The revised native host builds successfully, and runtime checks
are being rerun in four independent cloud device jobs.

The latest user-requested chooser replaces large brush cards with a compact tool
rack and one selected-stroke preview. The production panel is reused directly in
the qualification host. Per-brush opacity joins existing width/color persistence,
with backward-compatible decoding, native range clamping, width presets and
continuous controls. Full App and TestFlight delivery remain pending.

Run [34853249242](https://github.com/JiangNanGenius/floe-agent/actions/runs/34853249242)
at `f6874d5` completed all three production component UI cases on all four
SDK/device paths (12 UI executions passed): eight native tools, width/opacity
controls and relaunch persistence, and three arc placements at three anchors.
The four parameter/migration unit cases also passed on every path. The remaining
failure was the strict ink-identifier equality in the roundtrip test: native
monoline is written as pen ink on both SDKs, with identical rendered PNG output.
The revised test permits only this observed alias, additionally checks every
control point's position, dimensions and opacity, and still requires identical
rendering. Only those unit checks need rerunning; production UI source is unchanged.
Original component screenshots remain separate from complete App screenshots.

### Build 168 download recovery

Build 167 / `v1.7.0-beta.24` at `5e50569` failed before App qualification in
[run 34855706377](https://github.com/JiangNanGenius/floe-agent/actions/runs/34855706377).
No TestFlight upload or GitHub app prerelease occurred. The SDK 27 bootstrap
received repeated 504 responses for the Brotli simulator wheel; the accepted
SDK reached package resolution and received 504 responses for seven shell
framework assets. Original build logs are retained privately.

The same Brotli wheel is available through GitHub's release API with the exact
locked SHA-256. Build 168 adds an API fallback for failed GitHub wheel downloads,
while preserving checksum validation and atomic cache commits. Three focused
checks cover successful fallback, corrupt data rejection, and refusing to use
the GitHub API for other hosts. The nine shell binary targets use the explicit
`?download=1` route to the same assets; all checksums remain unchanged. The awk
artifact was downloaded from that route and verified against its original hash,
and the package manifest parses successfully. No brush/editor source changed.

### Build 169 verified artifact cache

Build 168 / `v1.7.0-beta.25` at `3796367` recovered wheel downloads and reached
module tests on SDK 27, but SDK 26 package resolution still received 504 responses
for two shell frameworks despite explicit download routing. Run 34857185974 was
stopped after that failure; no signed upload or GitHub app release occurred.

Build 169 preloads all nine shell framework archives using GitHub's release API
and verifies their manifest checksums before atomically publishing them to a
SwiftPM cache. Xcode is explicitly given that cache path. The original manifest
URLs and digests are retained, and SwiftPM independently checks each archive
when extracting it. A focused local native SwiftPM resolution (no App build)
verified all nine cache hits from an otherwise empty package build directory.
Python wheel downloads prefer the release API when available and retain HTTPS
fallback. Seven focused transport/cache tests cover valid reuse, corrupt payloads,
foreign-host rejection and API unavailability. Brush and editor source is unchanged.

### Build 170 workflow validation

Build 169's workflow was rejected before any job started because `runner.temp`
is unavailable in a job-level `env` expression. The cache path is now initialized
in a setup step through `GITHUB_ENV`. Actions semantic lint (with the repository's
existing `xcode-27` runner label declared) and shell syntax validation pass.
No application or dependency implementation changed in this correction; build
170 supersedes the unstarted build 169. Published tags are not moved.

### Build 170 device compiler gate and build 171

The fixed 170 source passed 1,270 Swift test executions. Its SDK 26 device
Release build failed in the tool arc button's nested SwiftUI background
expression because type checking exceeded the compiler limit. SDK 27 work was
cancelled after this failure; no App archive or TestFlight upload is claimed.
See the [preserved outcome](evidence/floe-1.7/release-170/release-outcome.json)
and [Swift test summary](evidence/floe-1.7/release-170/swift-test-summary.json).

Build 171 extracts the button view and explicitly types its color and opacity
values. Selection, preview and dismissal behavior are unchanged. Component CI
now compiles a device Release host once per SDK as well as running the existing
iPad/iPhone unit and UI checks. Full App qualification and delivery remain pending.

### Build 171 generated project gate and build 172

Build 171 stopped before SDK 27 App compilation: `project.yml` declared 171,
while the committed generated Xcode project still declared 170. This was a
release-preparation omission. No upload occurred; the other SDK job was cancelled.
Build 172 regenerates and commits the matching project. The initial release
preflight now checks every generated marketing/build version before expensive
dependency setup; the full xcodegen consistency gate remains enabled.
The production brush code is unchanged from `84c85f5`.

### Refactored Pencil component qualification

[Run 34863262123](https://github.com/JiangNanGenius/floe-agent/actions/runs/34863262123)
passes all four SDK/device paths: eight cases each, zero final failures or skips,
plus SDK 26 and 27 device Release compilation. SDK 26 iPhone first lacked a
simulator; SDK 27 iPad first timed out reading the native reed tool through AX.
Both failed jobs passed unchanged on attempt 2. The original logs/recording remain
private, and the [public qualification summary](evidence/floe-1.7/release-172/brush-qualification.json)
keeps these failures explicit. Full App and TestFlight gates are separate.

### Requested expedited TestFlight delivery

The user requested a new TestFlight build for personal testing, allowing the
dual-device qualification gate to be bypassed when this speeds up delivery.
The new distribution-only path reuses the exact-tag accepted-SDK artifact from
run 34864482336 and does not wait for SDK 27. It checks the source workflow, tag,
commit, accepted-SDK job and artifact provenance before restoring the application;
version, bundle identifier, signing and Apple validation remain mandatory.
The already-running source job cannot be edited in place, so its existing steps
continue until the artifact is retained. Nothing is rebuilt by the upload path.
Incomplete qualification remains separate from actual TestFlight availability.

### Direct upload recovery for build 172

The user requested TestFlight first and waived dual-device qualification as an upload gate. The first retained-artifact uploader (`34868515365`) could not run: the original SDK 26 job compiled both device Release and simulator hosts, then failed before executing App tests because its simulator selector found three same-name devices across installed iOS 26 runtimes. Its old workflow discarded the built device package instead of retaining it. No upload occurred.

The direct workflow in policy commit `9c741b0`, [run 34870170373](https://github.com/JiangNanGenius/floe-agent/actions/runs/34870170373), checks out the unchanged immutable app source `fb86fef896d41871fa98c8871237606f56c5ff39` / `v1.7.0-beta.29`. It builds only the accepted-SDK device app, retains an unsigned recovery IPA before signing, checks profiles and bundle metadata, and performs Apple's validation and upload. Simulator builds and tests are explicitly skipped in this direct run. Apple processing and Floe QA visibility still require separate readback. The half-hour target is not a guaranteed completion time.

The original SDK 27 job separately finalized 159 App cases, all passed with zero failures or skips. These results do not imply iPad/iPhone UI or physical-device acceptance. The duplicated simulator selector is repaired for future runs: choose an available device on the newest installed matching-major runtime and pass the same UDID to both diagnostics and xcodebuild. Four selection regressions cover multiple runtimes, duplicates, unavailable devices and a missing target.

## PowerPoint visible-render and edit repair (2026-09-22)

The presentation editor could report itself ready while the engine never painted
a slide. Root cause, from the pinned engine sources and the shipped `bundle.js`:

- The mobile editor starts every editable document in its viewing-first UI
  (`Permission.js` calls `_enterReadOnlyMode('readonly')` on the first
  `setPermission('edit')`), and `ImpressTileLayer.initialize` additionally sets
  `app.file.fileBasedView = true` for phones and tablets so presentations open
  as endless slide scrolling with page skeletons.
- Floe's injected fullscreen-entry wrapper refused that guarded entry whenever
  `app.file.fileBasedView` was true, while the same wrapper's sibling scripts
  read `app.file.readOnly` (the backing permission) as readiness. A PPTX
  therefore became "editable" in the App while the engine stayed in its
  viewing layout, and `docloaded` plus a sized canvas was accepted as a
  rendered document even when no tile had been decoded.

Fixes in this slice:

- `FloeOfficeNative.mm` injects the host mount grant as
  `window.__floeOfficeSession`, allows the engine's own guarded mobile entry for
  `presentation`/`drawing` file-based layouts, defers (bounded) when the document
  type is unknown, and never elevates a read-only backing permission, a
  protected file or a view-only file-based document.
- A bounded render probe polls the editor's own tile pipeline
  (`RenderManager.getTiles()` / `Tile.isReadyToDraw()`) plus a downsampled
  document-canvas fingerprint. Presentation/drawing formats must show a decoded
  document tile on a sized canvas; `docloaded`, the open event, the engine
  permission and a save receipt are explicitly not render evidence.
- `OfficeFileSession` gains `OfficeVisibleRenderGate`: presentations stay
  loading until the host's painted-surface signal, fail visibly at the bounded
  deadline (with retry/recovery and the retained editing copy) and never present
  a blank ready editor. Word/Excel keep their open-only contract. The host
  callbacks are installed through runtime selectors, so the app still builds
  against a pinned framework that predates the contract; the strict gate
  activates with the rebuilt host.
- Edit verification now requires the engine's *UI* mode (`map.isEditMode()`), not
  only the backing permission: an editable presentation whose UI did not switch
  follows the guarded entry once more before any writable claim.
- Diagnostics: content-free `[FloeOffice]` lines record format, document type,
  open/permission/JS state, first render facts and save receipt identity.

Qualification gates:

- `office_render_readiness.py` runs the shipped probe script in Node against
  synthetic engine states and compiles the shipped native decision with clang;
  page skeletons and blank canvases never qualify, a decoded tile does.
- `office_render_gate_swift.py` compiles the shipped Swift gate and asserts the
  open-vs-render distinction, the bounded failure and the retained-copy copy.
- `verify_pptx_deck_semantics.py` checks the committed `sample-deck.pptx`
  fixture from OOXML alone and validates rendered-tile receipts against it.
- `office_release_gates.py` requires every release capability to carry device
  provenance; `verify_office_app_embedding.py --require-release` and
  `pin_office_host_artifact.py` reject a framework whose capabilities are
  unproven, and `qualify_office_device_capabilities.py` is the only writer that
  may record device evidence, from verified probe receipts.

Remaining gates (not claimed here): the native framework must be rebuilt and
re-qualified in cloud CI (`office-native-host.yml`) from this source and
re-pinned; then the App build, a real PPTX edit/save/close/reopen and the
original-file write-back need the user's physical-device acceptance. The pinned
framework still predates this source, so `pin_office_host_artifact.py --check`
reports SOURCE AHEAD OF ARTIFACT and the release gate fails closed.

### Rebuild and pin update (2026-09-22)

- `office-native-host` [run 35668651442](https://github.com/JiangNanGenius/floe-agent/actions/runs/35668651442)
  (`c4ff0dde`) rebuilt the host from this source and passed the real framework
  compile/link plus the Swift import check; commit `f0ca71a7` re-pinned
  `FloeAgent/ThirdParty/Collabora/engine.lock.json` to that artifact
  (`archiveSHA256 cd423813…542ca`), so `main` at that commit no longer reports
  SOURCE AHEAD OF ARTIFACT for the host contract described above.
- The framework's `capabilityQualification` receipts remain all `false`
  (`embeddedEditorPassed`, `pptxVisibleRenderPassed`, `deviceRoundtripPassed`,
  `originalFileWritebackPassed`), so the release gate still refuses to claim a
  qualified Office capability and every device check listed above stays open.
- The first cloud App regression after the pin failed on a simulator-only
  compile error (`OfficeDocumentEditorView.swift:730/740`, host types used
  outside `canImport(FloeOfficeNative)`); `67a37db3` guards both watchdogs and
  adds focused regression coverage. The full-App simulator build re-run is the
  remaining cloud gate and had not completed at audit time.

## Build 220 device-App compile failure and Build 221 repair (2026-09-22)

The accepted-SDK Release/device App compile for build 220 stopped in the App
target (`FloeAgent`), after every SPM target compiled, with 14 diagnostics in
three files (rebuild run 35673428023, Xcode 26.6 / iPhoneOS 26.5; diagnostics
preserved under `Local/Scratch/build220-release-failure/`). No artifact was
retained, signed or uploaded.

- `FloeApp/Platform/BackgroundRunCoordinator.swift` (9): the durable-background
  slice named `LinuxGuestMetricsSampler` (FloeExecution) and
  `TaskNotificationDecision` / `NotificationAuthorizationState` (FloeModels)
  without importing those modules. Fix: add both imports; no behavior change.
- `FloeApp/Terminal/LinuxImageInstallCard.swift` (4):
  `environmentIDHint ?? await services.firstLinuxEnvironmentID()` is invalid
  because `??` evaluates an autoclosure that cannot be `async`, and
  `CancellationToken` (FloeTools) was named without an import. Fix: explicit
  if/else that awaits the fallback lookup, plus `import FloeTools`.
- `FloeApp/Workspace/OfficeDocumentEditorView.swift` (1): the render watchdog
  referenced `awaitingVisibleRender`; the gate property is
  `awaitsVisibleRender`. The typo was latent because the block compiles only
  when `FloeOfficeNative` is importable; device builds reached it once the
  rebuilt host was re-pinned at `f0ca71a7`.

A local full-App device-SDK compile (Xcode 27, Debug, unsigned, pinned host
artifact run 35668651442 whose archive matches
`engine.lock.json` `archiveSHA256 cd423813…542ca`) found one additional Swift 6
strict-concurrency error in the same changed file: the non-`Sendable`
notification dictionary crossed into a `MainActor` closure
(`userNotificationCenter(_:didReceive:)`). It now forwards only the
`Sendable` string payload rebuilt from the parsed `BackgroundWorkDeepLink`,
with identical routing keys. After this repair the local device-SDK build
compiled, linked and passed the hash-verified host embedding, and the App plus
Screen Share extension both report 1.7.0 (221). The local Vendor host at
`34722048321` predated the pin and was replaced locally by the verified
`35668651442` artifact. Release run 35678610685 then passed the accepted-SDK
build, retained recovery and symbol artifacts, signed and uploaded Build 221.
Apple build `387e2282-0814-4384-88a8-5a756d46a5ef` is VALID, unexpired and
IN_BETA_TESTING in the sole private internal Floe QA group (verify 35682374446).
Physical-device behavior remains for user acceptance. Detail:
[Build 221 release notes](RELEASE_NOTES_1.7.0_BUILD_221.md).

## PPT simulator stage diagnostics and simulator-host blocker (2026-09-26)

The Build 229 device report ("PPT cannot open/edit", preview works, edit stalls)
still had no durable App-side trace: the pinned host logs bounded
`[FloeOffice]` stages, but nothing persisted the App chain
(edit intent → working copy → native controller → engine init → document import
→ permission → first painted slide → exit interlock) under one correlation
identity. This slice adds that trace and proves why the real engine cannot
supply a simulator first frame.

- **Simulator-host blocker (build/link evidence).** The pinned framework in
  `engine.lock.json` (`qualifiedHostArtifact` run `36000058922`) is hash-verified
  (`executableSHA256 37167e93…`) and is device-only: `LC_BUILD_VERSION platform
  IOS`, one `arm64` slice, `CFBundleSupportedPlatforms = [iPhoneOS]`. Linking it
  into an `arm64-apple-ios26.0-simulator` target is refused with
  `ld: building for 'iOS-simulator', but linking in dylib (…) built for 'iOS'`.
  `scripts/check_office_simulator_blocker.py` records this receipt;
  `scripts/tests/test_office_simulator_blocker.py` pins the parsing and runs the
  real probe when the framework is provided. A simulator host would need a fresh
  engine build (`--enable-ios-simulator`), new packaging/hashes and App linkage,
  not a relink.
- **Durable stage diagnostics with correlation identity.** `OfficeStageRecorder`
  (`FloeAgent/FloeApp/Workspace/OfficeStageDiagnostics.swift`) records bounded,
  content-free stages per session UUID plus the monotonic open generation into
  the unified log (`[FloeOfficeStage]`) and
  `Library/Application Support/FloeAgent/OfficeDiagnostics/office-stage.jsonl`
  (512 events / 256 KiB bounds). `OfficeFileSession` records intent, working
  copy, engine runtime, controller mount, host render contract, open permission,
  visible render, host `renderDiagnostics`, edit entry, save, close and the
  exit-interlock decisions; `NotesOfficeView` records the Notes staging,
  commit and leave-guard stages under the same identity; `FilePreviewView`
  records the host-less fallback. The trace never carries document text, paths
  or bytes.
- **Narrow repair.** `OfficeEditEntryAck` was the only one of the three
  one-shot acknowledgements that could orphan a stale waiter's continuation
  (the close and save receipts already defend against it): a second concurrent
  `wait()` overwrote the first continuation, which could then never resume and
  would keep `operating` set forever. A stale waiter now settles as
  unverified-read-only (never an editing grant) and the live waiter continues;
  `OfficeEditEntryAckTests` covers it. `hostRenderDiagnostics(_:)` also reads
  the pinned host's own bounded render facts (docType, tile/canvas counters,
  edit-surface paint evidence) into the trace instead of leaving the selector
  unused.
- **IDE Office tab open-trigger repair.** The Build 229 device pass showed the
  IDE's embedded Office surface on its opening spinner for DOCX/XLSX as well as
  PPTX. The owner loader was a bare SwiftUI `.task` (with the commit binding
  only on `.onAppear`) inside `WorkspaceIDEView.officeSurface(_:)`: consecutive
  Office tabs keep the same structural view identity, so switching from one
  Office tab to another never re-ran the loader and the newly active tab's
  session stayed `.idle` with no controller and no watchdog. The loader is now
  keyed on `IDEOfficeLoadTrigger.identity(activeTab:)` (the tab id) with the
  commit binding re-bound inside that task, so consecutive tabs open and a
  switch back to an already-open tab keeps its live session. The focused
  `scripts/tests/test_office_ide_office_trigger.py` fails on the old binding
  (observed) and passes on the fix; `IDEOfficeLoadTriggerTests` pins the
  distinct/stable identity contract. No Office product flow changed.
- **Cloud simulator runs.** `office-simulator-stage.yml` rebuilds the real App
  for the simulator, generates real PPTX/DOCX fixtures through the product
  OOXML builders, opens them through the Notes library, Workspace preview and
  IDE Office tab, retains screenshots, xcresult, the pulled `office-stage.jsonl`
  and console log, and fails unless every path recorded the honest
  `engine.unavailable` stage with no engine success claim. Runs
  [36245810244](https://github.com/JiangNanGenius/floe-agent/actions/runs/36245810244)
  and
  [36246400751](https://github.com/JiangNanGenius/floe-agent/actions/runs/36246400751)
  proved the pinned-host blocker in cloud (`platform IOS`, `arm64`,
  simulator link refused with the exact `ld: building for 'iOS-simulator' …`
  diagnostic, pinned executable hash matched) and passed the 15 focused harness
  tests; the full-App stage execution itself stopped on gitignored CI build
  inputs (dash slices, Xcode Metal toolchain, bundled fonts). The workflow now
  bootstraps all three; the stage execution remains pending a future bounded
  run. See [the qualification record](qualification/office-simulator-stage/README.md).
- **Not claimed:** no simulator or component result here proves an iPad PPT
  first frame, edit, save, close or write-back. The pinned host's
  `capabilityQualification` flags stay false. The smallest device evidence path
  (same trace plus the host's `[FloeOffice]` stages on a physical iPad) is
  recorded in the qualification README.

## PPT edit-stall root cause and edit-surface readiness repair (2026-09-26)

The Build 227/229 device reports ("PPT preview works; entering edit stays on
正在打开文档 / never becomes usable") had two already-merged causes — the IDE
Office-tab loader that never re-armed across tabs, and the `OfficeEditEntryAck`
stale-waiter wedge that could keep `operating` set forever — plus one remaining
provable readiness defect in the pinned host's own edit-surface evidence, which
this slice repairs.

- **Root cause (source-proven).** An editable presentation is session-ready
  only when the host's render probe observes that the part-based edit surface
  painted *after* the guarded mobile edit entry. The shipped probe required a
  new tile image object or a changed 24×16 canvas fingerprint. The pinned
  engine keeps its shared tile map across
  `ImpressTileLayer._switchToPartBasedView`, and after the layout switch it can
  serve the part-based view from the *same* tile image objects with an
  unchanged downsampled fingerprint (single-slide decks are the clean case).
  The probe then reads a healthy, painted, editable editor as "never painted":
  its deadline hard-fails the session-ready threshold, the editor is left on
  the permanent render-unverified outcome with **saving refused**
  (`OfficeVisibleRenderGate.permitsSave` stays false and the finished probe
  never polls again), and every retry reproduces it. That is the device "edit
  stall" that no retry escapes. A sequence-level harness drives the *actual
  shipped probe script* through multi-poll engine lifecycles and proves the
  false negative (`FloeAgent/scripts/tests/test_office_edit_surface_evidence.py`);
  the pre-fix probe returns `editSurfacePainted: false` on the painted-editor
  lifecycle (observed).
- **Fix (host, minimal, evidence-adding only).** The probe now records the
  engine's own layout-swap receipt — `app.activeDocument.activeLayout.type`
  (`"ViewLayoutFileBased"` → `"ViewLayoutImpress"`, a stable string verified in
  the shipped pinned bundle) — in the armed baseline, and accepts a real
  file→part layout change followed by painted canvas content as edit-surface
  evidence. Strictness is unchanged where the receipt is absent: tile reuse
  without the swap, and any blank canvas, still never qualify, and the
  tile-decode/canvas-repaint paths are untouched. `FloeOfficeNative.mm`
  (`FLOE_EDIT_SURFACE_EVIDENCE`) carries the change; diagnostics expose
  `editSurfaceLayoutChanged`/`editSurfaceLayout`.
- **Fix (App, evidence integrity).** `acknowledgeEditPermission`'s
  unconfirmed-engine branch (`hostReadOnly == nil`) no longer claims a bare
  `ready` for render-required sessions: it presents the same recoverable,
  banner-backed render-unverified outcome as a bounded render miss (save stays
  refused until a real paint). Word/Excel keep their open-only readiness.
  `OfficePresentationOpeningTests` pins the composed contract.
- **Repin.** The pinned framework predates these host sources; the lock check
  fails closed with `SOURCE AHEAD OF ARTIFACT` until the cloud host rebuild
  (`.github/workflows/office-native-host.yml`) repins the artifact hashes.
  Run `36248761459` (branch `codex/ppt-edit-stall-repair`) rebuilt and
  re-qualified the host from the new sources; the repin records the new
  artifact identity in `engine.lock.json`.
- **Simulator host (immutable blocker, exact evidence).** The pinned framework
  and every qualified engine input are iphoneos-arm64 only: `LC_BUILD_VERSION
  platform IOS`, one `arm64` slice, `CFBundleSupportedPlatforms = [iPhoneOS]`,
  and a simulator link is refused (`ld: building for 'iOS-simulator', but
  linking in dylib … built for 'iOS'` — retained in
  `simulator-blocker.json`). At the pinned engine commit `27b21dc1`,
  `configure.ac` has **no** `--enable-ios-simulator` (or equivalent) option and
  the upstream `ios/README.md` states the engine "cannot run in a simulator,
  because the engine is built for an `iOS` target while the simulator is
  `iOS-simulator`". A real simulator host therefore needs a fresh LibreOffice
  core cross-build for `iphonesimulator` (all static deps rebuilt), a new host
  framework build, packaging, and a separate simulator pin — a dedicated
  engine-toolchain effort, not a relink. Until then the PPT edit path is
  qualified only on a physical device.
- **Not claimed.** No simulator or component result here proves an iPad PPT
  editable first frame, edit, save, close or write-back. The device evidence
  path (stage trace + host `[FloeOffice]` stages + `renderDiagnostics`
  `editSurfaceLayoutChanged` on a physical iPad) remains the acceptance gate.
