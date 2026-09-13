# Build 156 feedback repair — in progress

This branch implements the September 14 feedback plan. It is not a release or a completed acceptance report.

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

Background transfer runtime/relaunch/cancellation tests; official production source; Python/npm management and package isolation; native Shell/Node integration and stdin; configuration hydration audit; stable-prefix/context replay qualification and live cache measurements; Office/map library previews and writing-control UI checks; full App iPad/iPhone tests and screenshots; documentation reconciliation; signed TestFlight upload and availability; main merge and merged-branch cleanup.

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
