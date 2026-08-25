# Floe Agent User Guide

[简体中文](USER_GUIDE.zh-CN.md) · [Website](https://www.floe-agent.com/) · [README](../README.md) · [Security](../SECURITY.md)

This guide describes the Floe Agent 1.4.31 source target (build 62). Labels may vary slightly with the system language and configured provider. Distribution status must still be verified in TestFlight; a source tag is not an Apple processing receipt.

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

## 3. Configure auxiliary image models

Open **Settings → Auxiliary Models**. The roles are independent:

- **Vision model** reads user images and browser screenshots. Select only a model whose provider genuinely supports image input.
- **Image generation model** creates a new image from a prompt.
- **Image editing model** edits an attached or selected image.

A provider appearing in the Agent picker does not imply it supports vision or image operations. Floe disables incompatible role combinations instead of sending an invalid request.

For a dedicated image provider, choose **OpenAI** or **Google Gemini**, enter its API key, and review the editable Base URL before saving. OpenAI defaults to `gpt-image-2`. Google defaults to Nano Banana Pro (`gemini-3-pro-image`) through the native Gemini `generateContent` API. Keep generation, editing and vision capabilities enabled only when the selected endpoint implements them. A proxy URL may include its own path prefix; Floe preserves that prefix when constructing requests.

### Apple Intelligence and downloaded local models

Open **Settings → Local Models**. The Apple Foundation Model row is system-managed and therefore has no Floe download button, API-key field or model selector. On iOS/iPadOS 27 it reports one of the system's real states: available, unsupported device, Apple Intelligence disabled, model not ready/downloading, or another system availability failure. Resolve that reason in iOS settings and leave Floe open long enough to refresh; do not repeatedly retry while the system model is downloading.

Qwen and Gemma entries are user-downloaded MLX snapshots. Download, load and benchmark are separate actions. Floe keeps one downloaded model resident at a time and checks current device headroom before mapping it. Closing background apps may increase available memory, but iPadOS can still terminate an app under pressure. If loading is rejected, retry after freeing memory or select a smaller model; if the process terminates, export the new Xcode/device or uploaded diagnostic log rather than assuming a prior crash has the same cause.

An installed model can be disabled without deleting its weights. Re-enabling it makes it available to the task picker again; disabling a resident MLX model also unloads it.

Local models receive a smaller, intent-ranked catalog of real Floe tools and a local-only dynamic context/compression budget. Cloud-provider context limits, compression and tool schemas are not reduced to accommodate a local model. If a local model cannot produce a valid tool call, Floe reports the parsing or capability reason instead of claiming the tool ran.

Greetings, ordinary conversation, questions and brainstorming do not require an explicit task command. Apple Foundation Model should answer them naturally and asks for clarification only when missing information materially changes a consequential action. Downloaded MLX models prefill prompts in device-budgeted chunks and release transient Metal/KV caches after each generation while retaining model weights only for tool continuation within the active task.

## 4. Start a task

Normal app launch opens **New Task**. Before sending, use the chips around the composer to choose:

- an Agent model;
- no project or a project workspace;
- local or an authorized remote execution target;
- enabled Skills;
- the initial task permission profile.

Attach files or images, write the request, and send. The draft becomes a persistent task in place; it does not jump into a second chat system.

### Workspace ownership

- **No project selected:** Floe creates an internal private workspace owned by this task and lists the task under **Chats**.
- **Project selected:** the task belongs to that project and appears under its folder in the sidebar.
- A task has exactly one workspace owner. Moving it later is an explicit action because the available file scope changes.
- Deleting a project task never deletes the external project files. Deleting a private task may remove its app-managed workspace and browser data.

### Lightweight source control

Open the workspace Files inspector and select **Source Control**. A non-repository workspace can be initialized in place. For a repository you can inspect status, per-file diffs and recent commits; stage all changes; commit; create or switch branches; fetch; fast-forward pull; and push. Floe intentionally omits destructive reset/clean, force-push and history rewriting.

Open **Settings → GitHub & Source Control** to connect a fine-grained GitHub token. The token is validated against GitHub, stored only in the device Keychain, and never added to a remote URL, repository file, log or model prompt. After connection you can list accessible repositories, clone one into a subfolder of the current workspace, or create a public/private repository. Grant only the repository permissions needed for the intended operations.

## 5. Continue the same conversation

Every later message creates a new Run inside the same task. Floe reconstructs context from prior messages, attachments, tool results, decisions, the active plan and goal, scoped memory, workspace instructions, and task permissions. Older history can be compressed into sourced summaries; evidence is referenced rather than silently re-executed.

If a task reports that it was interrupted, use **Resume** or send a continuation message. Side effects whose outcome is uncertain require confirmation before retrying.

## 6. Choose a working mode

- **Agent mode** can use the tools allowed by the task policy and normal approval gates.
- **Plan mode** is read-only: it may inspect and analyze, but cannot write files, run side-effecting commands, or submit browser actions until the plan is accepted.
- **Goal mode** tracks steps, budget, evidence, child runs, and completion criteria. Completion should be proposed only when the evidence gate is satisfied.

Memory is scoped globally, to a workspace, or to one task. A memory candidate must be reviewed before it becomes active, and memory never grants permissions.

## 7. Review progress and evidence

The task timeline shows assistant output, reasoning previews, tool requests, tool results, file activity, errors, questions, approvals, and checkpoints. The inspector is collapsed by default; open it when you need:

- **Changes** for per-file diffs and line statistics;
- **Files** for the current workspace tree;
- **Browser** for the task's visible web session;
- **Terminal/Host** for an authorized execution target;
- **Progress** for phases, checkpoints, and budget;
- **Child Agents** for independent child-run status and cancellation;
- **Permissions** for the task's effective policy.

Switching tasks clears task-specific inspector references so one task cannot accidentally display another task's browser or files.

## 8. Use the visible browser

The browser is a real, user-visible `WKWebView`. The Agent can navigate, observe a bounded semantic DOM, wait for page changes, take screenshots, click stable element references, type, scroll, and manage tabs within the task policy.

Choose **Take Over** when a page requires login, QR scanning, CAPTCHA, 2FA, password entry, payment, camera/microphone access, a trusted file chooser, canvas interaction, or content Floe cannot safely address. Finish the interaction directly in the browser, then choose **Return to Agent**. Floe observes the page again before the Agent continues.

An element reference is bound to a document ID. After navigation or a major DOM change, a stale reference fails and the Agent must observe again; it must not guess and continue clicking.

## 9. Understand permissions

Effective authority is the intersection of the global ceiling, workspace defaults, task overrides, available device/host capabilities, and any time-bounded grant. The provider receives only allowed tool schemas, and the executor checks authority again.

Routine bounded reads, workspace inspection, image generation/inspection, OCR, read-only PDF operations and local-network discovery bypass approval-model latency. Bounded preparation on an explicitly selected SSH host and ordinary workspace/Git operations can reuse a matching task or session grant. Deleting data, entering credentials, uploading files, browser login/payment, broad remote mutation and catastrophic commands still require explicit review. Git force-push, destructive reset/clean and history rewriting are not exposed.

Approval is based on the user's stated goal and the concrete tool target, not on a brittle keyword match. A broad request such as “test all tools” permits safe diagnostics and bounded non-destructive checks, but does not authorize deletion, credential access, arbitrary remote commands, model-policy changes or persisted personal-data writes. Approval results and reasons appear inside the corresponding expanded tool call rather than as a detached chat message.

## 10. Background work and notifications

Leaving a task screen does not cancel its Run. Floe records checkpoints at model phases, tool boundaries, approvals, user-input waits, child runs, and partial responses. When the app returns, it reconnects to a provider job when supported or creates a recovery Run in the same task.

iOS scheduling and background execution are best effort. A notification or Live Activity opens its target task; ordinary cold launch still opens New Task. Do not assume an SSH, VNC, browser, or model stream stayed connected while iOS suspended the app.

## 11. Apple capabilities, Shortcuts and automation

Open **Settings → Apple Capabilities** to decide which compiled integrations Floe may advertise to the Agent. Calendar, Reminders, Home, Maps, Web, Watch status, vision, mail composition, documents/PDF, camera, location, Shortcuts and automatic tasks are independently switchable. These device-local switches do not grant OS permission; iOS still asks on first real use, and denial must not block the rest of a task.

Floe publishes **Run Floe Task** and **Schedule Floe Task** App Intents. Add **Run Floe Task** to a Shortcuts personal automation for a system time, Focus, arrival or other exact Shortcuts trigger. Floe's own schedule is durable but uses best-effort iOS background refresh, so its wake time is not guaranteed. The immediate intent starts a normal durable task with the default Agent model without opening Floe.

## 12. Local Python, packages and code editing

Signed builds include bounded CPython 3.13. The model can request a familiar declarative command such as `pip install marko==2.2.0`; Floe parses its package specs and asks the package-review model whether they are necessary for the user's existing task before any download. The managed installer resolves dependencies in quarantine and activates only pure-Python `py3-none-any` wheels after hash verification and static inspection. Flags, URLs, paths, shell syntax, native extensions, Mach-O/ELF payloads, dynamic libraries, subprocess execution and sandbox escape remain unavailable.

`exec.localNumerical` provides a bounded, dependency-free R, Stata and MATLAB/Octave compatibility surface for descriptive statistics, quantiles, covariance/correlation and one-predictor OLS. Stata-compatible commands include `generate`, `display`, `summarize`, `correlate` and `regress`. It is not GNU R or Stata. PyStata still requires a separately installed, licensed Stata runtime, while `pyreadstat` depends on native extensions; neither can masquerade as an installable pure-Python iOS package. Route full R/Stata or pandas/native-package work to a configured trusted SSH host.

Open Python, JavaScript, MJS or CJS files from the workspace to use the structured editor with line numbers, syntax highlighting, search/replace, symbols, undo/redo and bounded local execution where supported.

## 13. Install and create Skills

- **Skill Creator** builds a local declarative instruction package.
- **Skill Finder** downloads an HTTPS candidate, uses a selected model to normalize it for iOS, then runs deterministic validation and compatibility checks.

Only instruction-only or read-only low-risk packages can install automatically. Scripts, network/browser access, writes, remote execution, credentials, uploads, capability expansion, and replacements require user confirmation. Scripts are visible source recipes; the App Store build does not dynamically execute them as local plugins.

## 14. Troubleshoot

- **Model not configured:** add a provider and select a default Agent model.
- **Apple Foundation Model unavailable:** read the exact reason under **Settings → Local Models**. It requires an eligible device, iOS/iPadOS 27, Apple Intelligence enabled, and the system model ready.
- **Downloaded local model will not load or terminates the app:** free device memory, unload another model and retry once. Export the newest device/Xcode or uploaded diagnostic log; do not diagnose it from an older unrelated crash.
- **Vision unavailable:** select a provider/model that advertises and implements image input.
- **Local model does not call a tool:** confirm the tool is allowed for the task and that the request names the intended action. Floe displays a capability or structured-call parsing reason when the model cannot use it.
- **Task interrupted after backgrounding:** reopen the task and use the offered safe recovery action.
- **A resumed task repeats completed tools:** stop the run and export diagnostics. A recovered run should restore its execution ledger and must not replay successful tool/argument pairs.
- **Browser says `stale`:** observe the page again before interacting.
- **Remote tool unavailable:** confirm the host, SSH authorization, task permission, and network path.
- **LAN scan finds nothing:** allow Local Network access in iOS Settings, stay on the same LAN, and retry. Discovery is limited to the Bonjour service types declared by the app and is not a general port scanner.
- **Workspace preview says it is not open:** reopen the Files inspector and confirm the task has either its private workspace or the intended project binding before opening the file.
- **Picture in Picture is black or does not start:** Floe prepares a visible progress source when the task starts and defers a background start request until AVKit reports it ready. Returning to Floe ends the active system PiP session; a later departure rebuilds and starts a fresh source. Include the PiP status and latest diagnostics when reporting a persistent black frame.
- **A Python package will not activate:** confirm it is a pure-Python universal wheel. Packages containing native extensions remain download-and-inspect only; use a trusted SSH host for native dependencies.
- **Voice fails or exits:** check microphone and speech-recognition permissions, audio route, and whether another app owns the input session.

Export a redacted diagnostics report from **Settings → Privacy & Security** when filing a reproducible bug. See [Support](../SUPPORT.md) for the report checklist and [Security](../SECURITY.md) for private vulnerability reporting.

## 15. Manage data, fonts, archives, and synced credentials

Open **Settings → Data Management** to inspect Floe's total footprint, installed app size, user data, safely reclaimable space, and categories for local models, private workspaces, fonts, attachments, generated content, browser artifacts, checkpoints, database and other data. Safe Cleanup removes only rebuildable caches and temporary items left for at least one hour. It does not remove workspaces, documents, models, fonts, attachments, the database, or credentials.

**Data Management → Archived Tasks** supports swipe-to-restore, confirmed single deletion, selected restore/delete and clear-all. The normal task list still supports swipe-to-archive.

**Data Management → Font Resources** keeps one content-addressed Floe-global copy of each imported font. Import from Files or use a direct public HTTPS URL for a TTF, OTF, TTC or OTC file up to 32 MB. Floe registers the managed library again at launch, so Word/PDF work in every workspace can reuse it without downloading per workspace. In Automatic mode, `font.list` and bounded `font.install` bypass approval-model latency; `font.remove` remains reviewed because it affects all workspaces. Apple public APIs do not permit an arbitrary web font to be silently installed for unrelated apps, so downloaded fonts are global within Floe rather than system-wide outside Floe. If iOS does not expose a requested system font, the Agent explains that boundary and installs a permitted font into Floe's managed library instead.

Task history is device-local. Configuration sync includes provider/model profiles and non-secret host profiles, while provider API keys use iCloud Keychain. **Sync saved credentials** is off by default and requires device authentication. When enabled, only credentials explicitly promoted to the vault can sync; task/workspace temporary credentials never do. A descriptor may arrive before its Keychain item, in which case the UI shows **Waiting for secret** instead of claiming synchronization completed.
