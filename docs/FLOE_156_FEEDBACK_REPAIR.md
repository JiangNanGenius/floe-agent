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
