# Floe Agent v1.0 Development Plan

> [!NOTE]
> This is the original long-range milestone plan. Floe Agent 1.2.x has since adopted the continuous Task/Run model, v8 workspace ownership, visible browser, Skills, Plan/Goal/Memory, task permissions, and the unified workbench described in [Architecture Overview](ARCHITECTURE_OVERVIEW.md). Keep this file for roadmap traceability; do not use its old navigation or milestone status as current product documentation.

Status: Approved product and architecture baseline
Last updated: 2026-08-13

## 1. Product definition

Floe Agent is a free, open-source, bring-your-own-key AI agent workspace for iPhone and iPad. It does not require a Floe account or route model, document, terminal, or remote-desktop traffic through a Floe-operated service.

### Locked product decisions

- Product name: **Floe Agent**
- App Store subtitle: **Private AI Agent Workspace**
- Tagline: **Your models. Your files. Your machines.**
- Proposed bundle identifier: `org.floeagent.ios`
- Minimum deployment target: iOS 26.0 and iPadOS 26.0
- The iOS/iPadOS 26 baseline remains supported after the next major OS release unless a future explicit product decision changes it.
- Required device capabilities: `arm64`, `metal`, and `iphone-performance-gaming-tier`
- Minimum validation hardware: iPhone 15 Pro and an M1 or A17 Pro class iPad
- Distribution: all intended App Store regions except mainland China
- Original project license: MPL-2.0, subject to a complete third-party license audit
- Languages at launch: English and Simplified Chinese
- No advertising, in-app purchases, model resale, behavioral analytics, or Floe-operated inference backend

The actual supported-device list must be verified in App Store Connect before the first TestFlight build. Performance restrictions must be present in the first public version because App Store capability requirements cannot safely be tightened for existing customers later.

## 2. Application architecture

### 2.1 Repository and runtime structure

The repository will contain three product areas:

- A Swift 6 iOS/iPadOS application using strict concurrency.
- Shared Swift packages for model protocols, agent execution, storage, security, document commands, image operations, SSH, and VNC.
- An optional open-source Rust remote helper installed in a user's home directory and accessed only through SSH standard input/output.

SwiftUI owns navigation, settings, chat, approval, and run-history screens. UIKit and Metal bridges own the Office editor, terminal surface, and VNC framebuffer. Shared mutable services are actor-isolated. Large event histories and audit data use GRDB/SQLite rather than view-owned state.

The iPhone interface uses a compact tab layout. The iPad interface uses `NavigationSplitView`, scene restoration, multiple windows, pointer input, and external keyboard commands. The primary destinations are Home, Chat, Files, Hosts, Runs, and Settings.

### 2.2 Public domain interfaces

Provider implementations translate wire formats into the following stable domain concepts:

- `ProviderProfile`: provider type, wire protocol, base URL, secret reference, region, non-secret headers, and enabled state.
- `ModelProfile`: remote model identifier, display name, limits, pricing metadata, and text, vision, tools, image-generation, image-editing, or approval capabilities.
- `ModelProtocol`: OpenAI Responses, OpenAI Chat Completions, or Anthropic Messages.
- `AgentEvent`: text delta, reasoning summary, tool request, tool result, usage, normalized error, or completion.
- `ToolCall`: stable call ID, tool name, validated JSON arguments, affected host or file scope, and idempotency key.
- `ApprovalDecision`: allow, deny, or escalate-to-human with reason, scope, and expiry.
- `RemoteHostProfile`: address, SSH port, user, authentication reference, jump chain, host-key policy, and optional VNC endpoint.
- `RemoteRun`: lifecycle, remote session identifier, heartbeat state, output cursor, exit status, and audit reference.
- `DocumentCommand`: semantic document mutation independent of editor screen coordinates.
- `ImageOperation`: a precompiled local image operation with validated parameters.
- `VNCAction`: click, double-click, drag, scroll, key press, text input, wait, or finish.

All externally received tool parameters are decoded into strict schemas, size-limited, validated, and presented to the policy engine before execution.

## 3. Model and agent runtime

### 3.1 Provider coverage

Version 1 supports:

- OpenAI Responses API, Chat Completions, and Images.
- Anthropic Messages streaming and tool use.
- Volcengine Ark chat, multimodal, Seedream, and SeedEdit endpoints.
- Alibaba Model Studio compatible chat and image endpoints.
- User-defined compatible endpoints with explicit protocol selection, base URL, model IDs, and headers.

When supported, `/models` is used for discovery. Manual configuration remains available because many compatible services do not expose complete capability metadata.

Networking uses URLSession with incremental SSE parsing, explicit cancellation, bounded retry with jitter, normalized rate-limit handling, and context-size enforcement. Public endpoints require HTTPS. Plain HTTP is available only for localhost or private-network endpoints after a risk warning.

### 3.2 Agent execution

The agent is a persisted, cancellable state machine. It records model messages, tool calls, approvals, results, and checkpoints without storing provider secrets. A tool result is returned to the model only after execution reaches a terminal state or an explicit recoverable failure.

Model-provided code is never downloaded and executed on iOS. The on-device tool catalog contains only compiled document, image, SSH, VNC, file, and status operations. Code execution is limited to an explicitly authorized remote host.

### 3.3 Approval modes

Floe Agent exposes three policies:

1. **Human approval:** every side-effecting action waits for the user.
2. **Approval model:** a selected configured model returns allow, deny, or escalate-to-human for a structured action.
3. **Full control:** normal actions execute without per-action approval for one selected host after local authentication.

Full control defaults to 30 minutes. The user may choose 15, 30, or 60 minutes, or until the connection closes. Enabling it requires Face ID or the device passcode and an explicit risk acknowledgement.

An independent catastrophic-action gate runs before every approval mode. It stops only high-confidence destructive actions such as recursively clearing root or home directories, formatting disks, overwriting block devices, or equivalent broad irreversible deletion. The user can still release a stopped action after a second local authentication and impact confirmation.

This mechanism does not promise to detect every destructive behavior hidden inside a shell script. Graphical VNC actions cannot be protected with the same certainty, so autonomous VNC control has a separate per-session enable switch and a persistent emergency stop control.

The approval model receives the user goal, structured proposed action, host and path scope, and deterministic risk labels. Untrusted terminal or document content is excluded unless necessary. The approval model cannot rewrite a tool call.

Audit entries contain the model, tool, target, policy, decision, timestamps, exit status, and bounded output digest. Entries form a device-keyed hash chain. API keys, passwords, private keys, and unredacted sensitive headers are never written to the audit database.

## 4. Storage, iCloud, and Files

### 4.1 Model configuration synchronization

- API keys, bearer tokens, and sensitive custom headers use synchronizable iCloud Keychain items.
- Synchronizable secrets use `kSecAttrAccessibleWhenUnlocked`; application-level Face ID locking gates normal UI access.
- Provider metadata, base URLs, model lists, capability tags, approval-model selection, and non-secret preferences sync through a private CloudKit custom zone using `CKSyncEngine`.
- Sensitive CloudKit fields use encrypted values.
- Records use stable UUIDs, revision metadata, per-field modification timestamps, and deletion tombstones.
- A configuration arriving before its Keychain item is shown as waiting for secret synchronization rather than treated as corrupt.
- Users may disable secret synchronization per provider and retain that secret only on the current device.
- When iCloud is unavailable, the application remains fully functional with local data and reports synchronization as paused.

SSH keys, SSH and VNC passwords, known-hosts data, host profiles, conversations, terminal logs, VNC frames, and detailed audit output remain local by default. A future user-controlled encrypted export may include them, but they are not part of automatic v1 CloudKit synchronization.

### 4.2 Files and documents

Documents and images are opened from Files using security-scoped URLs. They may live in iCloud Drive, On My iPhone/iPad, network storage, or third-party file providers. Floe Agent does not create a second CloudKit copy.

Writes use `NSFileCoordinator`, a temporary sibling file, atomic replacement when supported, and explicit conflict UI when the underlying provider changes the file. Agent changes create local version snapshots before mutation and support diff, restore, and Save As.

Configuration export excludes secrets by default. A full secret-bearing export requires local authentication and produces a password-encrypted file.

## 5. Office editing

Floe Agent embeds a pinned Collabora/LibreOffice iOS core. The first technical gate must prove reproducible compilation, acceptable binary size, and round-trip editing on the minimum devices.

Interactive editing targets DOCX, XLSX, PPTX, ODT, ODS, ODP, CSV, RTF, and TXT, with PDF viewing and export. The editor covers text styles, page layout, tables, formulas, charts, images, comments, tracked changes, and presentation objects to the extent supported by the pinned upstream engine.

VBA macros, ActiveX, executable OLE content, downloaded editor plugins, and hosted collaborative editing are excluded. Floe Agent must never claim pixel-perfect compatibility with every Microsoft Office version.

Agent operations use semantic `DocumentCommand` values rather than simulated taps. Version 1 commands cover document creation, text reading and replacement, styles, tables, cell formulas, images, comments, slide structure, and export. Commands execute through a narrow reviewed bridge into LibreOffice/Collabora functionality.

## 6. Image editing

Local editing uses Core Image, Metal, Accelerate, and ImageIO. Compiled operations cover crop, rotate, resize, format conversion, compression, metadata removal, exposure, color, sharpening, blur, masks, compositing, text, watermarking, and transparent backgrounds.

Editing is nondestructive and versioned. The app preserves color-space and orientation metadata unless the user requests removal or normalization.

Provider adapters support OpenAI, Volcengine, and Alibaba image editing, including single or multiple source images, masks, partial previews when available, cancellation, cost presentation, and versioned results.

## 7. SSH, terminal, and remote execution

Citadel and SwiftNIO SSH provide SSHv2, PTY, SFTP, TCP forwarding, and chained jump hosts. SwiftTerm provides terminal emulation.

Required behavior includes:

- Password, imported-key, and device-generated-key authentication.
- Device-only Keychain storage for SSH credentials.
- Trust on first use with visible host fingerprints.
- A hard stop on unexpected host-key changes.
- Modern algorithms by default; legacy algorithms enabled only for a specific host after warning.
- Multiple terminal tabs, PTY resizing, external keyboard support, protected paste, SFTP browsing, and remote-file editing.
- VNC forwarding through the same SSH and jump-host chain.

The optional Rust helper installs under the remote user's home directory, opens no public listening socket, and communicates through an SSH command channel using framed, versioned messages. It manages tmux sessions, process groups, heartbeats, pause, resume, terminate, structured output cursors, and exit status.

The default missed-heartbeat timeout is 45 seconds. A helper-managed process group is paused after that timeout and retained for reconnection. Processes that deliberately escape the managed process group cannot be guaranteed to pause.

Without the helper, an unexpected disconnect produces an unknown task state. Floe Agent must not tell the user that an unmanaged task was paused.

Foreground SSH and VNC connections are long-lived. On backgrounding, the app requests only legitimate short completion time, saves cursors, and permits suspension. It does not misuse audio, location, VoIP, or notifications to claim permanent socket survival. A known disconnect can trigger a local notification; a suspended app cannot report later remote state until it resumes.

## 8. VNC and multimodal control

RoyalVNC supplies the MIT-licensed RFB protocol implementation. Floe Agent adds a Metal-backed iOS/iPadOS framebuffer and touch, pointer, keyboard, clipboard, scaling, and resolution-change handling.

Public-network VNC requires an SSH tunnel. Direct VNC is available only for private addresses after a warning because classic VNC authentication does not protect framebuffer and input traffic.

Only models marked with visual-input capability can control VNC. The control loop is:

1. Capture the current framebuffer.
2. Apply user privacy masks and sensitive-field exclusions.
3. Request one structured action from the model.
4. Validate and execute the action.
5. Capture a new frame and ask the model to verify progress.

A text-entry action may contain a complete bounded string; other actions remain atomic. The default limit is 50 actions or 10 minutes. The user can stop the run at any time. Password fields, marked private regions, SSH secrets, and protected clipboard values are not sent to a model.

## 9. Delivery milestones

### M0 — Technical validation, 3 weeks

- Build and embed the Office engine.
- Open, modify, save, and reopen representative DOCX, XLSX, and PPTX files.
- Establish SSH PTY through a jump host with strict host-key validation.
- Render and control a RoyalVNC session on minimum hardware.
- Verify CloudKit configuration and iCloud Keychain secrets across two devices.

Failure of a core spike blocks UI expansion until the underlying integration is resolved. The project does not silently replace full Office editing with a text-only editor.

### M1 — Foundation, 4 weeks

- Xcode project and modular Swift packages.
- Swift 6 concurrency boundaries, GRDB migrations, navigation, app lock, Files integration, CloudKit, and Keychain synchronization.
- CI build, dependency pinning, SBOM generation, secret scanning, and license inventory.

### M2 — Models and agent runtime, 6 weeks

- Three wire protocols, core provider adapters, streaming chat, attachments, tool loop, usage reporting, approval policies, run timeline, cancellation, and checkpoint recovery.

### M3 — SSH and remote execution, 8 weeks

- Terminal, SFTP, jump hosts, forwarding, known-hosts, remote-file editing, Rust helper, tmux recovery, disconnect reporting, and audit logs.

### M4 — Office, 12 weeks

- Production editor integration, open-in-place saving, snapshots, semantic Agent commands, and compatibility corpus.

### M5 — Images, 5 weeks

- Local pipeline, three remote adapters, masks, history, metadata policy, and export.

### M6 — VNC and visual control, 8 weeks

- Metal viewer, SSH tunnel, keyboard and pointer input, privacy masks, visual action loop, timeouts, and emergency stop.

### M7 — Integration and security, 7 weeks

- Full-control lifecycle, destructive-action corpus, prompt-injection defenses, protocol fuzzing, privacy review, memory and thermal behavior, and endurance fixes.

### M8 — Beta and release, 4 weeks

- TestFlight, accessibility, localization, privacy manifest, source and license notices, export-compliance documentation, review demo hosts, and App Store submission.

M2, M3, and M4 may proceed in parallel after M0. A recommended team is two Swift/iOS engineers, one LibreOffice/C++ engineer, one systems/Rust engineer, plus part-time product design, QA, and security review. Estimated duration is 9–11 months for that team or 20–26 months for one full-time engineer.

## 10. Verification and release criteria

### Automated testing

- Provider contract fixtures for SSE fragmentation, unknown events, tools, images, cancellation, 429 responses, malformed payloads, and context overflow.
- Two-device sync tests for create, update, delete, offline edits, tombstones, delayed secrets, iCloud logout, and encrypted-data reset.
- Unit and fuzz tests for schema decoding, shell risk detection, SSH/RFB framing, image parameters, and document commands.
- Automated secret scans proving API keys, passwords, and private keys do not enter SQLite, logs, crash attachments, or analytics.
- UI tests for approval boundaries, full-control expiry, local authentication, emergency stop, and destructive-action override.

### Device and endurance testing

- iPhone 15 Pro and M1/A17 Pro class iPad as the minimum performance baseline.
- Eight-hour foreground SSH session, network changes, three-hop jump chain, large terminal output, tmux reconnection, and helper timeout pause.
- At least 200 complex Office samples with open, edit, save, reopen, and structural-diff checks; no silent corruption.
- Large and wide-gamut images, transparency, EXIF orientation, memory pressure, cancellation, and failed remote requests.
- VNC encodings, resolution changes, clipboard, tunneling, network jitter, and 50-step visual-agent scenarios.
- Target 30 fps for a 1080p LAN VNC session on minimum hardware, with adaptive quality under memory or thermal pressure.
- VoiceOver, Dynamic Type, external keyboards, pointer input, multitasking, window restoration, and English/Chinese layouts.

### Release gates

- No known critical or high-severity security findings.
- No plaintext secret persistence outside Keychain.
- Reproducible pinned builds and complete license/source notices for bundled components.
- Privacy manifest, encryption export classification, SBOM, and reviewer-facing architecture notes completed.
- Reviewer demo connects only to computers owned or controlled by the project and demonstrates generic remote-client behavior without a software marketplace.
- Formal name and trademark search completed for **Floe Agent** before final icon and store assets are locked.

## 11. Explicit exclusions and limitations

- No mainland China App Store distribution.
- No Floe account system, provider proxy, hosted terminal relay, or push-notification backend in v1.
- No arbitrary on-device code execution, downloaded plugins, model marketplace, RDP, VBA, ActiveX, or Office cloud collaboration.
- No guarantee of permanent SSH or VNC connectivity while iOS suspends the app.
- No guarantee that unmanaged remote tasks pause after a disconnect.
- No guarantee that destructive intent hidden in arbitrary scripts or graphical VNC actions will be detected.
- Users remain responsible for API costs, provider terms, data regions, and authorization to operate connected computers.

## 12. App Store and privacy position

Floe Agent is a generic client for computers owned by or explicitly authorized to the user. Remote software executes on the host. Account and software management occur outside the remote mirror, and the app does not expose a store-like catalog of remote applications.

The privacy label should state that Floe Agent itself does not collect user content. Data sent directly to a configured model provider is governed by that provider and is explained before the provider is enabled. The app provides a per-provider data-destination summary and a preview of attachments or screenshots before first transmission.
