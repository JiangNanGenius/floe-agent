# Build 156 feedback repair — in progress

This branch implements the September 14 feedback plan. It is not a release or a completed acceptance report.

Current candidate: **build 165**, incorporating the user's Goodnotes interaction preference, document tabs, a collapsible document header and a compact Pencil quick palette. Four navigation-state tests and the actual palette component compilation have passed locally. Full App, both SDK/device UI gates and distribution remain pending. Build 156 remains the latest verified TestFlight delivery.

Build 164 (`f150e888028aa20a0131240e0c3d259756cac304` / `v1.7.0-beta.21`, [run 34833194332](https://github.com/JiangNanGenius/floe-agent/actions/runs/34833194332)) passed SDK 27 module, App and dual-device UI tests. Its run was cancelled before upload to incorporate the new requested scope; it was not delivered to TestFlight or published as a GitHub Release. Its evidence and screenshots below remain valid only for that source.

Build 165 adds ordered document tabs with independent page/tool/zoom state, close-without-delete, persisted open tabs with the library remaining the initial screen, and Office save guards before switching. The document title/tab header can be hidden while writing tools remain accessible. Squeeze uses a compact three-row palette for tools, six colors, three stroke widths and undo/redo; detailed ink settings remain in the main toolbar. Native gesture delivery still requires the user's hardware check.

The release workflow now builds each SDK's simulator test hosts once and uses `test-without-building` for App regressions and both device UI cases. Debug test hosts retain the existing DEBUG-only UI fixtures; independent Release device builds remain mandatory under both SDKs. This removes the extra SDK 27 simulator Release build and separate UI host build requests. Both SDK jobs now start from a small immutable-source preflight and run independently. Signing/upload joins their successful results and restores the accepted-SDK app from a SHA-256-checked artifact with matching source/version/build; it does not recompile it. Actual wall-clock savings have not yet been measured.


Previous candidate: **build 163**, `7ef24846e87da67fe3f5b5db9fad545489dc7be8` / `v1.7.0-beta.20`, [release run 34823071123](https://github.com/JiangNanGenius/floe-agent/actions/runs/34823071123). This candidate includes the independently identifiable toolbar controls and full 44-point button hit regions. Its UI gate failed; archive, upload and GitHub publication were skipped.

Build 163 release source `7ef2484` passed [1,266 module executions](evidence/floe-1.7/release-163/swift-qualification.json), SDK 27 Release compilation and [157 finalized App regressions](evidence/floe-1.7/release-163/sdk27-app-qualification.json). Both devices passed the foreground editor/header checks. The UI gate then found a real iPad placement error: the palette marker was at y = -62, outside the window. A positioned transparent overlay supplied the wrong popover attachment bounds. The follow-up uses a normalized point on the actual canvas viewport and lets the system select the arrow edge. It also allows subpixel AX rounding in the 44-point hit-area checks; the iPhone failure was 43.999999999999986 versus 44. A small qualification host exercises the production presenter and button style at top, center and bottom anchors before full-App qualification.

Local palette qualification passed all three iPad anchors. The initial iPhone run reached and selected the palette but checked the underlying toolbar during its dismissal transition; the test now waits for the control to become hittable. Subsequent local attempts failed at simulator App launch or AX initialization, before validating the correction. Original results are retained privately. The focused cloud workflow now runs this production presenter on both devices under SDK 27 and the accepted SDK 26; these component results cannot replace the complete App UI gate.

The [cloud component evidence](evidence/floe-1.7/release-164/palette-component-qualification.json) confirms one passing iPad case under each SDK, with all three anchor positions, selection and dismissal. Its iPhone paths failed before menu assertions: SDK 27 timed out launching the App, and SDK 26 reached the step deadline before initialization. These results do not qualify iPhone behavior. The full Floe release workflow retains its mandatory dual-device Notes UI gate before archiving or uploading.

The fixed build-164 release source has passed [1,266 module test executions](evidence/floe-1.7/release-164/swift-qualification.json): 1,164 main, 12 JavaScript engine, 12 JavaScript tool, 61 platform and 17 Notes. Full App compilation, App/UI regression, signing and distribution are still pending.

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
