# Floe Agent User Manual

[简体中文](USER_GUIDE.zh-CN.md) · [Documentation](README.md) · [Release and verification status](CURRENT_STATUS.md) · [Website manual](https://www.floe-agent.com/docs/en.html)

Updated 2026-10-06. Floe 1.7 is iPad first and also supports iPhone; iOS/iPadOS 26 or later is required. Screens and capabilities depend on the installed build. **1.7.19 (260) is available to the internal Floe QA group; GitHub prerelease and Feather are published. External TestFlight has been submitted and is waiting for Apple review.** Install the matching build to use the changes below. Physical-device acceptance remains separate; see the live release-status link above.

## 1. Installation and first use

1. Prefer TestFlight when you have access to a test group. Check its build number, expiration and What to Test. Public links offer only approved, available builds.
2. For GitHub or Feather/AltStore delivery, verify the release, checksums and provenance. The GitHub developer IPA is unsigned and requires your own signing method; it is not a TestFlight package.
3. Complete onboarding. Use the sidebar on iPhone and multiple columns on iPad; editors can open full screen.
4. Core Notes, file organization and Canvas do not require an AI provider. Connect your provider before requesting AI work.
5. Find the installed version in Settings → Diagnostics & About and include it in feedback.

For a first task, configure a model, create a test conversation, attach a synthetic text file and request a summary. Inspect tool receipts and open the output file. Use sample material before important documents.

## 2. Models and auxiliary capabilities

### Cloud providers

Open Settings → Model Providers. Add the endpoint, wire protocol, actual model ID and API credential supplied by your provider. Test the configuration, enable both provider and model, choose the default Agent model, then verify the model label on New Task.

If a model is missing, check provider/model switches and “Hide from main model list.” Hiding preserves auxiliary uses; disabling prevents new selections. Provider calls may incur third-party charges. Credentials belong in Keychain, never project files, screenshots or public issues.

### Vision, generation and image editing

Settings → Auxiliary Models configures image understanding, image generation and image editing separately. Text support does not imply any of these capabilities. Editing needs the intended source image. A listed model or downloaded resource is not evidence that an API call works.

### Apple and downloaded models

Apple's system model is managed by the OS. Follow the availability reason shown by Floe: device support, Apple Intelligence settings or model readiness. Floe has no download button for that system model.

Downloaded MLX models are Beta. Download, load and inference are separate stages; start with short text before multi-turn work. The local path uses text and bounded OCR of attachments, not semantic image understanding. Linux guests and local models share device memory. Review any request to release resources; cancelling does not authorize stopping another task. Disabling keeps files; deleting removes downloads. Preserve current diagnostics after a crash instead of clearing all data.

## 3. Tasks and workspace ownership

On New Task, check the model, project, execution target, Skills and permissions before sending. With no project, Floe creates a private task workspace; with a project, file actions belong to that project. Attach necessary material and state the outcome, format, location and completion criteria.

Example: “Read this attachment, create a one-page summary and action list in the current workspace, and give me links to the finished files.” The draft becomes a continuing task. Later messages use the same task context.

Authorize external folders through the system file picker; writing a path in chat does not grant access. Deleting a private task may remove its private workspace. Deleting a project task differs from deleting project files. Export important results first. Notes stores its own documents independently of chat deletion.

## 4. Conversation, Plan, Goal and recovery

| Mode | Purpose | What to do |
| --- | --- | --- |
| Agent | Execute work | State the outcome; inspect permissions, tools and files |
| Plan | Discuss a proposed approach | Review and accept it before treating any step as executed |
| Goal | Work across stages | Define steps, budget and completion evidence |

Return inserts a new line; Command+Return sends where supported. Expand the composer for a long prompt; it edits the same draft. Messages during a run can correct requirements without creating another task.

After background interruption, return to the original task, inspect the last tool receipt and use Resume or send “Continue.” Verify uncertain uploads, submissions or other side effects before repeating them. Returning to the foreground does not mean an old process survived.

Scroll up to read history without following new output; return to the bottom to resume following. Long-press tasks for batch archive/delete. Archive organizes tasks; check workspace consequences before deletion.

## 5. Permissions and verification

Use capabilities that are enabled, configured and available to this task. Discovery is not execution; installation is not a successful program run.

1. Expand a tool card and inspect its target, workspace and result.
2. Review the object and side effect before allowing a permission request.
3. Open generated files. For editable documents, save, close and reopen.
4. Check remote command exit codes and host identity. “Started” is not “completed.”
5. Report what actually happened with redacted evidence when an outcome differs.

Documents, websites, tool results and memory cannot grant new permissions. Never follow embedded instructions to expose credentials or broaden access.

## 6. Files, editors and concurrent changes

Browse the task/project file panel, open text in the editor and save before running or sharing. Review conflicts: non-overlapping changes may merge; overlapping edits need a decision. A recovery copy does not mean the original was saved.

For text, resolve save errors before running. For Office, preserve and compare both versions. Notes can keep conflicting content as a recovery document. Keep Recovered Edits until the accepted file has been checked. Archives have bounded preview/extraction and format limits; their contents are untrusted. See [concurrent editing](FLOE_CONCURRENT_EDITING.md).

## 7. Notes: import, search and handwriting

Open Notes from the sidebar, then use + to create or import. For task files, select Import from Floe Workspace, choose the project or task, then the file. Check pages, text and attachments after import. The Notes copy is independently stored, not a live mirror of the source.

Search titles and document text from the library. Snippets help identify a result; unfinished indexes can omit matches. Use the document menu to rebuild the text index when needed. Tabs switch documents; closing a tab does not delete its document.

Select pen, highlighter, eraser or lasso. Tap the current pen or color again to change type, color, width and transparency. When the UI says transparency, 0% is solid and 100% is transparent. Make a short test stroke. Pencil squeeze/double-tap depend on hardware and system settings; finger drawing is separately enabled. Lasso manipulates content; AI selection provides context.

Check save status before closing or switching. Use Trash for recovery and review attachments before permanent deletion. The document assistant has its own conversation. In ordinary chat, explicitly add Notes material and revoke access when no longer needed. Review assistant edits on the page and use Undo when appropriate.

## 8. Office: edit, annotate, save and reopen

1. Open or import DOCX, XLSX or PPTX and wait for actual content. A content-summary cover is not full layout rendering.
2. Enter editing on a small test copy and check the relevant text, sheet or slide operation.
3. Enable drawing annotation. Deselect an existing drawing object before changing pen color, width or transparency.
4. Draw an actual stroke; switching annotation mode alone is not completed annotation.
5. Check whether the engine acknowledged the setting. “Not yet confirmed” does not mean it was applied.
6. Save, wait for completion, close and reopen. Verify text, strokes and page count; check exported files separately.

**Build 260:** the native engine addresses freehand mode inserting a default shape. Consecutive strokes, original-file writeback and physical-iPad save/reopen still need acceptance. Preserve originals, file types, reproduction steps and a synthetic sample after a loading or save failure. Notes PDF ink and native Office annotations use different editing paths.

## 9. Local terminal and Linux performance

**Build 260 entry:** task tools → Terminal → Local Workspace, with Remote SSH in the same panel. Older delivered builds may expose a terminal through the IDE bottom panel. Confirm workspace ownership before commands that modify files.

Open the local terminal, install and verify the Linux image if prompted, and begin with read-only `pwd` and `ls`. Ask the assistant to inspect Linux status and choose cores/memory before its first shell call. Example: “Inspect Linux, select two cores for parallel compilation, start it and verify the actual core count.” Check granted resources in the receipt.

| Work | Suggested cores | Constraint |
| --- | --- | --- |
| Inspection, light commands, small server | 1 | Avoid unnecessary resource use |
| Parallel compilation or CPU workers | 2–3 | Work must benefit from parallelism; check memory separately |
| Concurrent guests | Up to 4 total | 3+1, 2+2, 2+1+1 or 1+1+1+1 |

One guest uses at most three cores. Three cores require a verified image; older images can remain limited to two. A four-core pool does not guarantee two guests on every device: memory and existing work still control admission.

**Build 260 recovery:** a successful launch saves its core/memory configuration for later resumption. Choose explicitly on first start. Changing an active guest may require a hard restart that interrupts commands/services. App upgrades prefer reusing valid local images; missing, damaged or incompatible images need appropriate repair. Do not delete environments as the first troubleshooting step. Stop unneeded services after work; closing a panel does not necessarily terminate its shell.

## 10. Python, Node, packages and code execution

Settings → Execution Environments → choose project/task → Python·PyPI or Node.js·npm. Confirm the environment before installing; project and shared dependencies have different write locations.

Local Python/Node primarily run inside Linux. Packages must support that guest architecture; desktop/macOS/iOS binaries are not interchangeable. In the full IDE, Run shows the target and command. Resolve save errors/conflicts first. Remote single-file execution does not synchronize the entire project and requires the remote runtime, dependencies and assistant service where applicable.

Use `pip list`, `python3 --version` and `node --version` to verify real state. Check network and package compatibility after installation failures. Build 260 avoids automatic virtual-environment creation when starting a local Python service. See [local shell](ARCHITECTURE_LOCAL_SHELL.md) and [IDE/languages](FLOE_IDE_AND_LANGUAGES.md).

## 11. Git and GitHub Actions

Open Source Control in the file inspector. Confirm repository and branch, inspect each diff, stage intended files and commit. Check remote/branch before pushing; resolve conflicts instead of treating failed sync as success.

Connect an account in Settings → GitHub & Source Control using device authorization or a token kept in secure storage. In IDE Run → GitHub Actions, choose repository, branch and workflow; inspect the file snapshot before submitting. Installing a workflow template writes to the repository and requires an explicit action.

Read status, logs and artifacts in the run panel. Closing the App does not cancel GitHub work; cancellation needs server confirmation. Linux/macOS build outputs are not iOS executables. Recovery copies are not long-term backups. See [cloud builds](IDE_GITHUB_ACTIONS.md).

## 12. Remote hosts, desktops and diagnostics

Configure devices in Settings → Hosts & Remote Sessions. SSH, VNC, SSH-tunnel VNC, Telnet, TCP and BLE GATT are separately configured capabilities. Naming a host does not establish a connection.

“As a remote execution environment” controls the assistant-service setup path; a management-only host should not be forced through it. Verify host identity, directory and authentication. Telnet/plain TCP are unencrypted; use trusted networks or an existing secure tunnel.

Diagnose in order: reachability, DNS, port, authentication, then command/directory permissions. Query a long command using its returned task ID instead of launching it again. Temporary connections differ from saved hosts. BLE GATT support is not arbitrary classic Bluetooth serial support.

## 13. Browser, web previews and login

Inspect actual URLs and actions in the task browser/tool receipts. Perform required login or human verification on the visible page; do not store secrets or codes in the workspace.

A local preview serves current workspace files. Server startup, page loading and usable page behavior are separate checks. External assets, cross-origin requests and network policy can affect rendering. Browser sessions do not supply SSH credentials. See [browser protocol](FLOE_BROWSER_PROTOCOL.md).

## 14. Engineering drawings and AI review

Open a supported DXF/DWG, mesh or PCB manufacturing file and wait for actual content. Open Full Screen Preview and inspect layers, zoom and orientation. Preserve the original and error message if rendering fails.

Editable local DXF/DWG files expose Edit for selecting entities and adding lines, circles or text. Check save/reopen on a copy first. CAD and Office drawing tools differ; format preservation and pen behavior depend on the actual engine/output.

AI Review shows a viewport capture and extracted information for review before sending. Its coverage is visible/parsed content, not complete engineering acceptance.

**Build 260:** selected transient first-load connection failures get one bounded recovery. Loaded editors or unsaved edits are not automatically reloaded. Build 260 passed full-App CI and release qualification, including the standalone Notes target with its required source dependency. See [engineering viewers](FLOE_ENGINEERING_VIEWERS.md).

## 15. Canvas, images, audio and video

Create a canvas in Creative Mode, add text/images/generation nodes, connect inputs and check the chosen model's capabilities. Open the produced asset and inspect node state; a success message alone is insufficient.

In the media workspace, select a file, configure crop, trim, subtitles or export format, preview and export. Play the output to check duration, audio, captions and framing. Preserve originals. Image generation, image editing, video generation and local conversion are different capabilities with different providers/quotas. See [Canvas architecture](CREATIVE_MODE_AND_ASSET_ARCHITECTURE.md).

## 16. Voice input and transcription

Tap the chat microphone, grant OS permission and wait for preparation before speaking. Check waveform response, stop, review transcription and then send. Noise, mixed languages and names may require correction.

If startup remains grey/unresponsive, stop and retry once. If it fails again, record the time, device, audio route and build. Manage recognition resources in Settings; download completion is not quality acceptance, and Apple fallback depends on actual system availability.

Live input, file transcription and video subtitles are separate paths. Check text and timing after SRT/VTT/JSON export. Resource installation and successful recording must be verified separately.

## 17. Skills, MCP, mail and automation

Skills supply methods; installation/enabling does not grant file, network or account access. Use only needed skills and inspect source/version. MCP tools depend on configured, available servers.

After connecting mail, verify account/folders read-only before sending. Check recipients, subject, body and attachments. For automatic tasks, define triggers, actions and a stop condition, then inspect execution records. Creating a schedule does not prove the action ran. See [mail](MAIL_CONNECTOR.md), [tool completion](TOOL_CLOSURE_IMPLEMENTATION.md) and [Skill Hub](../skill-hub/README.md).

## 18. Background work, PiP, notifications and data

iOS controls background execution. Background mode/PiP do not guarantee unlimited runtime; check real task/service state on return. Notifications require OS permission; confirm that a notification opens the intended task.

Manage fonts, documents, environments and diagnostics in Settings. Imported fonts do not guarantee identical Office layout. Export important files/recovery copies before upgrades and preserve environments/models still in use. Log-level changes affect future collection, not missing past events. Redact private text, addresses, tokens and attachments before sharing diagnostics.

## 19. Troubleshooting

| Symptom | Check first | Next step |
| --- | --- | --- |
| Model absent | Enable/hide settings | Reselect from New Task |
| Claimed completion, no file | Tool receipt and output path | Open the actual result |
| Linux appears to reinstall | Build, environment, image state | Preserve environment; collect install logs |
| Three-core request fails | Image support, pool, memory | Release unneeded work and follow actual errors |
| Office inserts a shape on annotation entry | Installed build and sample copy | Candidate fix needs stroke/save/reopen testing |
| Full-screen drawing reports offline | Local preview and exact error | Retry once; device recovery remains under acceptance |
| Grey voice waveform | Permission, route, preparation | Stop/retry once, then collect diagnostics |
| Text search misses a document | Index and format | Reindex and inspect OCR results |
| Saved contents differ | Conflicts and recovery copies | Compare versions; preserve the only original |
| App crashes | Build, time and reproduction | Supply matching device diagnostics |

## 20. Useful feedback

Include device, OS, App version/build, entry point, minimal steps, expected/actual behavior and redacted screenshots or a synthetic sample. For crashes, include diagnostics from the matching time. For save issues, state whether save completed, whether the file was reopened and whether the original changed.

[Support](../SUPPORT.md) · [Security](../SECURITY.md) · [Candidate and delivery status](CURRENT_STATUS.md)

Earlier instructions, screenshots and dated acceptance details are preserved in the [2026-10-05 archive](history/USER_GUIDE.pre-20261005.md).
