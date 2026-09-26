# Floe Agent User Guide

Current internal delivery: **1.7.0 (229)**. Immutable tag `v1.7.0-beta.86` binds source `b06b0b0e`; [release run 36239956371](https://github.com/JiangNanGenius/floe-agent/actions/runs/36239956371) retained the unsigned IPA (739,485,403 bytes; SHA-256 `5cd022eb612d89f1d94b91594b747000404cec3f247b8508e89a83e88436124d`), uploaded the signed build and published the [GitHub prerelease](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.7.0-beta.86). [Verify run 36242653374](https://github.com/JiangNanGenius/floe-agent/actions/runs/36242653374) confirmed Apple `VALID`, unexpired and `IN_BETA_TESTING` in the sole private internal Floe QA group; both beta-note languages were read back. The matching unsigned GitHub developer IPA and Feather feed entry are published. Gitee mirroring is tracked separately. [Build 229 notes](RELEASE_NOTES_1.7.0_BUILD_229.md) · [Delivery record](TESTFLIGHT_1.7.0_BETA.md).

**What changed in Build 229.** Office close/save acknowledgements now settle once, a late real PPT paint can recover a waiting session, and a failed original-file write-back keeps its working copy. An unhealthy MLX container is evicted before the next local-model turn. The IDE Run sheet retains automatic, one-core and two-core requests; two-core execution remains disabled by the shipping safety gate. Component checks are not iPad acceptance.

**Physical-device retest required.** Earlier iPad testing reported ordinary MLX chat/benchmark crashes, PPT edit-entry stalls and indefinite IDE Office loading. Build 229 contains targeted repairs, but local-model load, benchmark and multi-turn/tool continuation; editable PPT first frame/save/reopen; Office exit behavior; IDE DOCX/XLSX/PPTX tabs; PiP, notifications and keyboard/touch behavior must still be verified on the device.

The Build 191/192 descriptions and screenshots below are historical snapshots. Their candidate and waiver wording records those releases and does not describe current availability.

[简体中文](USER_GUIDE.zh-CN.md) · [Website](https://www.floe-agent.com/) · [README](../README.md) · [Security](../SECURITY.md)

This guide covers existing Floe workflows and the 1.7 internal beta. Labels vary with the installed build. Consult [1.7 status](FLOE_1_7_IMPLEMENTATION_STATUS.md) and [upgrade/recovery](FLOE_1_7_MIGRATION.md); a source commit or successful build does not establish TestFlight availability.

This guide includes the build 172 workflow upgrade. See [scope, screenshots and outstanding validation](WORKFLOW_UPGRADE.md); release availability is verified separately.

## Build 192 repair record (historical)

The following paragraph preserves the Build 192 candidate boundary as it stood at the time: the behavior had only host/fixture validation, while Build 191 was then the current internal TestFlight delivery. Current availability is recorded at the top of this guide.

- **Office editability is the engine's truth.** An unknown or missing read-only flag never becomes editable; a protected or read-only document returns to preview with a reason, and an edit-password document prompts for the password. The native host behind this compiled in cloud run `35373122891`; save/close/reopen on a device is still pending. An imported workbook with its own formulas, sheets or embeddings is never silently rewritten — strict save validation may reject the save and keep your original file.
- **The IDE routes by file type.** Every entry point sends text/code to the code workbench, Office to the Office editor, PDF, drawings, images and media to their viewers, and archives or unknown binaries to Quick Look. The code workbench refuses Office and binary bytes for both read and write. Inside the IDE, text/code, PDF and Office share the workbench's internal editor tabs and file tree: the native PDF/Office surface is overlaid on the internal tab, and one Office document keeps a single working copy between its preview and editing; closing that tab with unsaved changes asks first. Drawings, images, media and Quick Look documents keep their typed native tabs.
- **File preview shares the visible document.** Cloud or network files are snapshotted locally before sharing, so the preview copy is untouched; lower-frequency actions moved into the **More** menu.
- **Source control adds real Git recovery.** Fast-forward now updates HEAD and the working tree, conflicts list correctly, staged rows can be discarded with index and working-tree recovery in `.git/floe-recovery`, and merge conflicts can be edited or aborted. Reset/clean, force-push and history rewriting remain intentionally unavailable.
- **Terminal and package commands are more honest.** An interactive session can no longer race a close or expiry; the last output of a fast command is kept; the IDE bottom panel hosts the local terminal without ending the shell when the panel closes. A busy engine reports exit 75 (not started) instead of a timeout, and a cancelled package command returns 130 without executing. Explicit `npm install`/`pnpm install` always uses the manager you named; project locks and preferences only guide automatic selection.
- **Model fallback repairs a broken default.** Disabling, deleting or hiding the stored model selects another usable model in a fixed order (current selection, stored default, most recent run, first usable); a running request keeps its own model.
- **Video generation works from ordinary chat.** `video.models`, `video.generate`, `video.status` and `video.cancel` list only enabled, adapter-backed models and accept one reference image (workspace path or conversation attachment; PNG/JPEG/WebP up to 8 MiB, sent inline). A replayed call reuses the existing job, cancellation wins over an in-flight submit, canceled downloads are not announced as ready, and expired results are labelled. GIF inspection and conversion use real frames and timing.
- **Languages:** local Python, Node and shell run inside the environment's TinyEMU Linux guest, and the App contains no native Python, Node or Ruby payload. Install Lua 5.4.8, Ruby 3.4.1, PHP 8.2.33 or `floe-text` as signed WASI commands from the verified capability catalog (`wasm.packages`); they are sandboxed WebAssembly interpreters, not Debian packages, and they register the `floe-lua`, `floe-ruby`, `floe-php` aliases. Installability comes from that verified signed catalog, and device runtime acceptance is the tester's. PHP 8.2 remains in security maintenance through 2026-12-31 and the pin is the patched 8.2.33 release. Compiler-backed languages run through the cloud-compile route and their staged artifacts are not signed. See [section 12](#12-local-python-packages-and-code-editing).
- **Local models:** MLX scoped error handling and GPU-drain changes are in place, but the build 191 iPad crash is not proven fixed. Export the current diagnostic log if it recurs.
- **Release pipeline (internal):** preflight is portable (no `plutil`), the unsigned device artifact is retained before dSYM capture, reuse requires symbols evidence, and a duplicate accepted upload or a non-`-unsigned.ipa` Feather asset is rejected.

## Live Soul and profile updates

In Settings → Memory and personalization, save, generate or activate a Soul/profile revision. The active revision applies automatically to the next new model request, including a running Agent after its current tool step. You do not need to save again or restart the conversation. An already streaming answer and retries of the same network request keep their original context. Workspace-specific documents take precedence over global ones; automatic drafts marked as awaiting confirmation remain inactive until accepted. Notes and Canvas assistants use the same active preference lookup while keeping their own conversations and document scope. This behavior is included in the internal build191; physical-device verification remains separate.

## Content search and workspace imports (build 172)

Build 172 adds eight native brushes with independent color, width and opacity, plus document tabs and a collapsible header that keeps writing tools visible. Tap the current pen or color dot to adjust its settings.

<img src="evidence/floe-1.7/release-172/screenshots/ipad-notes-native-brushes.png" width="640" alt="Build 172 iPad brush styles, width and opacity">

<img src="evidence/floe-1.7/release-172/screenshots/ipad-notes-document-tabs.png" width="640" alt="Build 172 document tabs above the writing tools">

These unedited SDK 27 full-App simulator captures accompany passing iPad and iPhone Notes UI cases. [Capture provenance](evidence/floe-1.7/release-172/screenshots/manifest.json). Physical Pencil gestures remain for device testing.

These instructions include features delivered in internal build191; screenshots and prior test results refer only to their labelled sources. Follow the [repair qualification record](FLOE_156_FEEDBACK_REPAIR.md) for full-App and device status.

<img src="validation/floe-156-feedback/screenshots/full-app-build164-sdk27/ipad/notes-workspace-import.png" width="640" alt="Selecting a PDF from a chat workspace in Notes">

Development iPad capture: choose a chat or project, then select its file. This PDF passed the full-App import, fullscreen-open and body-search case. The image does not establish a new TestFlight release; see [capture provenance](validation/floe-156-feedback/screenshots/README.md).

Notes searches names and document content across the library, shows excerpts and opens matching pages. Version-bound Office/OCR caches can be rebuilt from the document menu; incomplete indexing is visible. Use **Notes → + → Import from Floe workspace** to copy files from conversation or project workspaces into independent Notes storage. UTF-8 text and Markdown become editable paginated notes.

Creative mode searches canvas names and node text, with folders, moves, renaming and folder dissolution that preserves canvases. Its assistant has consistent sizing, drag bounds and a reorganized text/model/voice composer. Conversation lists and batch management search titles and message content, including Chinese substrings.

Main entries remain New task, Task center, Notes, Creative mode and Plugins, followed by project/conversation lists. Settings stays at the lower left. Appearance and speech are inside General; language packages are under Execution environments → selected project/session → Python·PyPI or Node.js·npm.

## 1.7 开发功能与使用边界 / Development features

The 1.7 release adds a media-workbench action to local MP4/MOV/M4V workspace previews. It carries the source automatically and offers trim, speed/volume, export settings, saved edit parameters and output playback. Full App/device interaction checks, shared queues and chat attachment handoff remain open. Menu availability depends on the installed build; see [status](FLOE_1_7_IMPLEMENTATION_STATUS.md).

- Dependencies resolve through session, project, shared and base layers. Writes belong to an explicit environment; preserve recovery copies until legacy migration is qualified.
- Guest Node and the npm/pnpm/yarn entry points have focused host tests. This does not establish compatibility with every public package. Linux native executables run only inside the Linux guest, not directly on iOS.
- Supported media conversions apply their parameters and verify real output files. Enhancements require both an available runner and verified resources.
- Package/model inventories contain candidates and exclusions. Counts are not completed capability counts; consult the [compatibility guide](FLOE_1_7_COMPATIBILITY.md) and [qualification matrix](FLOE_1_7_QUALIFICATION_MATRIX.md).

### Media workbench: source and trim range

<img src="evidence/floe-1.7/native-media-workbench.png" width="360" alt="Media workbench: source and trim range">

Open a local MP4/MOV/M4V in workspace file preview, then choose the media workbench. The screenshot shows the source player and a restored 1–5 second trim range. Scroll down for edit and export settings. This is an iOS Simulator development preview, not release acceptance.

### Video generation from chat (1.7)

Ordinary conversations now expose `video.models`, `video.generate`, `video.status` and `video.cancel` for the configured cloud video suppliers (Google Veo/Omni, Volcengine Ark Seedance, Alibaba DashScope Wan). Only enabled, adapter-backed models are listed, together with their real parameter contract and reference-image support. One reference image may be supplied as a workspace path or a conversation attachment (PNG/JPEG/WebP, up to 8 MiB); it is read locally and sent inline, and a model without reference support rejects the argument instead of ignoring it. Jobs are durable and owned by the conversation: polling resumes after a relaunch and the finished video is downloaded into the conversation workspace with a notification. A replayed tool call attaches to the existing job, a new request creates a new job, a cancel wins over an in-flight submit, a canceled download is never announced as ready, and an expired result URL is reported as expired. GIF sources can be inspected (frame count, loop count, timing) and converted to a constant-rate video without a cloud call. Real provider acceptance with your own keys is still pending.

## 1. Install safely

Use TestFlight when a testing invitation is available. If you use the community unsigned IPA, verify its SHA-256 and provenance, inspect the source, and sign it with your own certificate. Never import a certificate, API key, SSH key, or provisioning profile supplied by an unknown distributor.

Floe Agent requires iOS or iPadOS 26 or newer. iPad is recommended for file review, browser takeover, terminal work, and multi-column inspection.

## 2. Configure a model provider

1. Open **Settings** from the bottom of the sidebar.
2. Open **Model Providers** and add a compatible endpoint.
3. Enter the endpoint, wire protocol, model identifier, and API credential required by that provider.
4. Test the configuration before making it the default Agent model.
5. Return to **New Task**. The model chip in the composer should show the selected model instead of *Not configured*.

Credentials should be stored in Keychain. Diagnostics and exported reports redact credential values; do not paste an unredacted provider response into a public issue.

Each provider and each model has its own routing switch. Turning one off keeps its endpoint, credential and model metadata editable in Settings while removing it from the New Task model picker. The picker groups Apple/downloaded local models separately and groups cloud models by provider, so duplicate model names remain distinguishable.

An enabled model also has a separate **Hide from primary model picker** switch, off by default. Use it for a model that should stay available as an auxiliary/internal model without cluttering the Home/New Task LLM menu. Existing tasks that explicitly reference the model remain resolvable.

If the stored default or the Home draft points at a model that was disabled, deleted or hidden, the build 192 repair selects another usable model in a fixed order (current selection, stored default, most recent run, first usable). A running request keeps its own model, and **Not configured** is reported only when no usable model remains.

## 3. Configure auxiliary image models

Open **Settings → Auxiliary Models**. The roles are independent:

- **Vision model** reads user images and browser screenshots. Select only a model whose provider genuinely supports image input.
- **Image generation model** creates a new image from a prompt.
- **Image editing model** edits an attached or selected image.

A provider appearing in the Agent picker does not imply it supports vision or image operations. Floe disables incompatible role combinations instead of sending an invalid request.

For a dedicated image provider, choose **OpenAI** or **Google Gemini**, enter its API key, and review the editable Base URL before saving. OpenAI defaults to `gpt-image-2`. Google defaults to Nano Banana Pro (`gemini-3-pro-image`) through the native Gemini `generateContent` API. Keep generation, editing and vision capabilities enabled only when the selected endpoint implements them. A proxy URL may include its own path prefix; Floe preserves that prefix when constructing requests.

### Apple Intelligence and downloaded local models

Open **Settings → Local Models**. The Apple Foundation Model row is system-managed and therefore has no Floe download button, API-key field or model selector. On iOS/iPadOS 27 it reports one of the system's real states: available, unsupported device, Apple Intelligence disabled, model not ready/downloading, or another system availability failure. Resolve that reason in iOS settings and leave Floe open long enough to refresh; do not repeatedly retry while the system model is downloading.

Qwen entries are user-downloaded MLX snapshots. Download, load and benchmark are separate actions. Floe keeps one downloaded model resident at a time, validates the installed snapshot against its pinned manifest before mapping weights, and checks the live device allowance minus the memory a running TinyEMU Linux guest is already admitted to use. Closing background apps may increase available memory, but iPadOS can still terminate an app under pressure. A corrupt snapshot and insufficient memory are reported as different failures; if loading is refused, free memory or select a smaller model, and if the process terminates, export the new Xcode/device or uploaded diagnostic log rather than assuming a prior crash has the same cause. Gemma 4 E4B (5.15 GB) is no longer offered as a recommended download because it cannot be admitted on a typical device allowance once Floe and a Linux guest are accounted for; an existing download remains listed so it can be deleted explicitly.

An installed model can be disabled without deleting its weights. Re-enabling it makes it available to the task picker again; disabling a resident MLX model also unloads it.

Local models receive a smaller, intent-ranked catalog of real Floe tools and a local-only dynamic context/compression budget. Cloud-provider context limits, compression and tool schemas are not reduced to accommodate a local model. On-device inference is text-only and never maps a vision projector. Floe transcribes attached images with Apple Vision OCR, saves the bounded handoff under the task workspace's **OCR** folder, and supplies that text to the conversation. PDF text inspection, page rendering and OCR remain available; semantic `image.inspect` and visual browser tools are not exposed to local models. If OCR finds no readable text, Floe states the limit instead of guessing what the image contains. If a local model cannot produce a valid tool call, Floe reports the parsing or capability reason instead of claiming the tool ran.

Greetings, ordinary conversation, questions and brainstorming do not require an explicit task command. Apple Foundation Model should answer them naturally and asks for clarification only when missing information materially changes a consequential action. Downloaded MLX models prefill prompts in device-budgeted chunks and release transient Metal/KV caches after each generation while retaining model weights only for tool continuation within the active task.

Build 179 adjusted local-model memory release; the iPad ordinary-chat crash reported on build 178 is retained as a historical record. Build 219 adds the snapshot-integrity check and guest-memory accounting described above, but physical-device confirmation of local-model loading remains with the tester; if it recurs, export the diagnostic log for that session. On the delivered Build 227, iPad testing reported that a downloaded MLX model crashes in ordinary chat and in the benchmark, independent of tools; that is an open regression, not a pass.

**Build 227 — model and Linux memory are shared honestly.** A local model and a TinyEMU guest compete for the same device memory, so Floe coordinates them instead of running both blindly. Asking for a Linux environment while a local model is resident unloads a model that has no work in flight (the next model turn reloads it), and the prompt can continue normally; if a generation is genuinely in flight, Floe does not silently cancel it — the Linux start waits and then fails with a message naming what still holds the model. When a local-model task's own Linux tool leaves a guest running, the next model turn may release exactly that run's own disposable guest (never another run's guest, a user-started one, a service, or one with forwarded ports) and continue automatically; anything else still asks first, and a refusal or quarantined guest falls back to that confirmation. Asking for a local model while Linux environments are running asks first and lists the affected commands, terminals and services; choosing Cancel leaves the guest untouched. Switching between downloaded models asks for confirmation and releases the previous model when the next one loads, so two local models are never resident. All of this is component-tested, including the release/continuation loop and its refusal paths; device behavior under real memory pressure remains with the tester.

## 4. Start a task

Normal app launch opens **New Task**. Before sending, use the chips around the composer to choose:

- an Agent model;
- no project or a project workspace;
- local or an authorized remote execution target;
- enabled Skills;
- the initial task permission profile.

Attach files or images, write the request, and send. The draft becomes a persistent task in place; it does not jump into a second chat system.

**Build 227 — the prompt editor.** The composer is multi-line: it grows with the text up to 8 visible lines on iPad-class widths (6 on iPhone-class) and then scrolls internally. **Expand** opens a full-height editor that always edits the same draft as the inline field, so nothing has to be copied back and forth; undo/redo, selection and the caret survive the switch. Plain Return always inserts a newline and Cmd-Return sends (only while a send is allowed and no input-method composition is in flight). Unsent text is kept per conversation (and for the Home launchpad draft) in a durable store: switching tasks, backgrounding or quitting the app does not lose a prompt, and a failed send restores the complete draft instead of a trimmed prompt. The checks are simulator component and UI harness runs; real-device IME and long-prompt behavior remain for the tester.

### Workspace ownership

- **No project selected:** Floe creates an internal private workspace owned by this task and lists the task under **Chats**.
- **Project selected:** the task belongs to that project and appears under its folder in the sidebar.
- A task has exactly one workspace owner. Moving it later is an explicit action because the available file scope changes.
- Deleting a project task never deletes the external project files. Deleting a private task may remove its app-managed workspace and browser data.

### Lightweight source control

Open the workspace Files inspector and select **Source Control**. A non-repository workspace can be initialized in place. For a repository you can inspect status, per-file diffs and recent commits; stage or unstage individual files; commit; create or switch branches; fetch; fast-forward pull or merge; push; and resolve merge conflicts in a bounded editor. Discarding a file first writes a recovery copy to `.git/floe-recovery`, including the staged bytes when the row is staged. The build 192 repair made fast-forward actually update HEAD and the working tree, fixed conflict-path listing, and discarded staged rows from both the index and the working tree; the 219 build additionally refreshes an open pane immediately after repository initialization or any Git mutation and re-reads on foreground return, so a repository created by an agent tool appears without a manual refresh. Floe intentionally omits destructive reset/clean, force-push and history rewriting.

The same Files inspector browses ZIP, TAR and 7z archives: entries are listed with size and bounded preview, and extraction is staged into a temporary hidden workspace directory that is removed when the browser closes. **Build 227** adds on-device compressed tar (`.tar.gz`, `.tar.xz`) and single-file gzip/xz, plus archive creation: the Agent can create ZIP, TAR, tar.gz, tar.xz, tar.bz2 and single-file gzip/bzip2/xz archives, and list or extract ZIP, TAR, tar.gz, tar.xz and 7z, all within bounded entry, size and cancellation limits and without starting a Linux guest. bzip2 *decoding* and browsing RAR are refused with their concrete reason (bzip2 creation still works; RAR needs the app's signed decoder, so ask the Agent to extract it). A format this app cannot read says so instead of silently starting a guest or failing with a generic error.

Open **Settings → GitHub & Source Control** to sign in through GitHub's official device authorization page. Floe shows a one-time code and polls only at GitHub's returned interval. Fine-grained token entry remains available as a fallback. The resulting credential is validated against GitHub, stored only in the device Keychain, and never added to a remote URL, repository file, log or model prompt. After connection you can list accessible repositories, clone one into a subfolder of the current workspace, or create a public/private repository. Grant only the repository access needed for the intended operations.

### Remote devices and multiple connections

Open **Settings → Hosts & Remote Sessions** to save a remote device. One device can contain SSH, direct VNC, VNC through an SSH tunnel, Telnet, raw TCP and BLE GATT serial connections at the same time. Device type is optional descriptive metadata; configured protocols and live connection probing are the capability authority.

Only an SSH device with **Use as remote execution environment** enabled receives automatic Floe guardian checks, installation and updates before guardian-backed work. With the switch off, it remains a management or debugging target and Floe does not force-install the guardian. The model may read and edit non-secret device and connection metadata; passwords and keys still enter through the secure UI and remain in Keychain.

For a paired SSH host, the Agent can run bounded read-only `network.ping`, `network.traceroute`, `network.dnsLookup`, and `network.tcpProbe` tools. The selected host performs the real probe and returns an exit code plus bounded output, separating host, DNS, route, and service-port failures. Targets, counts, hops, ports, timeouts, and output sizes are structurally constrained.

When the user explicitly supplies an address, port or BLE GATT identifiers in the conversation, the model can open a task-only temporary Telnet, TCP or BLE serial session without saving a device. Temporary connections are not synced and automatically close after 30 minutes. Telnet and raw TCP are unencrypted and should be used only on a trusted network or inside an existing secure tunnel. iOS does not expose arbitrary classic Bluetooth SPP to normal apps, so Floe supports BLE GATT serial characteristics; MFi accessories still depend on their published vendor protocol.

Stateful tools discover identifiers before acting: saved hosts and connections come from the host list, a running SSH command returns the `taskID` consumed by status checks, remote hosting list returns the `shareID` consumed by stop, and `cloudWorkspace.catalog` returns the `workspaceID` used by remote file and Git tools. The Harness writes trusted provenance and bounded `resourceBindings` for these IDs and cursors before output can be truncated; tool or model text cannot forge those fields. If an identifier is missing, the Agent calls the named read-only discovery step once rather than guessing an ID or repeating a side effect. Malformed structured calls get one correction attempt and do not create a fake call/result pair.

## 5. Continue the same conversation

Every later message creates a new Run inside the same task. Floe reconstructs context from prior messages, attachments, tool results, decisions, the active plan and goal, scoped memory, workspace instructions, and task permissions. Older history can be compressed into sourced summaries; evidence is referenced rather than silently re-executed.

If a task reports that it was interrupted, use **Resume** or send a continuation message. Side effects whose outcome is uncertain require confirmation before retrying.

Opening an existing conversation positions it at the latest content. Live output follows while you are at the bottom; reading older history keeps your position. Long-press a task in the sidebar, workbench, or conversation list and choose **Select Multiple** to filter, select all, archive, or delete. Archived tasks can be restored in batches. Archiving running tasks explains the stop action; individual failures remain visible.

## 6. Choose a working mode

- **Agent mode** can use the tools allowed by the task policy and normal approval gates.
- **Plan mode** is read-only: it may inspect and analyze, but cannot write files, run side-effecting commands, or submit browser actions until the plan is accepted.
- **Goal mode** tracks steps, budget, evidence, child runs, and completion criteria. Completion should be proposed only when the evidence gate is satisfied.

Memory is scoped globally, to a workspace, or to one task. A memory candidate must be reviewed before it becomes active, and memory never grants permissions.

## 7. Review progress and evidence

The task timeline shows assistant output, reasoning previews, tool requests, tool results, file activity, errors, questions, approvals, and checkpoints. The inspector is collapsed by default; open it when you need:

- **Changes** for per-file diffs and line statistics;
- **Files** for the current workspace tree, including ZIP, TAR and 7z archives that open in a bounded browser with entry preview and staged extraction. **Build 227** adds on-device tar.gz/tar.xz and single-file gzip/xz handling and archive creation; bzip2 decoding and RAR browsing report the concrete reason instead of starting a guest;
- **Browser** for the task's visible web session;
- **Terminal/Host** for an authorized execution target;
- **Progress** for phases, checkpoints, and budget;
- **Child Agents** for independent child-run status and cancellation.

Switching tasks clears task-specific inspector references so one task cannot accidentally display another task's browser or files.

## 8. Web tasks and the browser

**Browser focus behavior (since build 156):** ordinary browser calls and local previews preserve your sidebar choices. Floe opens the browser panel automatically only when the Agent explicitly requests your help and provides a reason; it pauses browser automation until you return control.

Many web tasks need no browser: `web.fetch` reads page content, while `network.http` handles raw HTML, API requests, JSON and forms, including PATCH/OPTIONS and pagination/retry response metadata. The Agent can inspect actual links, forms and API documentation, then issue requests and check the result. For multi-request sessions, parsing or batch operations, it can use shell, Python or Node in the current workspace. HTTP-tool calls do not share website cookies; stateful scripts should keep their session/cookie files in their own workspace. Browser cookies are not automatically exported to scripts. JavaScript-dependent pages, browser login and human challenges use the browser path. Access permissions apply to both paths.


The browser is a real, user-visible `WKWebView`. The Agent can navigate, observe a bounded semantic DOM, wait for page changes, take screenshots, click stable element references, type, scroll, and manage tabs within the task policy.

Choose **Take Over** when a page requires login, QR scanning, CAPTCHA, 2FA, password entry, payment, camera/microphone access, a trusted file chooser, canvas interaction, or content Floe cannot safely address. Finish the interaction directly in the browser, then choose **Return to Agent**. Floe observes the page again before the Agent continues.

An element reference is bound to a document ID. After navigation or a major DOM change, a stale reference fails and the Agent must observe again; it must not guess and continue clicking.

**Search configuration:** Floe offers only enabled, complete search services to the Agent. A key alone may not be enough: Google also needs its engine ID; SearXNG needs its endpoint; Tencent needs both credential fields. Configuration changes take effect in subsequent tool discovery without saving unrelated settings again.

**HTTPS:** curl and the Python/Node inside a task's Linux guest use current certificate roots (the guest image's CA store, refreshed by the component update). Normal HTTPS keeps server certificate validation enabled. A TLS error is reported as an error; it is not presented as a successful page fetch.

## 9. Understand permissions

Effective authority is the intersection of the global ceiling, workspace defaults, task overrides, available device/host capabilities, and any time-bounded grant. The provider receives only allowed tool schemas, and the executor checks authority again.

Change the current task's permission only from the permission control below the chat composer. A selection saves automatically; there is no second Save action. It can also be changed while a task is running: the new mode immediately re-evaluates a waiting tool and applies to subsequent calls. The upper-right menu and inspector no longer duplicate this control. **Settings → Agent & Permissions** manages defaults for new tasks and existing temporary grants.

Routine bounded reads, workspace inspection, image generation/inspection, OCR, read-only PDF operations and local-network discovery bypass approval-model latency. Once the user explicitly requests installation, deployment, environment repair, a Floe guardian update, or preparation on a selected SSH host, ordinary system packages, package-source changes, dependency repair, and Floe's verified atomic guardian update inherit that task authority instead of interrupting for every command. Deleting data, entering credentials, uploading files, browser login/payment, ambiguous broad remote mutation and catastrophic commands still require explicit review. Git force-push, destructive reset/clean and history rewriting are not exposed.

Approval is based on the user's stated goal and the concrete tool target, not on a brittle keyword match. A broad request such as “test all tools” permits safe diagnostics and bounded non-destructive checks, but does not authorize deletion, credential access, arbitrary remote commands, model-policy changes or persisted personal-data writes. Approval results and reasons appear inside the corresponding expanded tool call rather than as a detached chat message.

## 10. Background work and notifications

Leaving a task screen does not cancel its Run. Floe records checkpoints at model phases, tool boundaries, approvals, user-input waits, child runs, and partial responses. When the app returns, it reconnects to a provider job when supported or creates a recovery Run in the same task.

iOS scheduling and background execution are best effort. A notification or Live Activity opens its target task; ordinary cold launch still opens New Task. Do not assume an SSH, VNC, browser, or model stream stayed connected while iOS suspended the app. If you manually close Picture in Picture, Floe persists that decision for the whole active task batch, including concurrent or cold-restored runs, while background execution may continue. Foreground retraction, mode changes, task completion, and a system interruption are tracked separately. A genuinely new batch may offer Picture in Picture again; stale preparation callbacks cannot recreate a player for an older batch.

**Default background path.** A task you start in the foreground runs under the system continued-processing task (the system Live Activity) plus a bounded completion window and durable checkpoints. Floe never keeps itself alive with an inaudible audio session, and automatic or scheduled work never turns itself into a system Live Activity - only your own explicit action does. **Settings → Background execution** offers three surfaces: standard (continued processing only), status Picture-in-Picture, and screen sharing with the operation guide. Status Picture-in-Picture is an opt-in surface behind a release gate: when a build disables it, the option is hidden and a Picture-in-Picture choice is honored as standard background processing instead of creating a player.

**What you see at the end.** A successful run stays visible for about three seconds ("Completed - time taken") and then its status surface closes on its own. A failure or a checkpoint is *not* dismissed: the status surface stays with the real reason and a recovery hint, and the durable record keeps the same identity so tapping it reopens that exact task. Teardown is generation-checked, so a delayed close from an older run can never dismiss the surface of a newer one.

**Notifications.** Each conversation has its own policy (off / terminal only / critical only / including stages). While Floe is in the foreground you get one in-app banner instead of a duplicated system alert; tapping it opens the same destination a notification would. In the background an alert requires real authorization - a denied or never-asked state cannot notify, and Floe shows that state instead of pretending it delivered. A completion or failure notification opens that task; a Linux session/service notification opens the execution-environment surface for that environment. **Next build** adds supervised service-exit notifications and a per-launch VM identity (runtime ID and launch generation) to Linux alerts; a stale-generation, notification-stream and pending start/stop repair for that surface is still in progress, so this remains component-tested rather than device-accepted.

**Keeping a Linux environment in the background.** **Settings → Execution Environments** has an explicit "keep running in the background" switch per Linux environment. Turning it on asks the system for continued processing time and starts a bounded resource sample; turning it off (or stopping the environment) ends both. iOS may still reclaim the app, and a TinyEMU guest never outlives the process: after a relaunch the environment is reported as stopped with its disk preserved, and nothing claims it kept running. The sample shows only measured values - emulator-thread CPU, guest CPU, guest memory and network counters - with "—" for anything not measured and GPU always unavailable, because TinyEMU has no GPU passthrough (heavy graphics use native Apple frameworks). **Next build** adds the VM's short runtime identity and the guest-reported core count, command/terminal/service/port counts and a rotation carousel over concurrent runs and held environments; the same repair pass still owes dropped-event and stale-identity fixes, and physical-device PiP presentation remains for the tester.

## 11. Apple capabilities, Shortcuts and automation

Open **Settings → Apple Capabilities** to decide which compiled integrations Floe may advertise to the Agent. Calendar, Reminders, Home, Maps, Web, Watch status, vision, mail composition, documents/PDF, camera, location, Shortcuts and automatic tasks are independently switchable. These device-local switches do not grant OS permission; iOS still asks on first real use, and denial must not block the rest of a task.

Floe publishes **Run Floe Task** and **Schedule Floe Task** App Intents. Add **Run Floe Task** to a Shortcuts personal automation for a system time, Focus, arrival or other exact Shortcuts trigger. Floe's own schedule is durable but uses best-effort iOS background refresh, so its wake time is not guaranteed. The immediate intent starts a normal durable task with the default Agent model without opening Floe.

## 12. Local Python, packages and code editing

Since the Phase 2 TinyEMU migration, local Python and Node.js run inside each task environment's TinyEMU Linux guest (a real Debian userland on riscv64), not in a bundled iOS interpreter, and the App carries no native Python, Node or Ruby payload. New and previously unconfigured environments use the Linux backend by default; an environment explicitly set to **Native** keeps only the POSIX shell compatibility subset (no Python/Node). When the Linux component is not installed yet, every Linux-required entry point (shell, Python, Node/npm, apt, background services, language packages) runs the same pinned, SHA-512-verified preparation itself and then resumes the original command — you do not need to ask the model to prepare Linux first. Component downloads always try GitHub Releases first and only fall back to the Gitee mirror after a bounded availability failure; the mirror's pieces are re-verified against the same whole-archive SHA-512 before import. The App IPA itself is GitHub-only: Gitee's repository attachment quota cannot hold it, so no Gitee build is offered for direct installation or as a Feather/AltStore source. **Settings → Execution Environments** shows the shared component state with download, update, start and stop controls plus the guest's reported network state, and the Terminal exposes the same entry; progress, cancel and retry are part of the shared job. Settings and Terminal derive one authoritative component state from the verified image, the per-environment disk and the live guest: an installed or running guest never shows the "Download and Start" card, and starting preparation from more than one place (or letting first Linux use trigger it) shares a single download rather than fetching the archive twice.

**Build 227 — capability routing is native-first.** Image, video, audio, PDF and OCR requests go to the app's purpose-built tools first — on-device Apple frameworks (Vision, CoreImage, AVFoundation/VideoToolbox, CoreML, PDFKit) or the configured model route for generation — and are not sent to the Linux guest just because it is installed. The guest is used for media only when the requested operation is not covered by an offered native tool, or when you explicitly ask for a script or command-line tool. Tool selection is per task and follows what is actually enabled and configured: if a native operation is not configured, Floe says so instead of quietly emulating it with a script, and on-device models receive a curated per-task set rather than the full global catalog. The routing contract and its remaining device-verification boundaries are recorded in [next-release status](FLOE_1_7_NEXT_RELEASE_STATUS.md).

Each Linux environment keeps its own persistent disk, cloned sparsely from the verified base image and grown in place (never replaced) toward a 16 GiB logical target, with any recorded capacity kept grow-only up to 32 GiB; installed packages and workspace changes survive that growth and guest restarts. The guest's temporary files and package caches live in the persistent environment layer (`/floe/env/tmp`, pip/XDG/npm caches under `/floe/env/cache`) rather than on the compact RAM-backed root partition, so a source build without a prebuilt package (for example a Pillow source distribution) uses the device's free storage for its build tree and does not fill the guest root. If extending the guest filesystem after a disk growth cannot complete, the guest still starts at its previous capacity and the component card offers a repair action with the reason. Extending an existing on-device disk and the ext4 resize on a physical device are covered by device/cloud qualification rather than by this App build alone.

On first boot the guest configures its own network: the slirp interface address and default route are applied, `/etc/resolv.conf` is written with the engine's own resolver alias (`10.0.2.3`, which slirp forwards to the host's resolver) followed by public fallbacks, and the system git config marks the `/workspace` and `/floe/env` shares safe, so an apt-installed guest git accepts host-owned files on the 9p mount. The guest reports `up`, `partial` (interface up but no resolver answered) or `down`; Settings shows that state instead of assuming the network works.

The shell, `exec.localPython`, the managed package installer and the package page share one interpreter per environment: the guest's Debian python3 with a per-environment venv. `pip install`, `pip3` and `python3 -m pip` run the guest's real pip against the environment's configured index — compatible Linux riscv64 wheels (including NumPy, pandas, Pillow and lxml when published) install normally. Node runs the guest's apt `nodejs`/`npm` with the environment prefix; pnpm is used when the guest provides it. A failed or cancelled change preserves the previous generation, and legacy pre-migration installs stay on disk (Python packages are reinstalled into the guest venv from the layer manifest on first start; the old directory is never placed on PYTHONPATH). Normal task permissions and package review still apply where required by the calling tool.

Package indexes and system packages come from the guest's own configured sources: `apt` inside a Linux environment is the standard Debian installer; host-side reviewed data-only `dpkg-deb` operations remain for native environments.

Long-running Python work (bulk downloads, data cleaning) should not block the conversation: `jobs.submit` runs `exec.localPython`, `network.download`, `network.http` or `web.fetch` as a durable background job with an immediate jobID, up to a 600-second cooperative deadline for Python. Track with `jobs.status`, collect with `jobs.result`, stop with `jobs.cancel`; completion re-enters the conversation automatically and posts a local notification. Background downloads keep running while the app is suspended and resume transparently after network interruptions (2 GB cap).

Since 1.6.3: job submissions validate the target tool's arguments at the call site (a wrong argument name fails immediately naming the missing key, not asynchronously later); a task checklist closes itself once every step is settled and the next task starts a fresh list (history is preserved); a tool failing three consecutive times trips a circuit breaker that forces re-reading its schema; long runs receive a plan-freshness reminder when work outruns the checklist. The Picture-in-Picture surface shows the real app icon, the currently running tool with call/failure counts, and the pending-approval tool name; its speed figure reflects model decode only (tool output is never counted).


`exec.localNumerical` provides a bounded, dependency-free R, Stata and MATLAB/Octave compatibility surface for descriptive statistics, quantiles, covariance/correlation and one-predictor OLS. Stata-compatible commands include `generate`, `display`, `summarize`, `correlate` and `regress`. It is not GNU R or Stata. PyStata still requires a separately installed, licensed Stata runtime, and `pyreadstat` depends on native extensions; neither ships as a bundled iOS payload. A guest-installable riscv64 build can run in the Linux environment, and full R/Stata otherwise routes to a configured trusted SSH host.

An installed skill may include bounded UTF-8 `.py` scripts and exact-version pure-Python package requirements. The creation/install review validates paths and source, downloads and inspects only universal wheels, and records script/package fingerprints. A later task can execute the identical audited script without asking again for ordinary sandboxed computation; task inputs travel separately in `inputJSON`. Any source or dependency change, important-file mutation, credential use, privilege request, destructive behavior, or external side effect returns to the current task's normal approval policy.

**Build 227 — the native IDE editor.** Opening a text, code or unknown text file from the workspace or the IDE now uses a native Swift editing surface: multiple open buffers in a tab strip, line numbers, bounded syntax highlighting, find/replace with wrap, undo/redo, and save with version checking and a side-by-side conflict review that keeps your draft. Drafts stay per buffer: switching tabs does not discard unsaved text. Guards are explicit rather than silent — a file over the 4 MiB text limit or without valid UTF-8 text shows a specific reason and uses the appropriate file preview, and up to 12 buffers stay open; when all 12 hold unsaved drafts, a new open is refused with a bilingual explanation and a **Save All** action instead of closing someone's draft. Highlighting is deliberately bounded (about 512 Ki UTF-16 units) and larger files still open with plain styling. IDE text and code editing use the native UIKit editor exclusively; there is no Web text-editor switch. Office and PDF keep their own surfaces, the file tree, source control, terminal and Run panel are shared, and Run stays restricted to the languages the local runtime offers. The [targeted cloud App/UI run 35947162133](https://github.com/JiangNanGenius/floe-agent/actions/runs/35947162133) passed on iPad mini and iPhone simulators, including save and cold reopen. An iPhone DXF preview assertion failed on its first attempt and passed on automatic retry. Physical-device keyboard/IME behavior remains unverified, and the Build 227 regression in which Office documents opened from the IDE file tree stay on the opening indicator is an open issue.

These screenshots show the native IDE as shipped in Build 227, captured in the iPad mini and iPhone simulators with a synthetic test workspace. They demonstrate the native layout and compact Explorer drawer; they are not physical-device acceptance.

<img src="images/floe-native-ide-ipad-mini-simulator.png" width="560" alt="Native IDE file sidebar and editor in the iPad mini simulator">
<img src="images/floe-native-ide-iphone-drawer-simulator.png" width="260" alt="Native IDE Explorer drawer in the iPhone simulator">

The signed WASI catalog installs sandboxed WebAssembly commands app-wide, separate from environment-layer packages and from Debian: the `wasm.packages` tool lists the verified catalog and installs or removes an entry by id, and an installed `floe-lua`, `floe-ruby`, `floe-php` or `floe-text` also answers to its `lua`, `ruby`, `php` alias in the shell. Lua 5.4.8, Ruby 3.4.1 and PHP 8.2.33 are catalog entries; PHP is the security-maintenance 8.2.33 release with the reviewed patch series. `apt` inside a Linux environment is the guest's Debian installer and does not install these WASI commands. Interpreter startup can exceed the default shell timeout, so raise `timeout` or use `jobs.submit`. Rust/Swift/C/C++ are not locally compiled — route them to a configured host as described under Run the current file.

## 13. Create and manually edit Office documents

The Agent can create native DOCX, XLSX and PPTX files with `document.createWord`, `document.createWorkbook` and `presentation.createDeck`. It can inspect semantic fields with `document.office.inspect` and apply bounded text, cell, formula and slide-note changes with `document.office.updateText`. These operations are local and do not wait for an approval model when they remain inside the current workspace.

For manual revision, open the file from the workspace or Notes and enter the full-screen Office editor. Builds with the embedded Office engine provide document layout and editing controls for Word, spreadsheets and presentations; the document menu includes drawing/annotation and presentation controls where applicable. A workspace preview keeps this standalone full-screen route for Office files; only an open that starts in the IDE file tree uses the IDE's embedded document tab. Notes keeps document tabs and access to its assistant. Saving checks the original version and preserves recoverable drafts after conflicts or errors; closing the standalone editor with unsaved changes asks save, discard or cancel, and Command-S saves in place through the same shared save path for DOCX, XLSX and PPTX. Advanced macros, animations and exact desktop Office formatting are not guaranteed.

Build 179 updated Office font selection, saving and closing. If another editor changes the document, Floe keeps your draft and asks you to resolve the conflict. Saving, reopening and native controls still need device verification.

The build 192 repair made editability truthful. An unknown or missing engine permission is never treated as editable; a protected or read-only document returns to preview with a reason, and a document that needs its edit password prompts for it. An imported workbook with its own formulas, sheets or embeddings may have its save rejected instead of being silently rewritten; the original file is preserved. Build 219 adds one shared bounded save/close-confirmation path for DOCX, XLSX and PPTX, a PPTX load watchdog so an unresponsive open cannot leave a blank page or an indefinite saving state, and an edit request that arrives before the standalone editor has finished opening either continues into edit or reopens the document — it is not silently dropped. Native chart round-trip, save, close and reopen on a device are still pending.

The PowerPoint repair on top of Build 219 fixes a presentation-only edit failure: the mobile editor starts every presentation in its endless-slide viewing layout, and the previous automation refused the engine's own edit entry for that layout, so a PPTX could report itself editable while the engine stayed in the viewing UI. Floe now follows the engine's guarded mobile entry for presentations and drawings and verifies that the engine actually switched into its editing UI before any writable claim is made. Readiness is also render-truthful: a presentation (PPT, PPTX, PPTM, PPS(X), POT(X), ODP/OTP/FODP, ODG/OTG/FODG) is not "ready" until the host has decoded a real document tile on a sized canvas. If no tile appears before the bounded deadline, the editor shows an actionable failure with retry/recovery instead of a blank ready editor, and the editing copy is retained. Word and Excel documents keep their existing open-only readiness. Build 227 pins the newer cloud host from run 35818562658 (commit `912e3b59`, post-entry paint validation, with verified archive, executable and resource digests) so the App builds against the contract that gates the edit entry on a real paint; the older host had been compiled and re-pinned from the `office-native-host` run 35668651442 on 2026-09-22. The device-capability receipts (embedded editor, visible render, device round-trip and original-file write-back) remain unproven: on the delivered Build 227, iPad testing found that a PPT/PPTX preview opens but the edit entry then stalls, so editable slide content, save and reopen are not accepted. Word and Excel documents opened from the IDE file tree also stay on the opening indicator on Build 227.

PDF is separate from Office: open it directly from the file list, read it in the wide-screen inspector, then expand to fullscreen. The shared reading session retains page and zoom state; changed local files reload. Remote previews are downloaded read-only snapshots. Office saves check the file version and retain your draft when saving fails or conflicts.

## 14. Use the workspace canvas and standard MCP

Open a workspace's Files inspector and choose **Canvas**. Each workspace owns at most one native canvas project, and that project can contain multiple canvases. The current native surface supports movable text notes, freehand drawing, panning, zooming, renaming and deleting individual canvases, and atomic local persistence. Canvas content stays with the workspace and is not silently published to a global asset library.

The canvas is deliberately a focused editing surface, not a second unrestricted browser. Drag empty space with one finger to pan, drag a node to move it, use two fingers to pan and zoom at any time, and use Apple Pencil to draw. Double-tap empty space to create a node; drag a connection port to another node or release on empty space to create the next node. Import artifacts from Files, Photos, or Materials rather than creating meaningless empty media nodes.

The small AI field below a selected node edits that node in place. It sends only the node's current value, saved settings, explicit references, and the new instruction; it does not open Canvas Assistant, create a task conversation, call tools, or start generation. For a generation task it can refine the prompt and provider-compatible options. Save the configuration first, then press **Start Generation** on the task card. The task and artifact cards show queued, generating, downloading, failed, and ready states. Retry reuses the existing task and artifact nodes.

Only explicit source connections contribute generation context. Ordinary connections, direction-only arrows, generated-artifact relationships, unconnected notes, and older output do not. Starting or retrying an existing task reuses its saved snapshot and never inserts a new prompt node. Execution stays inline on the task and artifact cards; configuration and import are the only generation flows that open sheets.

Choose **Canvas Assistant** for cross-node research and orchestration with only the tools allowed on the canvas surface. A text-only primary model routes visual understanding through the configured Canvas Vision model; when none is available, Floe reports the missing capability once instead of retrying. A research result remains read-only in the assistant conversation and is never written to the canvas automatically. Public web images are downloaded, validated, deduplicated, and stored before being used as references; raw web URLs are never sent as reference-image inputs. Standard MCP remains disabled for canvas by default. Open **… → Canvas Guide** to replay the canvas onboarding.

To connect a standard remote tool server, open **Plugins → Manage Connectors → Standard MCP** and add a Streamable HTTP endpoint. Floe supports no-auth, Bearer token, and custom-header authentication; secret values are stored in Keychain rather than server metadata. Each server and discovered tool can be enabled independently. Remote tools use a server-specific namespace, remain subject to the current task's local permission and approval policy, and treat server descriptions and outputs as untrusted data. Enabling **Allow canvas use** adds only that server's currently enabled tools to future Canvas Agent runs; the setting is off by default, does not grant ordinary task authority, and never bypasses approval.

You can also create a private canvas from **Creative Mode → New Canvas** without first binding a workspace or configuring an image-generation model. Creation menus show generation tasks first. iPhone uses a compact action menu and scrollable bottom tools; new nodes use the actual viewport. SVG, HTML, and Markdown node refinement checks revisions to avoid overwriting concurrent edits.

## 15. Install and create Skills

- **Skill Creator** builds a local declarative instruction package.
- **Skill Finder** downloads an HTTPS candidate, uses a selected model to normalize it for iOS, then runs deterministic validation and compatibility checks.

Skill tool calls remain subject to the current task authorization and runtime validation. Supported UTF-8 Python scripts and pinned pure-Python dependencies are reviewed at installation; execution reuses only the approved fingerprints. Code or permission changes are checked again. This does not permit native dynamic plugins or installation hooks.

The plugin entry separates **Discover** and **Installed**. Official entries show purpose, version, and install/update actions; source and technical details are folded away. Uninstalled official plugins stay removed across launches and can be installed again from Discover. Updates that expand permissions still show the change.

## 16. Troubleshoot

- **Model not configured:** add a provider and select a default Agent model.
- **Apple Foundation Model unavailable:** read the exact reason under **Settings → Local Models**. It requires an eligible device, iOS/iPadOS 27, Apple Intelligence enabled, and the system model ready.
- **Downloaded local model will not load or terminates the app:** free device memory, unload another model and retry once. Export the newest device/Xcode or uploaded diagnostic log; do not diagnose it from an older unrelated crash. If the app crashes as soon as a downloaded MLX model starts an ordinary chat or the benchmark on Build 227, that is a known open regression, not a configuration mistake.
- **Vision unavailable:** select a provider/model that advertises and implements image input.
- **Local model does not call a tool:** confirm the tool is allowed for the task and that the request names the intended action. Floe displays a capability or structured-call parsing reason when the model cannot use it.
- **Task interrupted after backgrounding:** reopen the task and use the offered safe recovery action.
- **A resumed task repeats completed tools:** stop the run and export diagnostics. A recovered run should restore its execution ledger and must not replay successful tool/argument pairs.
- **Browser says `stale`:** observe the page again before interacting.
- **Remote tool unavailable:** confirm the host, SSH authorization, task permission, and network path.
- **LAN scan finds nothing:** allow Local Network access in iOS Settings, stay on the same LAN, and retry. Discovery is limited to the Bonjour service types declared by the app and is not a general port scanner.
- **Workspace preview says it is not open:** reopen the Files inspector and confirm the task has either its private workspace or the intended project binding before opening the file.
- **Picture in Picture is black or does not start:** Floe prepares a live inline progress source while the task runs and lets AVKit promote it when you leave the app. Returning to Floe ends the active system PiP session. If you close PiP yourself, Floe will not recreate it for the same task batch after another foreground/background cycle; a new Run resets that choice. Include the PiP status and latest diagnostics when reporting a persistent black frame.
- **A Python package will not activate:** inside a Linux environment, `pip` installs the guest's real Linux packages, so a package without a riscv64-compatible build fails with that reason. Packages installed by the app's own skill installer remain limited to pure-Python universal wheels. The retired iOS wheelhouse and native-extension embeds are no longer part of the App; a package with no riscv64 build and no audited pure-Python wheel belongs on a configured trusted SSH host.
- **Voice fails or exits:** check microphone and speech-recognition permissions, audio route, and whether another app owns the input session.

Export a redacted diagnostics report from **Settings → Privacy & Security** when filing a reproducible bug. See [Support](../SUPPORT.md) for the report checklist and [Security](../SECURITY.md) for private vulnerability reporting.

## 17. Manage data, fonts, archives, and synced credentials

Open **Settings → Data Management** to inspect Floe's total footprint, installed app size, user data, safely reclaimable space, and categories for local models, private workspaces, fonts, attachments, generated content, browser artifacts, checkpoints, database and other data. Safe Cleanup removes only rebuildable caches and temporary items left for at least one hour. It does not remove workspaces, documents, models, fonts, attachments, the database, or credentials.

**Data Management → Archived Tasks** supports swipe-to-restore, confirmed single deletion, selected restore/delete and clear-all. The normal task list still supports swipe-to-archive.

**Data Management → Font Resources** keeps one content-addressed Floe-global copy of each imported font. Import from Files or use a direct public HTTPS URL for a TTF, OTF, TTC or OTC file up to 32 MB. Floe registers the managed library again at launch, so Word/PDF work in every workspace can reuse it without downloading per workspace. In Automatic mode, `font.list` and bounded `font.install` bypass approval-model latency; `font.remove` remains reviewed because it affects all workspaces. Apple public APIs do not permit an arbitrary web font to be silently installed for unrelated apps, so downloaded fonts are global within Floe rather than system-wide outside Floe. If iOS does not expose a requested system font, the Agent explains that boundary and installs a permitted font into Floe's managed library instead.

**Diagnostics & About → Third-Party Licenses** is the single legal entry. It reproduces the complete TinyEMU/slirp notices (MIT core plus the BSD-2-Clause and BSD-3-Clause slirp subset and the downloadable Linux guest terms) and every other notice bundled with the App — PDFium, libarchive, document conversion, engineering viewers/OCCT, Whisper, the offline IDE, image/video components and each bundled CJK font family — then lists the engines, Swift packages, Python runtimes and conversion/IDE components with their versions, license identifiers and sources. Each text can be copied in place. A notice that a particular build omitted is shown as unavailable instead of being hidden, and the generated repository record `FloeAgent/LICENSES-THIRD-PARTY.md` remains the authority for versions and sources. **Build 227** consolidates the previously separate TinyEMU screen into this one entry; earlier builds listed both.

Task history is device-local. Configuration sync includes provider/model profiles and non-secret host profiles, while provider API keys use iCloud Keychain. **Sync saved credentials** is off by default and requires device authentication. When enabled, only credentials explicitly promoted to the vault can sync; task/workspace temporary credentials never do. A descriptor may arrive before its Keychain item, in which case the UI shows **Waiting for secret** instead of claiming synchronization completed.

**Settings → Files → Browse and Manage Files** provides quick access to project workspaces and private workspaces from active or archived conversations. Browsing does not switch the current conversation workspace. Reuse directory search, preview, edit, move, export, and batch deletion. Deleting a private task cleans up its own files while shared projects remain; pending local cleanup can be retried in the manager.

## Long reasoning

Expanded long reasoning uses its own scrolling reading area with beginning/latest navigation and fullscreen reading. Copy retains the complete transcript. Partial tool-argument generation counts as activity; execution still waits for complete, validated arguments.

### Convert existing files (this test release)

Ask to convert a workspace Markdown, DOCX, HTML, RTF or text file to another supported format, or to PDF, while keeping the source. Floe passes file paths to its bundled offline converter rather than asking the model to rewrite the body. Results are saved as new files; only compact status and warnings return to the model. Local images are embedded. Searchable PDF input exports text in page order; scans need OCR first. Complex page geometry, floating objects and formatting that Markdown cannot represent are not guaranteed to survive. Open the output to inspect it.


### Visual editing and captions (1.7)

Open a workspace video and select the crop/rotate/captions entry in the media workbench. Add manual captions with source start/end times, then open the visual editor to adjust cropping, rotation, speed and caption placement/size. Saved and exported videos become new workspace files. See the [integration and qualification status](FLOE_1_7_VIDEO_EDITOR_INTEGRATION.md).

### Audio and frame utilities (1.7)

Ask the Agent to trim workspace audio, adjust gain, apply fades or mix two inputs. Mix inputs must share a sample rate and channel count; convert them first when needed. Gains range from 0 to 16 and summed peaks clip to the normal PCM range. Choose a separate WAV, CAF, AIFF or M4A output. Cancellation preserves the source and any existing output.

Frame extraction writes actual PNG or JPEG files. Choose timestamps or an interval and a new output directory; the complete batch commits together and existing directories are preserved. Proxy videos retain their aspect ratio within the requested maximum dimension.

## Light, dark and automatic appearance (1.7 beta)

Open the lower-left **Settings → General** and choose Automatic, Light or Dark. Automatic follows iOS, including its scheduled/sunset appearance changes configured under system Settings → Display & Brightness → Automatic. Manual choices persist and apply immediately. A canvas without its own explicit appearance inherits the app choice. Document pages and video pixels retain their original content.

Reasoning and tool calls use consistent expandable frames. Open a header to inspect text, inputs, outputs and approval records. Consecutive calls can collapse as a batch without reopening on each result. Current activity, failures and pending decisions remain visible when collapsed. New steps use a short fade/offset transition; Reduce Motion disables it.

## Project, conversation and package management (1.7 beta)

Open **Settings → Execution Environment → Project and conversation containers**. Search environment names or IDs, then inspect ownership, status, measured storage, locally installed dependencies and read-only inherited dependencies. Installation, removal and version holds target the exact environment shown on that page.

**Build 227 — what an environment owns.** An environment's own installed packages live in its own layer; dependencies inherited from a project, shared or base layer are read-only. Two environments do **not** share installed packages, a running VM or localhost, even when both descend from the same base: each keeps a private copy-on-write disk bound to the verified base image, so one environment's changes never appear in another. Inside one environment, however, commands, terminals and local services all run in that environment's single guest, so they do share its files, installed packages, network and localhost. Downloads may be cached, but a cached download is not an installed package, and a saved template is immutable — installing something into an environment never changes the template it came from. Installation state and the current VM are also separate: stopping an environment keeps its disk and installed state, and the next start is a new VM with a new runtime identity. Saving a template is idempotent for identical content and creates a new version for different content. The software-templates page shows each official image's real state: the basic and dev-document images passed cloud qualification and are published as component prereleases, but each still needs this build's install-path checks before the App can offer it as a user download, and the page reports an unmet dependency instead of promising an install. Resource shape is honest too: a new environment requests one vCPU and a small RAM tier, the pool admits it within the device budget, and a dual-core request fails closed with an explicit reason until a genuinely SMP-capable guest image is qualified; the higher-performance six-vCPU tier is not enabled. There are no user-facing CPU/RAM controls in this build.

Refresh validates repository signatures and indexes before exposing installable versions. Missing sources and failed verification appear as errors, not a usable package catalog. Production apt source provisioning and the official package pool remain unfinished. Package tasks retain their running/result state across navigation and provide cancellation while running.

The **Python · PyPI** and **Node.js · npm** management pages live inside each environment. Enter a package name and optional version, inspect local versus inherited dependencies, and uninstall only locally owned packages. App-owned jobs continue after navigation and expose cancellation/results. npm uses staging and a recovery journal and explicitly rejects unsupported native artifacts or install scripts; package operations install into the environment's Linux guest through its shared venv or npm prefix. The retired in-process Node runtime and native Python host are no longer part of the App, so their older host-test evidence is historical; physical-device qualification of the guest install paths remains pending.

Stop closes admission before waiting for that environment's tasks; Resume reopens a stopped environment unless its dependencies require rebuilding. Stop before saving a template. Deletion waits for owned work and refuses a project with remaining child sessions or a worker that has not ended. These containers layer dependencies, data and lifecycle; they are not strong process isolation for native code.

These development captures use native production components with synthetic
workspace/task rows; the actual appearance entry is Settings → General.

<img src="evidence/floe-1.7/interface/appearance-light.png" width="300" alt="Light appearance in General">
<img src="evidence/floe-1.7/interface/appearance-dark.png" width="300" alt="Dark appearance in General">

Completed calls can remain folded while a newly running tool stays visible:

<img src="evidence/floe-1.7/interface/thread-folded-active.png" width="360" alt="Folded completed calls with visible current activity and an error result">


## Canvas image and video workbenches (1.7 development)

Select a local image and choose **Edit image**. The image workbench opens directly,
with crop, drawing, text, mosaic, filters and adjustments. Undo, redo and original
comparison stay accessible above the image. **Save copy** verifies a new PNG and
returns it to the canvas as a derived asset; the source remains unchanged. The
interface follows light/dark appearance. Layers are flattened on export.

Select a local video and choose **Editing and captions** to reuse the workspace
video editor. Verified exports become derived canvas nodes. If the originating
canvas changes, the result remains in the material library instead of being
inserted into a different document. Full-App and physical-device acceptance
remain separate from the native fixture tests.

The Canvas Assistant now uses the main chat's Markdown, live reasoning and tool
frames, and provides access to earlier conversation records.


## Document assistant refinement under validation

The repair following Build 172 opens the document assistant directly to your conversation. The document name stays in the panel header; document IDs and tool setup instructions no longer appear as an opening chat message. Ask a question, request an edit, or save an answer as note content using the same assistant. Existing document access and edit permissions still apply.

On a wide iPad layout the assistant sits beside the document in an inset pane; smaller windows use a dismissible sheet. Model, mode and permission controls remain available. Close the assistant to reclaim writing space without deleting its conversation. These changes are delivered in build 178; see the [repair ledger](FLOE_172_REPAIR_EXECUTION.md).

## 1.7 Notes and local speech

These instructions describe the 1.7 internal beta. Check the [implementation record](FLOE_1_7_CONTINUATION_STATUS.md) for full-app, device and TestFlight status.

The sidebar orders New Task, Task Center, Notes (手记), Creative mode and Plugins / Skills above projects and tasks. Settings remains at the bottom left. Notes and Canvas keep separate content management; there is no additional top-level Library destination.

- Use the Notes plus menu to create notebooks, pages, mind maps or Office files, or import PDF, images, Office files and `.floenote` archives. Search, notebook filters, favorites, rename/move and trash recovery organize content.
- Pencil drawing is the default. Finger drawing is enabled separately in the writing toolbar. Insert text, images and shapes; adjust page elements using their position, size and color controls.
- On version 27, select ink with the native lasso and choose Ask Floe, or use AI region selection for page content. The actual image and source coordinates enter the assistant composer for review before sending. Select a model capable of handling the supplied image.
- Save an assistant response as editable content or a new organized note. Long answers paginate and retain AI/source identity. Source links open the current source page.
- Export a readable PDF or an editable `.floenote` archive; mind maps also export Markdown outlines. Archive import creates an independent copy with validated resources, without importing conversation permissions or undo history.
- Office uses the existing native engine. Export, drawing and presentation controls depend on host capabilities. Recovery can create an independent document. Actual Word ink persistence and PowerPoint presentation behavior still require full-app device acceptance.
- The new-task home screen, existing conversations and the Canvas assistant can select Notes material, read-only by default. Home creates a task only when sent, retaining draft scope on a failed launch. The picker displays and revokes grants; revocation does not remove text or Office attachments already sent to chat. `notes.read`, `notes.search` and `notes.edit` use only that conversation's selected scope.
- Select a mind-map topic and use the topic-image menu to insert, replace or remove its image. The center topic is used when nothing is selected; the menu names the target. Up to 64 distinct image resources are retained in editable archives.
- Use **Document maps** to create or link an independent map and open it in a movable, resizable reader window. **Topic content and attachments** stores images, documents, audio, video and other files for preview, replacement and sharing. Editable archives include linked maps; unlinking does not delete the map. See [mind-map behavior and archive scope](FLOE_1_7_MIND_MAPS.md).


Settings → General contains system/light/dark appearance and Whisper management. The multilingual Small model is an on-demand download of about 491 MB. When Whisper is unavailable, recognition falls back to Apple and its system permissions. Video captions and Agent `audio.transcribe` now use the file transcription service, with separate SRT, VTT or JSON output and bounded audio chunks. Mixed Mandarin/English quality, long recordings and device behavior remain under validation.

### Dynamic maps and Trash

Mind maps lay out their hierarchy from actual topic and image sizes. Adding, removing, moving, expanding or collapsing topics updates the layout and connectors; Agent layout-direction edits apply to the same editor. Editing retains zoom and selection; resizing the PDF window fits the map. The current renderer uses an adaptive tree layout. Every map editor keeps **新增子节点** (Add child node) and **新增同级节点** (Add sibling node) at the top-left: with a topic selected, the button creates the node and opens its text editor immediately, with no extra canvas tap, while a missing selection or a center-topic sibling gets an explicit hint. The new node re-flows the connectors and remains undoable and saved.

In Trash, restore an item or confirm **Permanently delete**. Permanent deletion removes that item's history and future assistant access, while independent linked maps and existing conversation copies remain separate. Shared files and other documents' undo history retain their resources. Active previews and exports defer collection until the app restarts and Notes opens again; failed collection remains retryable.

Export `.floenote` before permanent deletion if you need an editable backup containing images and linked maps. PDF shares rendered pages and annotations; Markdown exports a map outline.

![Text and ink reread from an exported PDF](evidence/floe-1.7/notes/ipad27-export-text-and-ink.png)

This is an exported-file image from an iPad SDK 27 component test, not a full-app screenshot. See the [evidence record](FLOE_1_7_CONTINUATION_STATUS.md) for device and release qualification.

![PDF and independent map window on iPad](evidence/floe-1.7/notes/verified-455/ipad-landscape-pdf-map.png)

This iPad component fixture comes from `4550b6d`. It illustrates the PDF and map window, not full-app or physical-device acceptance.

<img src="evidence/floe-1.7/notes/verified-455/iphone-portrait-pdf-map.png" alt="iPhone portrait map window" width="320">

The same passing component test also exercises portrait iPhone layout. This is a component fixture; close the window to return to the PDF.

## Writing tools and Apple Pencil

The Notes editor combines Back, title/save state and document actions in one header. Secondary actions move into a menu on iPhone. The writing palette provides pen, highlighter, eraser, lasso, AI region selection, ink color/width and undo/redo; its toolbar button works without Pencil Pro.

Build 172 added document tabs: select a tab to switch, use × to close its view without deleting the document, and use + to find another document by title or indexed content. Returning to the library keeps open tabs. Relaunch still starts in the library. The arrow beside the writing toolbar collapses the document header and tab strip while leaving writing tools available. Each document retains its page, viewport and tool; a failed Office save prevents switching. Squeeze opens a compact ring around the Pencil tip: pen, highlighter, eraser, lasso and AI selection occupy fixed positions. Movement, hover and lifting only preview; explicitly tap a tool to confirm. Squeeze again, tap blank space or use the center close control to dismiss without changing tools. Choose Above (default), Upper left or Upper right in the writing toolbar’s More > Tool arc position menu; the choice persists. Tap the color dot or the current pen again to open the brush panel. Ballpoint, fountain pen, monoline, pencil, crayon, watercolor, calligraphy/reed and highlighter each remember color, width and opacity. Thin/medium/thick shortcuts and continuous width/opacity sliders update the stroke preview. The arc’s pen slot restores the last writing brush. These interactions are delivered in build 178.

Native squeeze and double-tap callbacks follow the system action preference, using the hover location for the contextual palette when available. Disabled gestures and system shortcuts are left to the system; finger drawing remains opt-in. See [Apple's Pencil interaction API](https://developer.apple.com/documentation/uikit/uipencilinteraction). Build 164 has passed this complete App UI flow on both iPad and iPhone with SDK 27. Accepted-SDK qualification and distribution remain pending; physical squeeze delivery requires compatible hardware.

<img src="validation/floe-156-feedback/screenshots/full-app-build164-sdk27/ipad/notes-pencil-quick-menu.png" width="640" alt="Floe Notes writing palette on iPad">

<img src="validation/floe-156-feedback/screenshots/full-app-build164-sdk27/iphone/notes-imported-pdf-fullscreen.png" width="300" alt="Full-screen Notes editor on iPhone">

Original build-164 SDK 27 simulator captures: the iPad palette and the iPhone full-screen editor. See the [capture manifest](validation/floe-156-feedback/screenshots/full-app-build164-sdk27/manifest.json) for the fixed source and passing UI results.

### Managed local preview services

Use **Settings → Execution environments → selected environment → Local services** to inspect output, open a ready preview, stop a server or start a new attempt. Ask the assistant to start a Node.js or Python service from a workspace script, or use Shell:

```sh
floe-service start node server.cjs 8080
floe-service start python server.py 8081
floe-service list
floe-service status JOB_ID
floe-service logs JOB_ID
floe-service stop JOB_ID
floe-service restart JOB_ID
```

Scripts bind `127.0.0.1` and use the supplied `PORT` environment variable. Additional script arguments follow `--`. Start returns a job ID; the preview URL appears only once HTTP responds. Closing previews or switching conversations keeps the service running. iOS may suspend execution in the background; app termination interrupts it and requires explicit restart. Stopping waits for the actual worker to exit. This supports managed Node/Python HTTP scripts, not arbitrary Linux daemon processes.

For environment JavaScript dependencies, choose **Automatic / npm / pnpm** on the package page. Automatic follows the owning project's `packageManager` and single lockfile; conflicting hints need an explicit choice or project cleanup. This selects the guest manager used for the environment installation (pnpm only when the guest provides it); it does not change the project's manifests, lockfiles or requested CLI version. Switching managers creates and validates a staged tree before replacing the installed generation. Failed installs keep the previous dependencies. Shell `npm` and `pnpm` remain explicit commands for project work: an explicit `npm install`/`pnpm install` is never silently replaced by the other manager because of a project lock or preference.

Office documents inside Notes share one top row for back, document tabs and actions. On compact screens, attachment, drawing and presentation controls move into the document menu. The assistant menu also opens document-linked mind maps.

Shell `npm install` and `pnpm install` use the selected session/project environment and the same rollback path as Settings. Without package arguments, they read the current package.json dependencies and devDependencies. Project manifests/lockfiles are preserved; this environment installation is not a reproduction of a project's frozen lock. Both `require` and ES module imports can locate the resolved environment dependencies. A cancelled package command returns exit 130 without executing.

Python packages can also be managed with `pip`, `pip3` or `python3 -m pip`: install a compatible package, uninstall one environment-owned distribution, or inspect dependencies with list/show/freeze/check. The commands use the same managed installer as Settings. An unavailable native extension requires a compatible App build; installing its pure Python wrapper alone does not make it usable.

The package page lets you edit the selected environment's Python Simple index or npm registry under **Package source**, or restore the official address. Manual, Shell and Agent installs share the setting; npm/pnpm share the Node registry. Use a public HTTPS source without credentials in its URL. Existing dependencies remain installed and the next transaction uses the new source. Private-registry authentication and the Floe language-package mirror remain incomplete.

Historical screenshots: [document assistant, brush controls and PDF body search](evidence/floe-1.7/build172-repair/notes-9e4434ca/README.md). These are full-App simulator captures from `9e4434ca`, not a new TestFlight availability claim.

### Build 173: search, ink and diagnostics

Entering a body-search query in Notes shows compact rows with a preview, title and matching excerpt. Press Search to dismiss the keyboard; clearing the query restores the chosen cover/list layout. Full-App iPad/iPhone validation of this layout was recorded with that repair; this guide does not claim a newer device pass.

Brush controls use transparency: **0% is solid; 100% is invisible**. Each brush retains its own value. Existing stored alpha values are preserved rather than inverted; highlighters keep their own transparency. Ink renders for the light paper surface even when the surrounding app uses Dark appearance.

Settings → Diagnostics & About → Logging settings offers Debug, Info, Warning and Error. Info is the default. The threshold applies to newly collected messages at that level or higher; it cannot reconstruct messages that were not collected. The App buffer and server retention are separate: the server's approximately 500-entry retention patch passed local checks, but deployment has not been confirmed. Changing the client level does not upgrade the server.

Since the Build 173 repair, each document assistant has its own persistent conversation. Its history stays inside the document and is excluded from ordinary chat lists, archives, full-text chat search and cross-chat history tools. Existing document bindings are repaired on upgrade without deleting messages. Adding Notes material to an ordinary chat does not turn that chat into a document assistant.

Build 176: the document assistant uses a full-height column on wide iPads and a sheet on iPhones or narrow windows. The header's restart button starts a new conversation for this document, stopping its previous run while preserving the document and old messages. Committed assistant edits refresh the open page automatically; local ink is saved first and unsaved strokes remain protected. Undoable edits to this document use the native document grant; other tools retain normal checks. Final-source interface verification of that revision remains historical.

## Editing alongside the assistant

Both editors remain available. If a text file changes before saving, review the combined independent edits, choose overlapping regions and optionally edit the result. Recovery drafts stay in `Recovered Edits`; another change triggers another version check. Office offers separate version previews and exports. Notes preserves conflicting changes in a separate recovery document, allowing you to keep both versions or apply the reviewed edits. Exporting a copy does not mean the original was saved. See [concurrent editing](FLOE_CONCURRENT_EDITING.md) for limits and pending qualification.

### Run the current file

In the full-screen IDE, open a code file and choose **Run**. The run panel shows the selected runtime or SSH host and the command before execution. Floe saves the editor first; unresolved conflicts or a failed save prevent running an older revision. Installed Python, Node, Shell and Lua use the local runtime. Rust, Swift, C/C++, PHP, Ruby, Go, Java and Kotlin need a configured host with the corresponding executable.

Remote Run transfers and verifies only the current file, up to 1 MiB; it requires the Floe remote agent and does not copy project dependencies. Stop can cancel preparation or request cancellation of a running program. Remote process exit and cleanup are shown as unconfirmed when they cannot be observed. Closing the IDE stops its owned local run. These additions have focused code tests; full-App and real-host qualification are still pending.

### Local terminal

The IDE bottom panel can host the local terminal. It reuses the app-lifetime shell session, so closing the panel does not end the shell; the standalone terminal keeps its restart and end-session actions. The build 192 repair fixed a descriptor race between an interactive session and a concurrent close or expiry, and preserves the last output of a command that exits immediately. When the engine is still running another command, a new command reports exit 75 (not started) instead of a fabricated timeout. A native command that ignores cooperative cancellation can still hold the engine until it stops; wait for it to finish or restart the app rather than assuming the command ran.

The Office editor also adds **Annotate** settings for color, width and transparency. **0% transparency is solid**. Settings are saved per document; deselect an existing drawing object before changing pen defaults. A pending-confirmation message means the engine has not confirmed the settings yet. Native drawing, export and save/reopen acceptance remain pending.

### Engineering file previews

Open DXF/DWG, mesh or Gerber/drill files from workspace files or the IDE, then expand the preview. DXF/DWG offer Edit for lines, circles and text, numeric moves, undo/redo and same-format Save. Previous versions and conflicting drafts stay in `Recovered Edits`; a conflicting save never silently replaces someone else's revision. Remote CAD and other 3D/PCB formats remain read only.

The current repair branch adds a Pen control for local DXF/DWG annotations. Open Edit to choose a color and line width, then draw with Apple Pencil; finger drawing is a separate switch and starts off. One stroke is one undo step, and the annotation layer can be hidden in Layers. Save keeps the original format and validates the output. Some drawings cannot be saved without losing unsupported style or layout data; in that case saving fails and preserves the original. The preview may simplify printed line widths. This addition has browser-component and engine evidence; native Pencil acceptance and TestFlight delivery are still pending.

Choose **Ask AI** to attach the current viewport and parsed drawing information, inspect the evidence, add a question and send with your configured model. Missing references and sampled geometry are identified. This helps review visible content; it does not establish complete engineering approval. See [the format and evidence matrix](FLOE_ENGINEERING_VIEWERS.md) for verified versions and pending App and KiCad work.

### Drawing review from files (build 177)

Open a supported drawing from workspace files and choose **Ask AI**. Review the
captured viewport and extracted information, enter a question, then send it. If no
chat belongs to that workspace, Floe creates a review task when you send. Opening
the review panel alone does not create a task or call a model. CAD review needs a
configured model; visual limits and missing drawing references remain visible.
Embedded IDE and drawing controls follow the app language. Final-source qualification of that revision remains historical.

### Build 179 record (historical)

This section preserves the candidate boundary as it stood then; later internal deliveries superseded it.

- Notes adds Word, Excel and PPT cover previews and imports DXF/DWG drawings with a read-only preview. Its assistant can read long documents in sections and place text at specific positions on a page.
- Office updates font selection, saving, closing and per-document pen settings. Conflicting changes preserve your draft for review.
- The IDE can save and run the current file, stop execution and use a configured host for remote languages. Shell adds signed Lua installation from the verified WASI catalog (the `apt install floe/lua` form recorded then is no longer the install path).
- Local MLX models change how inference memory is released. The reported iPad chat crash still requires physical-device verification.

Cloud full-App Notes tests passed on iPad and iPhone: three tests per device, with one native Office test skipped on each. See the [retained Notes screenshots](qualification/build178-feedback/full-app-955e346a/README.md). That run failed IDE saving tests; the later targeted run 35223435570 passed all three IDE cases on both simulator devices. Release run 35228451173 then timed out in accepted-SDK Notes qualification before upload. Native Office interactions, real SSH execution and this candidate's TestFlight delivery remain pending. See the [repair record](FLOE_BUILD178_FEEDBACK_REPAIR.md) and [candidate notes](RELEASE_1.7.0_BETA_36.md).


### IDE cloud builds (build 180)

After connecting GitHub in Settings, open a source file in the full-screen IDE
and select **Run → GitHub Actions**. Choose the repository, base branch and
workflow, then review the file snapshot before submitting. If the repository has
no suitable workflow, review and install the provided template; installation adds
a workflow file to the repository default branch, so this is an explicit action.

Floe keeps the remote job record independently of the editor and conversation.
Closing the editor or App does not cancel the GitHub build. On reopening, Floe
reloads unfinished records and polls GitHub while the App is active, backing off
when nothing changes or the network is unavailable. A cancelled job remains
pending until GitHub confirms it stopped. If the submission response was lost,
Floe looks for the original snapshot run instead of silently launching another.

Return to the IDE run panel to see status, logs and available artifacts. Downloaded
outputs are cloud build products, not iOS executables. Files on the device remain
editable while the snapshot builds. This feature is still awaiting final-source
cloud and interface qualification; see [the workflow guide](IDE_GITHUB_ACTIONS.md).

Library cover qualification now explicitly includes Word, Excel, PowerPoint, DXF
and DWG. Functional acceptance requires real content: a system thumbnail or a
labelled, independently verified Office summary; generic icons and blank cards
still fail. The strict system-thumbnail-only checks are recorded separately and
never turn a failure into a pass. A labelled summary does not establish an
original-layout thumbnail. See [thumbnail acceptance](NOTES_OFFICE_THUMBNAIL_ACCEPTANCE.md).

### Build 186 and build 187 qualification records (not uploaded)

Build 186 / beta.43 failed qualification and was not uploaded: the focused app
regression passed 204/204 including 23 IDE cases, the Notes component passed 84/84
on iPhone and 83/84 on iPad (one strict Excel thumbnail case hit its 45-second
deadline while a real labelled summary was returned), and both full-App Notes UI
legs failed because an opened Office document's back button lost its
accessibility identifier to the parent header — the button itself existed. The
cover cold-relaunch phase was not reached. In build 187, modern
Office cards show a labelled content summary as soon as it is ready and upgrade
to the system thumbnail when it arrives; a timeout keeps the labelled summary
instead of a blank card. Summaries cover at most 240 fields and the first Excel
sheet, and are not an original-layout render. Build 187 is tagged `v1.7.0-beta.44` at `d77aa11f` and encountered component/UI failures in
cloud run `35312393708`; it has not uploaded. See [beta.44 record](RELEASE_1.7.0_BETA_44.md).


### Historical Build188 cloud candidate

Build187 passed204/204 SDK27 App regressions but failed Notes UI and the original
component fixture. It was not uploaded. Build188 fixes cover-card accessibility
queries and bounds WebKit screenshot waits; source `c5656276a3fed0cc0546d2ab360603e443b7f87e`,
[run35317532109](https://github.com/JiangNanGenius/floe-agent/actions/runs/35317532109).
Cloud verification stopped without an upload; no installability is claimed.

The preceding candidate entries are dated history: builds 188-190 were not delivered and build 191's record is historical. Current availability is recorded at the top of this guide.
