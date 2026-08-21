# Floe Agent User Guide

[简体中文](USER_GUIDE.zh-CN.md) · [Website](https://www.floe-agent.com/) · [README](../README.md) · [Security](../SECURITY.md)

This guide describes Floe Agent 1.4.5. Labels may vary slightly with the system language and the configured provider.

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

## 3. Configure auxiliary image models

Open **Settings → Auxiliary Models**. The roles are independent:

- **Vision model** reads user images and browser screenshots. Select only a model whose provider genuinely supports image input.
- **Image generation model** creates a new image from a prompt.
- **Image editing model** edits an attached or selected image.

A provider appearing in the Agent picker does not imply it supports vision or image operations. Floe disables incompatible role combinations instead of sending an invalid request.

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

Deleting data, entering credentials, uploading files, browser login/payment, and catastrophic commands always require explicit review. A Skill declaration is a maximum request, not authorization. Stop or cancel remains available while a task or remote session is active.

## 10. Background work and notifications

Leaving a task screen does not cancel its Run. Floe records checkpoints at model phases, tool boundaries, approvals, user-input waits, child runs, and partial responses. When the app returns, it reconnects to a provider job when supported or creates a recovery Run in the same task.

iOS scheduling and background execution are best effort. A notification or Live Activity opens its target task; ordinary cold launch still opens New Task. Do not assume an SSH, VNC, browser, or model stream stayed connected while iOS suspended the app.

## 11. Apple capabilities, Shortcuts and automation

Open **Settings → Apple Capabilities** to decide which compiled integrations Floe may advertise to the Agent. Calendar, Reminders, Home, Maps, Web, Watch status, vision, mail composition, documents/PDF, camera, location, Shortcuts and automatic tasks are independently switchable. These device-local switches do not grant OS permission; iOS still asks on first real use, and denial must not block the rest of a task.

Floe publishes **Run Floe Task** and **Schedule Floe Task** App Intents. Add **Run Floe Task** to a Shortcuts personal automation for a system time, Focus, arrival or other exact Shortcuts trigger. Floe's own schedule is durable but uses best-effort iOS background refresh, so its wake time is not guaranteed. The immediate intent starts a normal durable task with the default Agent model without opening Floe.

## 12. Local Python, packages and code editing

Signed builds include bounded CPython 3.13. The managed package interface may download dependencies into quarantine, but activates only pure-Python `py3-none-any` wheels after hash verification, static inspection and package review. Native extensions, Mach-O/ELF payloads, dynamic libraries, subprocess execution and sandbox escape remain unavailable. Repeated direct `pip`, shell or `subprocess` attempts are rejected with a machine-readable explanation.

Open Python, JavaScript, MJS or CJS files from the workspace to use the structured editor with line numbers, syntax highlighting, search/replace, symbols, undo/redo and bounded local execution where supported.

## 13. Install and create Skills

- **Skill Creator** builds a local declarative instruction package.
- **Skill Finder** downloads an HTTPS candidate, uses a selected model to normalize it for iOS, then runs deterministic validation and compatibility checks.

Only instruction-only or read-only low-risk packages can install automatically. Scripts, network/browser access, writes, remote execution, credentials, uploads, capability expansion, and replacements require user confirmation. Scripts are visible source recipes; the App Store build does not dynamically execute them as local plugins.

## 14. Troubleshoot

- **Model not configured:** add a provider and select a default Agent model.
- **Vision unavailable:** select a provider/model that advertises and implements image input.
- **Task interrupted after backgrounding:** reopen the task and use the offered safe recovery action.
- **Browser says `stale`:** observe the page again before interacting.
- **Remote tool unavailable:** confirm the host, SSH authorization, task permission, and network path.
- **A Python package will not activate:** confirm it is a pure-Python universal wheel. Packages containing native extensions remain download-and-inspect only; use a trusted SSH host for native dependencies.
- **Voice fails or exits:** check microphone and speech-recognition permissions, audio route, and whether another app owns the input session.

Export a redacted diagnostics report from **Settings → Privacy & Security** when filing a reproducible bug. See [Support](../SUPPORT.md) for the report checklist and [Security](../SECURITY.md) for private vulnerability reporting.

## 15. Archive tasks and sync credentials

Swipe a task to archive it. Deletion never runs as a full-swipe action and requires confirmation. Use **Task Center → Archived** to restore multiple tasks or delete selected archived tasks.

Task history is device-local. Configuration sync includes provider/model profiles and non-secret host profiles, while provider API keys use iCloud Keychain. **Sync saved credentials** is off by default and requires device authentication. When enabled, only credentials explicitly promoted to the vault can sync; task/workspace temporary credentials never do. A descriptor may arrive before its Keychain item, in which case the UI shows **Waiting for secret** instead of claiming synchronization completed.
