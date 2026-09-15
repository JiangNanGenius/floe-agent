# Build 172 feedback repair and delivery ledger

Updated: 2026-09-15. This is an implementation ledger, not a release acceptance claim.

## Delivery boundary

Repair and qualify the complete app, then upload a new internal TestFlight build. Prepare public Beta review materials for the owner's review; do not submit public Beta yet. GitHub prerelease, Feather, documentation, main merge and task-owned branch cleanup are separate deliverables. No build for this repair has been uploaded yet.

The owner's demonstration credential must not enter source, logs, examples, review materials or reviewer access. Generated video is limited to **10 seconds total**, including uncertain charged attempts. Screen recordings are separate. Use only the authorized small amount of image/model generation.

## Work in progress

| Area | Implemented candidate | Evidence / remaining work |
| --- | --- | --- |
| Node startup and services | Live stdin handoff; separate service workers; native service control/ownership; actual version probe in settings | 11 desktop host tests pass, including real HTTP during foreground work, stop/port closure and bounded logs; native bridge syntax check passes; full App service test added but not run |
| Python output | Stop retaining empty output fragments after the shared byte limit | Two tests of the extracted production runner pass; not iOS runtime evidence |
| Document assistant | Native document scope is injected internally from live grants; no setup bubble on creation; exact legacy first-message migration; inset adaptive iPad pane and reduced composer chrome | Scope/revocation test passes; Swift parse and native layout scan pass; full-App UI screenshots/upgrade migration checks pending |
| Python services | Own-GIL sub-interpreters, virtual cwd/environment, loopback listeners, bounded output, owner-only stop and lifecycle retention | Two desktop HTTP services pass; actual Objective-C bridge HTTP x3/owner/cleanup test passes; iOS native test added; durable jobs/Agent routing, Shell floe-service command, environment management UI and task-scoped preview now implemented; full-App integration pending |
| Bundled Python networking | Requests, HTTPX and pytest plus dependencies added as pinned pure wheels (48 total) | Lock validation and isolated CPython 3.13 HTTPS/import/pytest check pass; iOS execution and remaining native packages pending |
| Crash diagnostics | Valid compact MetricKit termination/attributed-frame summary precedes large payload | Original uploaded payloads lost metadata to client truncation; no supported Qwen crash cause yet; App Store Connect crash endpoint returned HTTP 403; added summary regression pending App execution |
| Notes ink | Paper canvas uses light appearance; transparency slider maps 0% to solid, 100% to invisible without inverting stored alpha | Pencil drawing, persistence and both device layouts pending |
| Guidance queue | Withdraw pending guidance from runtime before editing/removing its durable row | Runtime race test added; execution and UI qualification pending |
| Logging | Persisted debug/info/warning/error collection threshold, default info | Module compilation passed; settings/relaunch/filtering and full app checks pending |
| Report retention | Private server patch retains up to 500 events and evicts whole old reports | Store tests and API/docs alignment pass; deployment entry point remains to be confirmed |
| APT trust | Explicit unsigned-source choice; only missing signature files may use that choice; signature/network failures do not downgrade | Seven package integrity tests pass; detached signature, third-party source and install UI qualification pending |

## Persistent local services — Node, Python and Shell

This addition applies to all supported local runtimes, not just Node. A detached one-shot job with the existing timeout is **not** a persistent service implementation.

- One service owns an explicit environment, conversation/project, working directory, invocation and cancellation handle. Its lifetime is independent of a tool response, preview tab or settings view.
- Reuse background task persistence and management. Provide start, status, bounded live logs, stop and restart through Agent tools and the environment/task UI. Record actual endpoints after readiness checks; starting a worker is not proof that HTTP is listening.
- Separate ordinary execution deadlines from service lifetime. A service must not occupy the foreground Shell gate or prevent later Node/Python commands and package operations from completing.
- Node uses the once-initialized runtime with independently owned service workers. Python requires an explicitly managed execution model: the current single-interpreter runner temporarily changes process-wide cwd, environment, streams and imports, so simply starting a second thread is insufficient.
- Shell service launches must keep ownership of the actual runtime/server and children. Reject unsupported daemonization or native executables with actionable errors; never report an untracked process as managed.
- Default preview access is loopback only. Authorize only the owned, verified endpoint for the browser, revoke on stop/failure, and preserve the existing static-file preview. Do not open the sidebar automatically.
- Closing a preview or changing chats keeps the service available. Stopping a chat generation does not silently delete a separately started project service. Explicit stop, owner deletion and environment deletion stop owned services and wait for actual worker exit before releasing files/dependencies.
- Bound concurrent workers, retained logs and resource use. Surface busy/failed/stopping states. A cancellation request does not establish termination; blocked native cleanup must keep the environment protected.
- App suspension does not imply uninterrupted iOS execution. Recheck endpoints on foreground return; after process death mark in-process services interrupted and offer restart. Do not advertise a dead URL or silently rerun project code at launch.
- Verify Node and Python HTTP responses, foreground execution while a service is alive, independent services in two environments, port collisions, repeated start/stop/restart, cancellation during startup, environment deletion, navigation, suspension and relaunch. Capture real responses and worker/resource cleanup evidence.

## Outstanding repair and qualification gates

1. Diagnose device Shell timeouts and Node availability/version using supplied task exports and preserved server reports. Decode/symbolicate Qwen first-inference and PDF crash evidence; verify memory handling without assuming an OOM cause.
2. Complete pip/npm/pnpm through UI, Agent and Shell: actual download, staged install, import/require, HTTP(S), cancellation, rollback, uninstall, inheritance and cross-environment ownership. Implement package-manager selection using project metadata and lockfiles, with explicit conflict handling.
3. Bundle requested common Python packages with tested pins and correct native ABI/signing. Audit Python wheels, native npm addons and executable/WASI packages separately; follow the [native package completion plan](FLOE_1_7_NATIVE_PACKAGE_COMPLETION_PLAN.md). Publish only verified artifacts to the official source with standard ecosystem names and indexes.
4. Complete third-party source management and authentication. Keep TLS trust, repository signatures, checksums and ABI checks distinct. APT is a Shell package command, with legacy adapters only where needed.
5. Finish Office chrome, Notes ink/tool controls, model setting migration, model capability overrides, Whisper view-independent download, streaming layout/collapse, browser handoff, enabled search-tool discovery and content search regressions. Verify existing requested features against current code before duplicating work.
6. Cover the current development SDK and upload SDK, iPad first and iPhone compatibility, clean install and upgrade, repeated mixed execution across two projects/multiple sessions, and original chat/Office/Notes/Canvas/media workflows. Preserve suitable screenshots and actual outputs. Distinguish module/host/simulator/device evidence.
7. Archive immutable source in cloud CI, retain a recoverable IPA, upload and verify Apple processing and internal group availability. Record actual build number/source/toolchain/hash. Do not label the new TestFlight installable until verified.
8. Record a real demo from the qualified build; update bilingual README/guides, release descriptions, compatibility and migration/recovery documents, review notes/sample files/PDF and public Beta metadata. Keep private logs and credentials out of public material.
9. Publish matching GitHub prerelease and Feather artifacts, merge authorized work to main, remove only proven merged task-owned branches, and clean only regenerable work-owned build scratch. Preserve delivery artifacts, screenshots, logs, symbols, backups and unrelated work.

## Current validation runs

- First batch source `96c5ed1`: [cloud CI 34888434125](https://github.com/JiangNanGenius/floe-agent/actions/runs/34888434125). SDK 26.6 and Linux builds passed. SDK 27 passed 160 App regressions and the iPad Notes UI test; iPhone XCTest exited during runner preparation with a stalled waiter before executing the test. Screenshots and original failure are retained. The next CI run explicitly shuts down the prior cloud simulator and waits for the selected device to boot before launching XCTest. This is not a delivery/upload run.
- `swift test --package-path FloeAgent/Qualification/Notes --filter assistantContextTracksLiveGrantsWithoutCopyingDocumentInstructions`: 1 passed, macOS module evidence.
- `node --test FloeAgent/scripts/tests/node_host.test.cjs`: 11 passed, desktop host evidence including persistent HTTP and stop/port closure.
- `/opt/homebrew/bin/python3.13 -m unittest discover -s FloeAgent/scripts/tests -p test_python_service.py`: 1 passed, two isolated desktop interpreters.
- `scripts/tests/python_service_bridge.m`, compiled against host CPython 3.13 and Foundation with the production Objective-C bridge: actual HTTP x3, wrong-owner rejection and interpreter shutdown passed. The temporary executable/bootstrap/working directory were removed after success. This is not an iOS build.
- App Store Connect crash-feedback attempt `34889396665` lacked a build ID and failed before requesting data; corrected attempt `34890729017` used the Build 172 identifier and returned HTTP 403. No crash log was retrieved from Apple; preserved server evidence remains authoritative but incomplete.

- `FLOE_NETWORK_PACKAGE_TESTS=1 node --test --test-name-pattern='pinned npm and pnpm install' FloeAgent/scripts/tests/node_host.test.cjs`: 1 passed. Both pinned CLIs downloaded `is-number@7.0.0` over HTTPS, wrote their lockfiles and loaded the installed module through the persistent host. Temporary project/cache directories were removed. Full-App managed npm install/uninstall and pnpm install/import tests are added separately; they have not passed on iOS yet.
- Assistant/Python bridge follow-up source `4e3cf2b`: [cloud CI 34891524229](https://github.com/JiangNanGenius/floe-agent/actions/runs/34891524229) queued behind the first batch at dispatch. Later targeted test additions may supersede this pending run; no upload was initiated.

### Service integration follow-up

- `exec.localService` runs inside durable `jobs.submit`, retains its execution lease until native shutdown, publishes bounded redacted logs and an HTTP-verified loopback URL, and revokes that URL on shutdown. Browser authorization checks the task that owns the view, including inactive tabs. Reserved managed ports cannot be reused by another live managed job.
- `floe-service` exposes the same lifecycle from Shell: start Node/Python scripts, list, status, logs, stop and restart. Unsupported native daemonization is not advertised as managed execution.
- Settings → Execution environments → selected environment → Local services lists active/finished attempts, output, preview, stop and restart. Navigation does not cancel runners. Restart is explicit after app termination.
- Background job status/result/cancellation verify the durable task owner. Submission propagates the executor's tool ceiling. State transitions are one database transaction; progress writes cannot resurrect terminal jobs.
- Targeted service module compilation passed; eight background-job tests passed on macOS, including wrong-owner rejection and retaining running state until a cancelled executor acknowledges exit. Node host tests passed 11/11 (the opt-in registry test was skipped in this repeat; its separate earlier pass remains recorded above). Native bridge syntax and Swift parse passed. These do not replace full-App execution.
- Cloud follow-up `34892228439` failed on an unhandled throwing Notes context lookup. The call now handles unavailable context explicitly, and the new migration/MetricKit tests are inside the selected regression suite. No upload occurred.

### npm / pnpm selection and transactional installation

The environment UI now persists **Automatic / npm / pnpm**. Automatic reads only the exact owning project's `packageManager` and lockfile; ambiguity or unsupported managers is reported before installation. An explicit selection applies to this environment and does not rewrite project files or download another manager version.

Both managed installers resolve a fresh staged dependency tree, retain direct-dependency and lock metadata in the same committed generation, reject unsupported native payloads/scripts/symlinks and restore the old generation on failure. Legacy npm global entries migrate without deleting their original generation before successful commit. The package registry remains the official npm registry; verified native packages and third-party registry controls are still separate outstanding work.

Two macOS tests passed: read-only selection/conflict handling; real pinned npm and pnpm CLI install, import, manager switch, bad-version rollback and removal. This exercises production Swift staging/recovery with desktop Node, not the iOS Worker bridge. Full-App managed pnpm and saved-choice checks were added for the next immutable-source CI run.

- Combined targeted qualification now passes **10 tests** (eight background-job lifecycle/ownership tests and two package-manager tests, including real HTTPS installs). Environment module compilation also passes. The current cloud run [34919306177](https://github.com/JiangNanGenius/floe-agent/actions/runs/34919306177) is fixed to `ec7d135a`; the later manager and orientation changes require a separate immutable-source run.
- Correction after inspecting PNG eXIf metadata: prior iPad attachments have portrait storage dimensions but orientation 8, so their displayed content is landscape. Dimensions alone were insufficient evidence of an orientation failure. The next test still explicitly asserts App frame orientation. Cloud UI runs retain real simulator recordings alongside screenshots; no recording or demo is claimed complete before those runs finish.

## Office chrome repair candidate

The Notes-hosted Office editor now uses one native row for return, document tabs, assistant/mind-map access and document actions. It removes the duplicate outer title and empty collapse row; on compact widths, attachment/drawing/presentation actions move into the document menu. Standalone Office retains its navigation bar. Save/owner-commit/discard/recovery paths are unchanged. Swift parsing passes; full-App layout and save/reopen qualification are pending.

## Shell package transaction and ESM follow-up

Shell `npm install/i/add`, `pnpm install/add` and remove/uninstall now use the same actor and staged dependency generation as settings. Named batches validate before changing files; no-argument install reads dependencies/devDependencies from the actual current workspace package.json. Packages are added to the active environment; project manifests and lockfiles remain unchanged. Unsupported mutation commands/options return an explicit error. This does not claim exact project-lock reproduction or native addon support.

The host now extends ESM resolution with ordered dependency roots through Node's standard loader hooks, preserving import/require conditional exports. Eval uses a CommonJS compilation context so dynamic import works without experimental VM flags. Desktop Node **18.20.4** (matching the embedded runtime version) passed 12 host checks, including ESM/CJS selection, export rejection, task isolation, stdin and service cancellation; one optional network case was not enabled in that run. Three manager checks passed, including actual npm/pnpm HTTPS install of two dependencies, generation switching, rollback and removal. Full iOS worker/Shell integration remains pending.

Native dependency audit on 2026-09-15: the current upstream PyPI releases of lxml (6.1.3), matplotlib (3.11.2) and scipy (1.18.1) expose no cp313/abi3 iOS wheels. BeeWare's package API returned no lxml/scipy package and no cp313 arm64 iOS matplotlib wheel; contourpy and kiwisolver do have dual-target candidates. python-docx and python-pptx both still require lxml. These findings explain why adding the pure wrappers alone cannot satisfy the request; native builds remain tracked, not marked installed. Sources: https://briefcase.beeware.org/en/latest/reference/platforms/iOS/xcode/ and the PyPI/BeeWare package metadata APIs.

## Direct pip Shell entry

`pip`, `pip3` and `python3 -m pip` now route parsed installation/removal arguments to the shared managed installer. Inspection supports version, list/JSON, show, freeze and dependency check using fixed metadata-reading source; user arguments are data, not generated executable source. This closes the earlier path where only a tool's packages field worked while Shell imported pip directly and was rejected. Target/source overrides and unsupported operations fail explicitly. FloeExecution compiles; 10 Python tool/parser checks and two real metadata-inspection checks pass locally. The native environment cycle now covers this service path; full-App execution is pending. Ordinary Python scripts still cannot turn on the internal installer privilege.

## Native regression findings and follow-up

Cloud run `34919306177`, source `ec7d135a`, compiled with SDK 27 and passed the SDK 26 compatibility and Linux builds. Of 167 App regressions, two tests failed (four assertions). Native Python wheelhouse imports, managed environment install/import/removal, Node/Python owned HTTP service lifecycle, and Shell HTTPS passed. These results do not cover the later transaction and Shell-entry changes.

- Installing through pip left process-global Rich logging handlers behind. A later HTTPX request called them after installer modules and privileges had been removed. The embedded runner now restores handlers, filters, levels and disabled/propagation state between jobs. Three exact-runner desktop tests pass. The failed combined HTTPS/pytest test now retains a larger bounded diagnostic result; native inference that this fixes its entire failure remains unverified until rerun.
- The embedded Node runtime rejected pnpm's Unicode property escapes. A digest-bound adapter expands only the pinned pnpm source into explicit Unicode ranges generated with Node 18.20.4. Upstream package files, lockfiles and `--check` hashes remain unchanged. Exhaustive code-point comparisons and source-tampering checks pass on the matching desktop runtime, and real npm/pnpm HTTPS install/import passes. General Node Unicode/ICU support is not claimed; iOS pnpm must still pass.
- iPhone Notes import, editing controls, assistant, tabs and body search passed. iPad reached body search but exceeded the test deadline while resolving accessibility elements; it is a failed UI qualification, not a passed retry. Original logs, xcresults and screenshots are retained privately. The later explicit landscape assertion and Office header remain unqualified.

The superseded `ffbec996` CI run was cancelled during setup to avoid building a source already missing these known repairs. No new archive, TestFlight upload or public Beta submission has occurred.

## Per-environment language package sources

Python and Node package pages expose an editable source address and restore-official action. One validated public HTTPS source is saved per ecosystem in the selected environment; UI, managed Shell and Agent installations read the same setting. Python uses an explicit Simple index and clears inherited extra-index/trusted-host configuration. npm and pnpm pass the selected registry explicitly. Changing the registry does not remove installed files; the next staged Node generation discards the old registry's lock and records the new source on commit.

Three Swift checks pass for source persistence across two environments, rejecting URL credentials/malformed or escaping configuration, and passing the registry to both managers with recovery after failure. Fourteen Python payload/recovery checks pass, including explicit index forwarding. This does not yet provide authenticated private registries, scoped source bindings or a published Floe language mirror; those remain outstanding. Full-App UI and non-default source end-to-end qualification are pending.

Native lxml candidate build `34923069149` compiled libxml2 for iOS, then failed to locate its CMake config while cross-compiling libxslt. Follow-up `34923284307` binds that config to the explicit target slice. Original failure retained; no lxml wheel or Office Python capability is reported ready yet.

## Simulator build scope

The SDK 27 cloud log showed unused x86_64 MLX/NIO compilations alongside arm64 on the Apple Silicon runner. CI and release simulator build commands now select `ARCHS=arm64 ONLY_ACTIVE_ARCH=YES`; iPad/iPhone runs and SDK 26/27 checks remain. Device archive settings are unchanged. Both workflow files pass actionlint; elapsed-time improvement is not claimed before a new run.


## lxml and Office Python integration

Candidate run `34923284307` (source `aa35a5e0`) passed: device and simulator wheels compiled with SDK 26.5, and the iOS simulator testbed executed Chinese XML/XPath/XSLT plus DOCX/PPTX save/reopen (one test, 9.506 seconds in the test process). All 14 Mach-O modules were inspected: correct platform/arm64, minimum iOS 17, no Homebrew dependency; libxml2/libxslt are static, iconv/zlib use Apple system libraries. Original artifacts/logs remain private qualification evidence.

The dependency prerelease `runtime-lxml-6.1.3-cp313` preserves tested code bytes and corrects only WHEEL/RECORD minimum-OS metadata using wheel 0.46.3. It includes provenance and hashes. Floe build pins, generated framework references, license inventory, runtime probes, and exact python-docx 1.2.0 / python-pptx 1.0.2 pure-wheel pins are added with a full-App round-trip regression. This dependency publication is not a new App release or TestFlight upload; App/runtime integration remains pending CI.

## Resolver and latest native regression repairs

Run `34922624182` (`83cbc383`) passed the managed environment install/import/remove cycle and Node/Python HTTP-service checks. It exposed two remaining defects: pytest's terminal reporter called `isatty()` on the bounded output sink, and a direct managed Node install encountered a missing environment `tmp` directory. The sink now implements the standard non-terminal TextIOBase interface; managed npm/pnpm prepare contained HOME/temp/cache/store directories before launch. Four exact embedded-runner checks pass; native rerun is still required.

Managed pip now resolves with `--dry-run --report` before staging, allowing already installed environment/bundled native libraries to satisfy dependencies. Only missing pure wheels from HTTPS URLs with SHA-256 hashes enter the staged install; resolution failure retains the original generation. A real desktop CPython 3.13 run installed python-docx/python-pptx/XlsxWriter while reusing lxml/Pillow, saved/reopened Chinese Office files, and repeated installation as an already-satisfied operation. No native module was copied to the managed layer. This is host proof, not App proof.

That run also found pip's `../../bin/vba_extract.py` RECORD relocation. Normalization now accepts only the exact relocated script whose real file is inside the staged `bin` directory, writes portable ownership, and keeps arbitrary traversal rejected. Eighteen payload/recovery tests pass, including uninstall of the relocated script. Full-App qualification now covers a layer-specific python-docx version and restoring the original bundled version after uninstall.


Full-App follow-up [34924942672](https://github.com/JiangNanGenius/floe-agent/actions/runs/34924942672) is fixed to `f5b6d3bd`, including the source UI, Notes card changes, lxml/Office integration, pip resolver, output-stream interface and Node directory repairs. It was queued behind the prior evidence run at dispatch. A local Node Swift qualification attempt was interrupted when Command Line Tools invalidated the shared build cache and began recompiling dependencies; it is not a test pass. No local App build was started.


Release CI reuse now accepts successful manual full-CI runs as well as pushes, always for the exact source SHA and all three successful required jobs. It verifies and retains both Notes UI bundles before omitting the repeated SDK 27 simulator build/tests. SDK 26 tests, both device builds and upload checks remain required. Workflow syntax passes actionlint; actual release execution remains pending.


An independent manual cloud diagnostic now exercises production `MLXTextEngine` and the pinned Qwen3.8 snapshot through cold load, two short generations and shutdown with the constrained resource profile. It records MLX memory and host process peak RSS. This macOS diagnostic can provide a reproducible engine failure; it cannot establish the original iPad crash cause or device acceptance. No paid provider API or local multi-GB download is used.


## Completed follow-up evidence on 2026-09-15

Full-App run `34922624182` at `83cbc383` passed both Notes UI flows: iPad mini A17 Pro landscape (114.382 seconds) and iPhone 17 Pro portrait (95.865 seconds), one test each, no failures or skips. It exercised workspace import, full-screen PDF editing controls, the assistant without a bootstrap bubble, brush selection, focus mode, tabs and a real PDF-body search snippet. [Original screenshots and provenance](evidence/floe-1.7/build172-repair/notes-83cbc383/README.md) are retained. Real simulator recordings (141 seconds iPad, 180 seconds iPhone) are saved privately. The iPad review cut removes launch overhead and rotates the stored frames; it is a candidate demonstration, not final release evidence or paid model output.

This same full-App run still failed two runtime cases: pytest required `isatty()` and npm required its environment temp directory. HTTPS requests/HTTPX and native Node/Python owned-service lifecycle passed. `f5b6d3bd` contains both fixes plus native lxml/Office integration and managed pip dependency reuse; follow-up `34924942672` has passed environment/package/media/job/Notes module qualification and Linux compilation, with full App checks still running. A screenshot-driven later change limits long composer labels so the assistant's other controls remain reachable; visual requalification is pending.

Independent Qwen diagnostic `34925666700`, source `59197330`, passed pinned download, production MLX load (7.343 seconds), two short answers and shutdown. MLX peak was 2,523,781,237 bytes; host process peak footprint was 2,695,814,080 bytes. Shutdown left 4,000 active MLX bytes and zero cache bytes. The original iPad crash remains unresolved: this is a macOS host with short inputs, not iPad memory-limit evidence. The next diagnostic adds a document-style prompt of at least 4,000 tokens and total request timing. No paid provider calls were made.
