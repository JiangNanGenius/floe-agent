<!-- docs-updated: 2026-10-16 -->
<!-- doc-anchor: section-1 -->
# Floe Agent User Manual

[简体中文](USER_GUIDE.zh-CN.md) · [Documentation](README.md) · [Website manual](https://www.floe-agent.com/docs/en.html)

Learn to use AI tasks, Notes, Office, Drawing Assistant, Canvas and media, and local and remote development in Floe. Designed for iPad and also available on iPhone, Floe requires iOS/iPadOS 26 or later.

## Contents

**Getting started**

- [1. Installation and first use](#1-installation-and-first-use)
- [2. Models and auxiliary capabilities](#2-models-and-auxiliary-capabilities)
- [3. Tasks and workspace ownership](#3-tasks-and-workspace-ownership)
- [4. Conversation, Plan, Goal and recovery](#4-conversation-plan-goal-and-recovery)
- [5. Permissions and verification](#5-permissions-and-verification)
- [6. Files, editors and concurrent changes](#6-files-editors-and-concurrent-changes)

**Documents & creative work**

- [7. Notes: import, search and handwriting](#7-notes-import-search-and-handwriting)
- [8. Office: edit, annotate, save and reopen](#8-office-edit-annotate-save-and-reopen)
- [14. Engineering drawings and AI review](#14-engineering-drawings-and-ai-review)
- [15. Canvas, images, audio and video](#15-canvas-images-audio-and-video)
- [16. Voice input and transcription](#16-voice-input-and-transcription)

**Development & connections**

- [9. Local terminal and Linux performance](#9-local-terminal-and-linux-performance)
- [10. Python, Node, packages and code execution](#10-python-node-packages-and-code-execution)
- [11. Git and GitHub Actions](#11-git-and-github-actions)
- [12. Remote hosts, desktops and diagnostics](#12-remote-hosts-desktops-and-diagnostics)
- [13. Browser, web previews and login](#13-browser-web-previews-and-login)

**More tools & help**

- [17. Skills, MCP, mail and automation](#17-skills-mcp-mail-and-automation)
- [18. Background work, PiP, notifications and data](#18-background-work-pip-notifications-and-data)
- [19. Temporary chat (RAM-only)](#19-temporary-chat-ram-only)
- [20. Troubleshooting](#20-troubleshooting)
- [21. Useful feedback](#21-useful-feedback)

<!-- doc-anchor: section-2 -->
## 1. Installation and first use

![The iPad home screen: choose a task in the sidebar or start from the central composer.](assets/guide/home.jpg)

*The iPad home screen: choose a task in the sidebar or start from the central composer.* Check the model and workspace before sending your first request.

1. Prefer TestFlight when you have access to a test group. Check its build number, expiration and What to Test.
2. For GitHub or Feather/AltStore delivery, follow the installation instructions on the release page. The GitHub developer IPA is unsigned and requires your own signing method; it is not a TestFlight package.
3. Complete onboarding. Use the sidebar on iPhone and multiple columns on iPad; editors can open full screen.
4. Core Notes, file organization and Canvas do not require an AI provider. Connect your provider before requesting AI work.
5. Find the installed version in Settings → Diagnostics & About and include it in feedback.

For a first task, configure a model, create a test conversation, attach a synthetic text file and request a summary. Inspect tool receipts and open the output file. Use sample material before important documents.

[↑ Back to contents](#contents)

<!-- doc-anchor: section-3 -->
## 2. Models and auxiliary capabilities

<!-- doc-anchor: section-4 -->
### Cloud providers

Open Settings → Model Providers. Add the endpoint, wire protocol, actual model ID and API credential supplied by your provider. Test the configuration, enable both provider and model, choose the default Agent model, then verify the model label on New Task.

Provider and model names may contain hyphens, underscores and version dots, such as `qwen3.5-plus` or `model_v2.1`. Keep the actual model ID exactly as supplied. Provider display names normalize pasted line breaks and incidental invisible formatting while preserving meaningful Unicode; oversized names report their UTF-8 size.

If a model is missing, check provider/model switches and “Hide from main model list.” Hiding preserves auxiliary uses; disabling prevents new selections. Provider calls may incur third-party charges. Credentials belong in Keychain, never project files, screenshots or public issues.

Floe validates the form before it writes anything. An invalid field is reported in your language, no write starts and the form keeps its content. A local save and an iCloud upload are reported separately: “Saved on this device; iCloud sync is pending” means the configuration is committed locally and the upload can be retried — it is not a failed save, and you do not need to re-enter an API key. Remote records that fail validation are skipped while the local copy is kept.

In Add text/image/video, tap the **Provider** field itself to open ONE searchable selector: the built-in provider presets (including an explicit manual/custom choice) and the verified catalog entries live in the same list and are filtered together as you type (aliases and configured badges included). There is no separate preset row, no "add from catalog" button and no separate catalog page. Choosing an entry closes the selector and preserves everything else you already entered, including a custom display name. Selecting a vendor that genuinely supports more than one service role raises a one-time **Additional uses** prompt where the role you started with is fixed and every extra role is opt-in; choose **Configure**, **Not now**, or dismiss the sheet — a declined role is not offered again. Extra roles share this connection's endpoint and API key only when the origin, protocol family and auth style really match; a different origin is shown as **Configure separately** with its own visible settings. Changing the connection identity (scheme/host/port/provider family/auth style) clears the typed key and refuses to silently reuse a stored key across connections.

Catalog metadata is verified per model, not promised for a whole provider. A model you add now starts with the capabilities the bundled catalog actually verified for it (for example image input for a vision-capable model). Models you saved before that metadata existed are never rewritten silently: Floe offers a one-time **Model capability updates** review that lists each model and the exact capability it would gain (**Before → After**) and writes nothing until you choose **Apply updates** (or **Not now**). A capability you set yourself is recorded as your own decision — a later catalog refresh or iCloud sync never flips it back, and a capability you switched off stays off. "Supports text/images/video" describes the roles the catalog verifies for that entry, not a tested live inference: the first real request is still the compatibility check. GitHub Copilot, Azure, Amazon Bedrock and Google Vertex are not offered when adding a new provider — Floe cannot execute them without OAuth or deployment-scoped endpoints — but connections you already saved to those providers stay listed and editable.

Models that support it also carry a reasoning/thinking effort setting. With **Automatic**, Floe asks your configured auxiliary text model once when a fresh round starts to choose an effort for that request; the decision is kept for the round, including guide/steer and continuation messages, and is not reclassified mid-round. A manual effort you choose is never changed. If no auxiliary model is configured, or the helper fails or times out, Floe falls back to the model's own supported default.

<!-- doc-anchor: section-5 -->
### Vision, generation and image editing

Settings → Auxiliary Models configures image understanding, image generation and image editing separately. Text support does not imply any of these capabilities. Attach the source image before requesting an edit.

<!-- doc-anchor: section-6 -->
### Apple and downloaded models

Apple's system model is managed by the OS. Follow the availability reason shown by Floe: device support, Apple Intelligence settings or model readiness. Floe has no download button for that system model.

Downloaded MLX models are Beta. Download, load and inference are separate stages; start with short text before multi-turn work. The local path uses text and bounded OCR of attachments, not semantic image understanding. Linux guests and local models share device memory. Review any request to release resources; cancelling does not authorize stopping another task. Disabling keeps files; deleting removes downloads. Preserve current diagnostics after a crash instead of clearing all data.

[↑ Back to contents](#contents)

<!-- doc-anchor: section-7 -->
## 3. Tasks and workspace ownership

On New Task, check the model, project, execution target, Skills and permissions before sending. With no project, Floe creates a private task workspace; with a project, file actions belong to that project. Attach necessary material and state the outcome, format, location and completion criteria.

Example: “Read this attachment, create a one-page summary and action list in the current workspace, and give me links to the finished files.” The draft becomes a continuing task. Later messages use the same task context.

Authorize external folders through the system file picker; writing a path in chat does not grant access. Deleting a private task may remove its private workspace. Deleting a project task differs from deleting project files. Export important results first. Notes stores its own documents independently of chat deletion.

[↑ Back to contents](#contents)

<!-- doc-anchor: section-8 -->
## 4. Conversation, Plan, Goal and recovery

| Mode | Purpose | What to do |
| --- | --- | --- |
| Agent | Execute work | State the outcome; inspect permissions, tools and files |
| Plan | Discuss a proposed approach | Review and accept it before treating any step as executed |
| Goal | Work across stages | Define steps, budget and completion evidence |

Return inserts a new line; Command+Return sends where supported. Expand the composer for a long prompt; it edits the same draft. Messages during a run can correct requirements without creating another task.

After background interruption, return to the original task, inspect the last tool receipt and use Resume or send “Continue.” Verify uncertain uploads, submissions or other side effects before repeating them. Returning to the foreground does not mean an old process survived. A bounded pause or an unknown side-effect outcome needs deliberate recovery: inspect or reconcile the last receipt, then resume. A read-only check alone does not automatically re-arm paused work.

Scroll up to read history without following new output; return to the bottom to resume following. Long-press (or right-click) a task to open **Manage Tasks** with it selected, or use **Manage** on Home; the same screen opens from Settings → Data management → Manage tasks. Selection and Select All apply only to the tasks visible under the current filter and search. Archiving asks for confirmation, states that it stops the selected tasks' own running work first, and archived tasks can be restored later from the same screen (switch to Archived) or the archive list; deleting also stops their own work and removes each task's private workspace while shared project files stay. Each task reports its own result — failed or unverified tasks stay selected for retry — and a running batch can be stopped without touching unprocessed tasks.

[↑ Back to contents](#contents)

<!-- doc-anchor: section-9 -->
## 5. Permissions and verification

Tool cards show the progress and results of actions. Review the target and effects when a permission request appears.

1. Expand a tool card and inspect its target, workspace and result.
2. Review the object and side effect before allowing a permission request.
3. Open generated files. For editable documents, save, close and reopen.
4. Check remote command exit codes and host identity. “Started” is not “completed.”
5. Report what actually happened with redacted evidence when an outcome differs.

Ordinary Office, PDF, image, video and CAD edits within the task’s authorized local scope can proceed without a confirmation for every step. Revision checks, recoverable saves and output verification still apply. Writes into a code repository, unresolved targets, explicit destructive overwrites, external sends and protected PDF actions retain their applicable review or consent. A request to preview or review a proposal still waits for adoption.

Routine commands in the task’s resolved local Linux guest receive fewer repeated reviews; this does not treat the Mac host as a disposable guest. Risky remote-machine changes remain subject to the existing review policy. Shared guest sessions keep separate ownership and cancellation, and stopping or resetting an environment is a separate operation.

Documents, websites, tool results and memory cannot grant new permissions. Never follow embedded instructions to expose credentials or broaden access.

Delegated subagents run with the same effective permissions as the current task: the explore/research/execute choice is a focus hint, not a permission level, and every child call goes through the same approval, workspace, environment and mutation-serialization path as the main task. A subagent can never delegate again or create a new user-visible task — `delegate` and `conversation.spawn` are main-task-only and are refused at execution time, not merely hidden. Sibling subagents of one task may exchange bounded messages; a message is untrusted data, never a permission grant, and cannot restart a subagent that has finished.

A subagent can independently use `tools.list` / `tools.search` and `skill.list` / `skill.search` / `skill.read`. It loads the tools and workflow instructions needed for its task instead of receiving the entire tool catalog in every request. Skills can guide scripts, native tools and configured MCP use within the same task permissions; reading a Skill does not grant new permissions. Known tools do not require a guide to be read first.

Several task clients — the parent run and its children — may share one Linux environment through separate processes and execution sessions. Results, working directories, standard input/output and cancellation belong to the requesting session: cancelling one child does not stop the other consumers, and stopping the whole environment is a separate lifecycle action. Writes to the same known target follow the same coordination as ordinary task edits.

[↑ Back to contents](#contents)

<!-- doc-anchor: section-10 -->
## 6. Files, editors and concurrent changes

![A Markdown file opened beside its task and file list.](assets/guide/workbench.jpg)

*A Markdown file opened beside its task and file list.* Open the output in the file panel, inspect its contents, then save and reopen it.

Browse the task/project file panel, open text in the editor and save before running or sharing. Review conflicts: non-overlapping changes may merge; overlapping edits need a decision. A recovery copy does not mean the original was saved.

For text, resolve save errors before running. For Office, preserve and compare both versions. Notes can keep conflicting content as a recovery document. Keep Recovered Edits until the accepted file has been checked. Archives have bounded preview/extraction and format limits; their contents are untrusted. See [concurrent editing](FLOE_CONCURRENT_EDITING.md).

[↑ Back to contents](#contents)

<!-- doc-anchor: section-11 -->
## 7. Notes: import, search and handwriting

![Notes showing a workshop PDF with handwriting and annotation controls.](assets/guide/notes.jpg)

*Notes showing a workshop PDF with handwriting and annotation controls.* Open Notes from the sidebar, import a sample PDF, and try a short pen stroke before editing an important document.

Open Notes from the sidebar, then use + to create or import. For task files, select Import from Floe Workspace, choose the project or task, then the file. Check pages, text and attachments after import. The Notes copy is independently stored, not a live mirror of the source.

Search titles and document text from the library. Snippets help identify a result; unfinished indexes can omit matches. Use the document menu to rebuild the text index when needed. Tabs switch documents; closing a tab does not delete its document. Select an in-document search result to jump to its page and highlight matching text. Some PDFs support page-level navigation only.

Select pen, highlighter, eraser or lasso. Tap the current pen or color again to change type, color, width and transparency. Five dots from small to large offer quick widths; use the slider for fine adjustment while the stroke preview updates. PDFs imported into Notes use these same writing settings. When the UI says transparency, 0% is solid and 100% is transparent. Make a short test stroke. Pencil squeeze/double-tap depend on hardware and system settings; finger drawing is separately enabled. Lasso manipulates content; AI selection provides context.

Check save status before closing or switching. Use Trash for recovery and review attachments before permanent deletion. The document assistant has its own conversation. In ordinary chat, explicitly add Notes material and revoke access when no longer needed. Review assistant edits on the page and use Undo when appropriate. The assistant previews edits for your confirmation; applied changes can be undone. Export selected pages or the whole document to PDF, or save a portable `.floenote` archive. Editing original PDF text and converting handwriting to editable text are not supported.

Saving an Office document in Notes updates its automatic cover from the saved content, including ink on the first page. Opening an existing document in preview mode also fills in a missing cover. A custom cover keeps priority. If the preview cannot be updated, choose **Update preview** to retry; the saved document and ink remain intact.

**Document covers.** A Notes document can use a custom cover instead of its generated preview: open the document menu and choose **Set Cover** or **Change Cover** to use a photo or a file, or **Restore Automatic Cover** to go back. The cover is independent of the document body: setting or restoring it does not change the content revision, does not enter the undo history and never modifies the original Office/PDF content, and the previous cover image is not discarded while other data still references it. The Notes assistant has the same cover action for a document selected for that task (`notes.cover`, read / set / restore): read reports the cover state, while set and restore carry the expected document revision and cover revision from a previous read, so a stale attempt is refused instead of overwriting a newer cover, and only images referenced by the selected document or files authorized in that task's workspace can be used. Unusable images are rejected and the previous cover stays. A `.floenote` archive containing a custom cover is refused by older Floe versions that do not support covers, rather than imported incompletely.

**Reading mode.** Text files and text-only Notes documents have an alternate read-only **Reading Mode** of the same file; the original is never changed and its editor stays available. Reading mode offers text size, line spacing, column width, appearance (including a warm-paper theme), a contents list and in-document search, and restores your last reading position only when the file still matches (files in a task's private workspace keep no position). It shows text only — a notebook with ink or images is read as text while those stay untouched. Encoding is detected automatically (UTF-8, UTF-16 and, when the platform provides the codec, GB18030); when detection is unclear you can choose Automatic, UTF-8, UTF-16 LE/BE or GB18030 (only when available) manually, and a choice that cannot decode the whole file is refused instead of showing replacement characters. Files over 64 MiB are refused rather than partially loaded, and very long files may stop showing line numbers once the line index is full. Other formats keep their existing native viewers (PDF, Office, CAD, images, media) — reading mode never converts them into text.

[↑ Back to contents](#contents)

<!-- doc-anchor: section-12 -->
## 8. Office: edit, annotate, save and reopen

1. Open a DOCX, XLSX or PPTX file, wait for it to load, then enter editing.
2. Edit according to the format: Word supports styles, lists, alignment and tables; Excel supports cells and formulas, formatting, rows and columns, freeze panes, sorting and filtering; presentations support slide duplication, reordering and object alignment.
3. Tap the toolbar pen button to write with Apple Pencil. In **Pen settings**, choose **Pen**, **Marker** or **Highlighter** and adjust color, width and transparency. Five dots from small to large offer quick widths; use the slider for fine adjustment with a live stroke preview. Tap **Done** to close settings and keep drawing; tap the pen button again to return to ordinary editing.
4. For AI edits, review the preview and confirm to apply. Save your manual edits first.
5. Save and wait for completion. Export the file when ready to share.

Available operations depend on the file format; unavailable options explain why. If loading or saving fails, keep the original and check the error. Compare conflicting versions before saving.

An AI edit that was not confirmed in the editor can still run as an authorized automatic copy: only after the task's runtime approves that exact tool call, the engine works on an isolated copy and publishes a new `<name>.edited.<ext>` — the original is never overwritten, the output is reopened and verified (formula cells check their persisted cached value/type/error), and an existing different file at the output path is refused. A user-confirmed edit (the editor's confirmation) keeps its existing path. Long Office/media work can be submitted as a background job: the job freezes the workspace, revision and command payload at submission, reports real progress, keeps running when you close the page, and cancellation only becomes terminal after the processor acknowledges and cleans its staging.

[↑ Back to contents](#contents)

<!-- doc-anchor: section-13 -->
## 9. Local terminal and Linux performance

task tools → Terminal → Local Workspace, with Remote SSH in the same panel. Confirm workspace ownership before commands that modify files.

Open the local terminal, install and verify the Linux image if prompted, and begin with read-only `pwd` and `ls`. Ask the assistant to inspect Linux status and choose cores/memory before its first shell call. Example: “Inspect Linux, select two cores for parallel compilation, start it and verify the actual core count.” Check granted resources in the receipt.

| Work | Suggested cores | Constraint |
| --- | --- | --- |
| Inspection, light commands, small server | 1 | Avoid unnecessary resource use |
| Parallel compilation or CPU workers | 2–3 | Work must benefit from parallelism; check memory separately |
| Concurrent guests | Up to 4 total | 3+1, 2+2, 2+1+1 or 1+1+1+1 |

One guest uses at most three cores. Three cores require a verified image; older images can remain limited to two. A four-core pool does not guarantee two guests on every device: memory and existing work still control admission.

a successful launch saves its core/memory configuration for later resumption. Choose explicitly on first start. Changing an active guest may require a hard restart that interrupts commands/services. App upgrades prefer reusing valid local images; missing, damaged or incompatible images need appropriate repair. Do not delete environments as the first troubleshooting step. Stop unneeded services after work; closing a panel does not necessarily terminate its shell.

<!-- doc-anchor: section-25 -->
### Web services and full-screen terminals

Open a workspace `.html` or `.htm` file and choose **Run** to preview the page and its nearby resources. For a `.py`, `.js` or `.sh` HTTP server, choose **Run as web service**. Confirm the owning task and port, or create a run task when asked. Server scripts should read `PORT` and listen on the guest network interface; static pages need no server code. **Preview** appears after the page responds. Check logs if startup fails. Closing the window keeps the service running; use **Stop** or the environment's local-service list to end it. Restart the service after the app is terminated.

Use the terminal status bar's expand button for full screen, then Hide to return without ending the session. Run terminals explicitly report when the process has not written output and show exit status.

Use ordinary Run for scripts that are expected to finish. Choose Run as web service for HTTP servers so you can inspect readiness, preview and stop them separately. Logs alone do not prove the port is ready. If a port is occupied, inspect existing services before starting another; resolve task/workspace errors instead of retrying in a different directory. Full-screen and embedded terminals share one session; hiding the window does not explicitly terminate it. Ctrl-C interrupts the foreground command.

<!-- doc-anchor: section-28 -->
### Terminal and ports

The terminal toolbar includes font size, copy output, paste, clear screen, Ctrl-C, Tab, Esc and arrow keys. Clear screen keeps the process alive; ending the session closes it. Scrolling up stops following output. Oversized input prompts you to paste smaller sections.

Choose the environment in port management before adding or editing a rule. The guest port is the Linux service's listening port; an empty requested host port uses dynamic allocation. Conflicts may change the actual bound port, so copy the currently available address. **Allow this device only** binds to loopback; disabling it permits LAN access.

A saved rule is not a live listener. The VM must be running and the service must listen on the guest port. Stopping the VM retains rules but makes their addresses unavailable. The agent should list rules before using `linux.port` to modify its scoped environment. Forwarding alone is not evidence that a web service started.

[↑ Back to contents](#contents)

<!-- doc-anchor: section-14 -->
## 10. Python, Node, packages and code execution

Settings → Execution Environments → choose project/task → Python·PyPI or Node.js·npm. Confirm the environment before installing; project and shared dependencies have different write locations.

Local Python/Node primarily run inside Linux. Packages must support that guest architecture; desktop/macOS/iOS binaries are not interchangeable. In the full IDE, Run shows the target and command. Resolve save errors/conflicts first. Remote single-file execution does not synchronize the entire project and requires the remote runtime, dependencies and assistant service where applicable.

Use `pip list`, `python3 --version` and `node --version` to verify real state. Check network and package compatibility after installation failures. See [local shell](ARCHITECTURE_LOCAL_SHELL.md) and [IDE/languages](FLOE_IDE_AND_LANGUAGES.md).

[↑ Back to contents](#contents)

<!-- doc-anchor: section-15 -->
## 11. Git and GitHub Actions

Open Source Control in the file inspector. Confirm repository and branch, inspect each diff, stage intended files and commit. Check remote/branch before pushing; resolve conflicts instead of treating failed sync as success.

Connect an account in Settings → GitHub & Source Control using device authorization or a token kept in secure storage. In IDE Run → GitHub Actions, choose repository, branch and workflow; inspect the file snapshot before submitting. Installing a workflow template writes to the repository and requires an explicit action.

Read status, logs and artifacts in the run panel. Closing the App does not cancel GitHub work; cancellation needs server confirmation. Linux/macOS build outputs are not iOS executables. Recovery copies are not long-term backups. See [cloud builds](IDE_GITHUB_ACTIONS.md).

[↑ Back to contents](#contents)

<!-- doc-anchor: section-16 -->
## 12. Remote hosts, desktops and diagnostics

Configure devices in Settings → Hosts & Remote Sessions. SSH, VNC, SSH-tunnel VNC, Telnet, TCP and BLE GATT are separately configured capabilities. Naming a host does not establish a connection.

“As a remote execution environment” controls the assistant-service setup path; a management-only host should not be forced through it. Verify host identity, directory and authentication. Telnet/plain TCP are unencrypted; use trusted networks or an existing secure tunnel.

Diagnose in order: reachability, DNS, port, authentication, then command/directory permissions. Query a long command using its returned task ID instead of launching it again. Temporary connections differ from saved hosts. BLE GATT support is not arbitrary classic Bluetooth serial support.

Bluetooth initializes only when you explicitly scan or connect. A GATT UUID must be 4 or 8 hexadecimal digits, or a standard 128-bit UUID; malformed input returns an error before the system Bluetooth API.

[↑ Back to contents](#contents)

<!-- doc-anchor: section-17 -->
## 13. Browser, web previews and login

Inspect actual URLs and actions in the task browser/tool receipts. Perform required login or human verification on the visible page; do not store secrets or codes in the workspace.

A local preview serves current workspace files. Server startup, page loading and usable page behavior are separate checks. External assets, cross-origin requests and network policy can affect rendering. Browser sessions do not supply SSH credentials. See [browser protocol](FLOE_BROWSER_PROTOCOL.md).

<!-- doc-anchor: section-26 -->
<!-- doc-anchor: section-27 -->
### Browser takeover and return

The address field shows the real URL, including the scheme, host, port and path of local pages. Edit it directly or copy it from the menu. Full screen retains the same tab, page and form state.

During takeover, the agent may continue analysis and other authorized tools, but cannot click, type or navigate the browser. Choose **Return to agent** when finished. **Original task notified** means the original task's input channel accepted the notification, not that the subsequent work is complete. The agent must observe the page again before acting. A finished task offers **Continue task** instead of restarting silently. Retry a failed notification; do not create a replacement conversation. The notification excludes passwords and form contents.

[↑ Back to contents](#contents)

<!-- doc-anchor: section-18 -->
## 14. Engineering drawings and AI review

Open a supported DXF/DWG, mesh or PCB manufacturing file and wait for actual content. Open Full Screen Preview and inspect layers, zoom and orientation. Preserve the original and error message if rendering fails.

Editable local DXF/DWG files expose Edit for selecting entities and adding lines, circles, arcs, polylines, text, dimensions and leaders, with layers, object snap, measuring, trim/extend/offset and numeric move/copy/rotate/scale/mirror. Check save/reopen on a copy first. CAD and Office drawing tools differ; format preservation and pen behavior depend on the actual engine/output. Save re-encodes and re-verifies the drawing before overwriting; 3D entities, blocks, xrefs, splines and proxy content stay read-only and are never flattened. Undefined units stay drawing units. Editing a drawing is not native 3D modeling: only Canvas 3D model nodes (§15) open the 3D workbench, and not every 3D file can be edited.

Open **Drawing Assistant** to ask about the current drawing or selection, measure and inspect geometry. It can locate and highlight entities and show additions, changes and deletions in color. Review the preview and confirm to apply; changes can be undone. Save manual edits before applying a proposal.

For native `.floecad` work (the 3D workbench's drawing and assembly services), the assistant must name the operation it wants — for example `drawing.addPage` or `assembly.addInstance`. A request without a recognizable operation now fails with a clear structured error that lists the known operations, instead of silently falling back to a read; a close guess is answered with a suggestion such as `Did you mean 'addPage'?`. When exact arguments are unclear, ask the assistant to use `capabilities` discovery for that service (`drawing`, `assembly`, `script` or `mesh`) — the full operation catalog is served on demand and paged, not loaded into every request. Mutating drawing/assembly changes keep the ordinary propose → apply path under the task's own authorization (no extra per-edit workbench grant for an ordinary authorized document), and a drawing PDF/SVG/DXF export needs the page id returned by a drawings query. The engineering chain is page → project → save → export: accept a result only after the real engine has saved and reopened it, and only for export formats the engine actually writes.

<!-- doc-anchor: section-30 -->

[↑ Back to contents](#contents)

<!-- doc-anchor: section-19 -->
## 15. Canvas, images, audio and video

![A populated Canvas with images, text and a document in one workspace.](assets/guide/canvas.jpg)

*A populated Canvas with images, text and a document in one workspace.* Select an object to inspect or edit it. Review each generated asset before exporting.

Create a canvas in Creative Mode, add text/images/generation nodes, connect inputs and check the chosen model's capabilities. Open the generated asset from its node to preview it.

In the media workspace, select a file, configure crop, trim, subtitles or export format, preview and export. Play the output to check duration, audio, captions and framing. Preserve originals. Image generation, image editing, video generation and local conversion are different capabilities with different providers/quotas. See [Canvas architecture](CREATIVE_MODE_AND_ASSET_ARCHITECTURE.md).

Double-click a `.dwg` or `.dxf` drawing node to open its drawing editor. Finish updates the original node; Make Variant creates a new node. Unsaved edits remain as a draft when you close the editor and can be resumed on reopening. Entering full screen re-parents the same live session — undo history and unsaved edits are preserved. Canvas backups include media projects, assets and CAD drafts.

<!-- doc-anchor: section-29 -->
### Media workbench: projects, editing and export

The image and video editors are now one workbench, opened from the Files tab,
the workspace file preview and Canvas. On a wide landscape iPad it shows
assets/layers on the left, a large preview in the centre, properties on the
right and the video timeline at the bottom; portrait iPad, narrow split views
and iPhone show a large preview with the panels in drawers so the preview is
never squeezed into a strip.

- **Images**: crop, move, scale and rotate; manage layers, add text or drawing, adjust color, blur, sharpen, mosaic and filters. Use rectangle, ellipse or lasso selections, then add, subtract, invert, feather or create a mask.
- **Video**: add clips to the main track, trim, split, reorder, change speed or adjust framing. Add music, volume changes and fades on the music track. Add captions manually or transcribe a selected clip. Hard cuts and cross-dissolve transitions are available.
- **Save and resume**: projects save automatically. Use the toolbar folder button to open saved projects with their layers, timeline and edit history. Opening the same source again lets you resume editing or start a new project.
- **Save failure**: your current edits stay open. Retry **Save project**, keep editing, or explicitly discard unsaved changes. Close completes after the current edits are saved; discarding keeps saved versions and source assets.
- **Export**: choose PNG, JPEG or HEIC for images, with size and quality options; choose H.264 or HEVC for video, with resolution and frame-rate options. Files go to `Workbench/Exports` in the workspace. Use Share / Save to Files after export.
- **AI**: open the AI drawer, choose your assets and model, then review parameters and costs before submitting. Accept a candidate to add it as a new layer or clip; you can still undo it. Jobs and candidates remain after closing the workbench. If generation is interrupted, check its status before resubmitting a paid request.

### Frame interpolation and super resolution

`video.interpolate` and `video.superResolution` (listed with the rest of the surface by `media.capabilities`) run through one shared processor; the result reports the effective engine and measured counters after re-opening the output, and a failed or cancelled run leaves no destination and never modifies the source.

- **`quality`** uses Apple VideoToolbox frame-rate conversion / super resolution. **`lowLatency`** uses the low-latency variants (interpolation is 2x only). **`coreml`** uses an installed RIFE 4.25 Lite or Real-ESRGAN x2plus/x4plus bundle. **`metalFX`** is a GPU spatial upscale, not learned super resolution; MetalFX interpolation is rejected with a reason.
- `overwrite` defaults to off: an existing output is refused unless you explicitly pass `overwrite=true`; even then the replacement is staged and atomic. HDR (BT.2020/PQ) and alpha sources are rejected with an explicit reason rather than converted silently.
- A Core ML model is reported `runnable` only after Floe re-hashes every bundle file and runs one bounded fixture inference (or revalidates a cached qualification whose bytes, version and runtime marker still match). Installing a bundle alone reports “not qualified” and never runs silently.
- Availability is host-specific and is reported separately: VideoToolbox frame processing runs on macOS qualification hosts and is expected on physical devices, but Apple's frame-processing headers do not support the Simulator. Core ML inference is verified on macOS and still pending physical-iPad acceptance. Do not read a macOS result as a physical-device result.

### 3D models: one unified workbench

Within a canvas, Floe has one 3D creation entry: open the bottom insertion menu (**+ ▸ 3D Model (unified workbench)**). It creates a native `.floecad` node owned by the canvas and opens the same full-screen workbench used by File Preview. **3D Panorama** stays a separate viewer node for panoramic images.

- **Edit**: double-click the node or use its edit action. The workbench works on the same live document session; **Done** closes it. Closing does not change the canvas node — **Apply to canvas** writes the updated model back to the original bound node (id, name, position, size and connections are kept), and **Make variant** creates a new node while the original stays unchanged. If the document is not bound to a node yet, **Add to canvas** asks you to pick the destination canvas; Floe never guesses one. If you opened the document from File Preview and more than one node references it, Floe refuses to guess and asks you to open it from the intended canvas node.
- **New model: Cancel vs Save & Keep**: when the bottom **+ ▸ 3D Model** entry creates a model, the workbench opens with **Cancel** and **Save & Keep** until you accept it. **Cancel** removes the just-created node and its on-device document when you have not edited it — no empty node or orphan file is left behind. If you already edited the draft (or its bytes can no longer be verified), **Cancel** keeps it as a recoverable draft and says so. **Save & Keep** keeps the valid document and the node binding; it is a save/keep action, never a discard.
- **Legacy 3D scenes**: existing 3D scene nodes keep a read-only preview and are converted only when you explicitly open one for editing. The **3D scene migration** sheet then shows the known visual differences before the workbench opens.
- **What conversion keeps**: node id, name, position, size and connections; per-object transforms, materials and hidden state; camera, lights and background. The five legacy primitives (rounded box, sphere, cylinder, cone, thin plane slab) become real meshes in the workbench's millimetre units (legacy metres ×1000). No fake parametric feature history is invented.
- **Recoverable original**: the exact legacy scene and the whole node are backed up on this device before conversion. Keep the app data until you have checked the converted model.
- **Known differences**: lighting intensity is normalized to the workbench scale (exact values stay in the backup), and shadows use a planar ground projection instead of the legacy shadow map.
- **If it cannot convert**: nothing is written. The sheet lists the exact unusable values (for example a non-finite number, a zero/negative or out-of-range scale, an invalid colour, camera or light, or duplicate object ids) and the node keeps its read-only preview.

See [unified 3D and design migration](FLOE_UNIFIED_DESIGN_MIGRATION.md) for the step-by-step conversion and recovery notes. Imported DWG/DXF drawings are not native 3D models: only their 2D entities are editable.

### Design workflow from four entrances

The same design workflow (brief → spec → frozen input → candidate → adopt/reject/variant → verified export) is available without creating another workspace:

1. **Creative start**: Canvas home → Quick Start. In builds up to 1.7.30 (271) this opens the design request entry; the next unreleased update replaces the type-selection menu and mandatory brief form with a natural-language start in the same task (see the note below). Saved requests, specs and candidates are preserved either way.
2. **Current file**: open a workspace file in File Preview → **Design workflow**. Live workspace files only; cloud/network copies are read-only and have no design owner.
3. **Chat attachment**: long-press (or right-click) a message with a file or image attachment → **Design from this attachment**. The adopted result returns as a new attachment in that same original task; the original attachment is never modified.
4. **Canvas node**: canvas view menu (⋯) → **Design workflow** — the existing Canvas panel.

> **Next update (unreleased).** The next source update starts a design in ordinary natural language from the same task: describe what you want, with no type menu or mandatory goal/audience form, and continue with follow-up messages. It distinguishes three kinds of work — **create** a new result, **modify** within a frozen revision while keeping everything outside the scope, and **restructure** (which first asks what content, data, behavior and format must be preserved before anything is regenerated). Candidates are shown for preview/comparison and only adopt after you confirm; a revision conflict keeps your manual edits and never silently overwrites, and results for a chat attachment return to the original task. This update is not released; it has been built and locally verified (2026-10-14: full App build, changed App suites, a live-model design loop and the entry UI test), while fine-grained GUI acceptance is still in progress — the entry above and the checklist below describe the installed behavior.

What to check in the panel:

- Save the brief/spec, then **Freeze current source** so later edits cannot change what a run is based on.
- A creative request starts with one goal/audience editor and one **Save request** action (the requested output type is shown in human-readable form). The request is stored before any material exists; the brief and spec stay editable after saving, including while the first result is pending, and later edits still cannot change an already frozen run.
- Candidates are proposals. **Compare** shows the bounded diff; **Adopt** updates the source in place where Floe may write it, or returns new content for read-only sources. **Reject** leaves the source unchanged; **Restore previous revision** appends a recovery revision instead of overwriting history. For a restructure, check the preservation list item by item before adopting — the tool is not allowed to replace the original before your confirmation.
- Assistant adoption needs your explicit confirmation in the panel (**Authorize assistant (update original / variant)**): a single-use grant bound to that candidate and mode, delivered to the originating task only. The assistant itself cannot approve a change; a target with no originating task offers the direct adopt instead. If the app restarts before the assistant uses the confirmation, or a claimed attempt fails, confirm again — the grant is single-use and is not silently re-armed.
- Anchored feedback resolves only against a real, verified content change — text alone does not complete it. If the source moved after freezing, use **Relocate anchor** and review the conflict; nothing is overwritten silently.
- First-result generation is offered only for capabilities that are actually connected (for now, image generation when a model is configured). A type without a real route shows an honest, localized reason instead of a dead button; for image output with no configured model the panel points to Settings → Models. No result is promised for output kinds Floe cannot generate. If a generation outcome is unknown, Floe does not resubmit it automatically — discard the unknown attempt explicitly to start a new one. If a published result can no longer be read on this device, the request shows an explicit missing-result state and offers only an acknowledged replacement (a new provider request that may be charged) or an acknowledged discard; a bind is never claimed from the stale record. Stopping a generation before the provider call is reported as a definite cancel (nothing was generated); only a stop after dispatch is an unknown remote outcome. A result generated while the design changed is retained and can be bound to the current revision.

See [design workflow](FLOE_DESIGN_WORKFLOW.md) and [design workflow tool contract](DESIGN_WORKFLOW_TOOLS.md).

[↑ Back to contents](#contents)

<!-- doc-anchor: section-20 -->
## 16. Voice input and transcription

Tap the chat microphone, grant OS permission and wait for preparation before speaking. Check waveform response, stop, review transcription and then send. Noise, mixed languages and names may require correction.

If startup remains grey/unresponsive, stop and retry once. If it fails again, record the time, device, audio route and build. Manage recognition resources in Settings; choose resources suited to your language.

Live input, file transcription and video subtitles are separate paths. Check text and timing after SRT/VTT/JSON export.

[↑ Back to contents](#contents)

<!-- doc-anchor: section-21 -->
## 17. Skills, MCP, mail and automation

Skills supply methods; installation/enabling does not grant file, network or account access. Use only needed skills and inspect source/version. MCP tools depend on configured, available servers.

After connecting mail, verify account/folders read-only before sending. Check recipients, subject, body and attachments. See [mail](MAIL_CONNECTOR.md) and [Skill Hub](../skill-hub/README.md).

Scheduled tasks live on Home under **Scheduled** (**Schedule task** adds one). Cadences are once, daily, weekly, a fixed interval, or **after a selected task run succeeds** — the last one fires exactly once for that run and does not follow the task forever. A schedule stores the model, workspace, environment and permission policy chosen when you create it, and every execution revalidates them before it runs; the assistant cannot grant itself extra authority through a schedule. iOS decides whether Floe may run in the background: when it is allowed, the due task starts automatically; otherwise the occurrence stays **Pending (waiting for the app to run)** and a notification reminds you to open Floe. That notification is a reminder, not proof of execution — check the schedule's history and the task's own run record. Missed repeats coalesce into the latest occurrence, and each scheduled row offers Run now, Enable/Disable and History.

Mail search and organization: `mail.search` is read-only and pages with an opaque cursor bound to the account, folder and mailbox version (UIDVALIDITY) plus the exact criteria — repeating a page with a changed account/folder/criteria fails loudly instead of returning wrong messages. `mail.move` (move/archive/trash, one message per call) requires approval, never issues a global EXPUNGE and never deletes permanently; POP3 accounts report these operations as unsupported instead of pretending. If the connection drops after a mutating command, the next attempt first reconciles read-only and reports whether the action actually completed.

Long mail bodies can be read to the end with `mail.read`: continue text and HTML separately using the returned cursors. Each page checks that it still belongs to the same message content; changed content requires starting again. When retrying a move, keep the same `requestID` so Floe can recover its receipt before looking for the original message. A completed mailbox change with an unsaved local receipt is reported explicitly; it must not be repeated as a new move.

Calendar and reminder lists (`apple.calendar.list`, `apple.reminders.list`) accept `limit` 1–200 (default 100) and return a task-owned cursor with `hasMore`/`nextCursor`/`snapshotTime`; a cursor from another task or filter is refused with an explicit error, never an empty success, and permission is re-checked on continuation. Calendar rows keep a per-occurrence identity for repeating events. Updating or deleting a repeating event requires that exact listed occurrence; the default affects only that occurrence. Changing this and future occurrences requires an explicit `futureEvents` scope. A stale or mismatched identity is refused before writing.

Web search results (`web.search`/`web.searchAI`) are search-index metadata, not page verification. Titles, URLs, excerpts, source/profile and index dates are returned as the provider supplies them; `pageAge` is “published OR last modified”, with relative age and crawl date kept separate and never relabeled as a publication date. Empty metadata is reported as empty, never fabricated, and is not the same as a failed search. Use `web.fetch` before relying on page contents or exact dates. The payload is bounded to valid JSON within the tool boundary — including very long queries, long citation URLs (an oversize row is omitted rather than returned with a changed URL) and large provider error text — and states explicitly when fields or results were shortened.

[↑ Back to contents](#contents)

<!-- doc-anchor: section-22 -->
## 18. Background work, PiP, notifications and data

iOS controls background execution. Background mode/PiP do not guarantee unlimited runtime; check real task/service state on return. Notifications require OS permission; confirm that a notification opens the intended task.

In **Settings → Background execution**, **Enhanced background**, **Picture in Picture**, and **Screen feedback** have separate switches. Enhanced background can run alongside PiP. Enabling screen feedback also enables PiP; turning PiP off turns screen feedback off. Screen sharing still requires system permission. Both use the same PiP window: it shows task progress unless screen feedback is actually available, and returns to progress when feedback ends. Open **Sound and narration** below PiP to choose and preview Meditation, First Light, Deep Blue, or Starfield, adjust the volume, or enable task narration and cues. Ambient sound starts muted on first use; raise the volume to listen. Your preferences are remembered, and playback ends when its task ends or PiP is closed.

Large downloads and Python data jobs are durable background jobs. A task that depends on a required job shows **Waiting for background work** instead of completed, and its Progress inspector lists the job with its real stage/phase and measured units, a Cancel action and the full-output pager: read the stored output page by page (`nextOffset` until it is done) instead of treating a short preview as the whole result; the pager reports total size, explicit truncation and UTF-8 boundaries. When the job finishes, its result continues the SAME task as its next round — you can add input while it waits — and it does not open a new unsolicited conversation. The status Picture-in-Picture floats only where the system allows it, and a web service's Ready state belongs to its current process; start the service again after the App is terminated.

**Data management** (Settings) manages only Floe's own data: it does not show device-wide storage or a total/free-capacity overview, and it never shows a guessed cap for the app. When Floe's files share APFS clone blocks (VM/runtime images and shared resources), the overview reports **App space** as **Managed by iOS Storage** — use iOS Storage for the app's system-accounted size — and Floe's shared data appears in its own **Shared files** section; that figure is file capacity and may count shared blocks more than once, so it is not additional physical usage and not free space that can be reclaimed. When sharing is detected, per-category file figures are one tap away under **File capacity details**. A cached snapshot renders the last valid totals immediately, an explicit pull-to-refresh always rescans, and real changes invalidate the cache. **Manage tasks** opens the same task-management screen as Home (see §4). Cleanup removes only registered rebuildable caches under Floe's own roots after owner checks; its estimate is labelled file capacity, not promised reclaimed bytes, and results report deleted, skipped and failed items separately.

Manage fonts, documents, environments and diagnostics in Settings. Imported fonts do not guarantee identical Office layout. Export important files/recovery copies before upgrades and preserve environments/models still in use. Log-level changes affect future collection, not missing past events. Redact private text, addresses, tokens and attachments before sharing diagnostics.

[↑ Back to contents](#contents)

<!-- doc-anchor: section-19 -->
## 19. Temporary chat (RAM-only)

The New Task launchpad is the only entry that starts a temporary chat; ordinary chat stays the default and no mode chooser appears. Text typed on the launchpad is carried into the temporary chat. An open saved conversation no longer offers a temporary switch, so a saved chat can never be converted from its own thread. *(Builds up to the current internal 1.7.32 (273) still show the header toggle; the next update removes it.)*

- The normal message list and composer are reused. Voice input is available; attachment staging stays unavailable. The compact Temporary menu carries the explanation, the voice note, End and Keep as saved instead of a persistent banner.
- Temporary chat can use only public web retrieval: web search (including the configured Bocha AI summary) and fetching public web pages. Personal data (calendar, reminders, mail, notes, conversation history, memory), files, device state, skill instructions and authenticated remote capabilities are not offered or discoverable here; writes, sending, code execution, installs, VM startup, background jobs, delegation and scheduled-task changes also stay unavailable. Unavailable tools are omitted from the actual model request, and a call outside this ceiling is refused with an explicit reason — it is not a prompt-only restriction.
- Voice follows your usual speech settings; Apple recognition may process audio online. Floe keeps no recording or transcript for a temporary chat: recognized text goes into the current RAM draft until you send it. Backgrounding stops capture without discarding the chat.
- End cancels and discards the temporary conversation, including work still in progress. Keep as saved atomically saves the messages, queued follow-ups and unsent draft without resending; a failed save preserves the temporary state for retry. The saved chat gets an ordinary fallback title from your first message (never an empty title) and one automatic title generation may follow; a title you renamed yourself is never overwritten.
- Rotation, fullscreen editing, backgrounding and locking preserve the same live conversation and draft. Switching chats, New Task or another destination immediately cancels and destroys temporary work; late tool or voice callbacks cannot bring it back. A conversation already kept as saved follows the normal saved-chat rules.

Temporary content — including any fetched public web content — lives only in the live session: it stays out of Floe history, persistent drafts, memory writes, notifications and the shared on-disk caches. Force-quitting or system termination does not restore them. Model and speech providers still process the content under their own policies — temporary chat is not a provider zero-retention promise.

[↑ Back to contents](#contents)

<!-- doc-anchor: section-23 -->
## 20. Troubleshooting

| Symptom | Check first | Next step |
| --- | --- | --- |
| Model absent | Enable/hide settings | Reselect from New Task |
| Claimed completion, no file | Tool receipt and output path | Open the actual result |
| Linux appears to reinstall | Build, environment, image state | Preserve environment; collect install logs |
| Three-core request fails | Image support, pool, memory | Release unneeded work and follow actual errors |
| Office inserts a shape on annotation entry | Installed build and sample copy | Deselect drawing objects and reopen pen mode; report a sample if it persists |
| Full-screen drawing reports offline | Local preview and exact error | Retry once; keep the original and report the error |
| Grey voice waveform | Permission, route, preparation | Stop/retry once, then collect diagnostics |
| Text search misses a document | Index and format | Reindex and inspect OCR results |
| Saved contents differ | Conflicts and recovery copies | Compare versions; preserve the only original |
| Legacy 3D scene cannot be converted | The reasons listed in the “3D scene migration” sheet | Fix the listed value, or keep the read-only legacy preview; the original is preserved |
| Provider saved but not synced | “Saved on this device; iCloud sync is pending” | Retry iCloud sync; do not re-enter the key |
| 3D drawing file not editable in the workbench | Imported drawing vs native 3D model | Only Canvas 3D model nodes open the workbench; drawing 3D entities stay read-only |
| App crashes | Build, time and reproduction | Supply matching device diagnostics |

[↑ Back to contents](#contents)

<!-- doc-anchor: section-24 -->
## 21. Useful feedback

Include device, OS, App version/build, entry point, minimal steps, expected/actual behavior and redacted screenshots or a synthetic sample. For crashes, include diagnostics from the matching time. For save issues, state whether save completed, whether the file was reopened and whether the original changed.

[Support](../SUPPORT.md) · [Security](../SECURITY.md)

[↑ Back to contents](#contents)
