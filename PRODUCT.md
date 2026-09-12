# Product Overview

> **Historical note (2026-09-12):** the version-1 exclusion of "an unrestricted
> shell/process environment" below is superseded. The 1.6.7 source introduced a bounded
> on-device POSIX shell substrate (approval-gated, with scoped file operations, no
> native ELF execution) plus an apt/pkg capability catalog. The authoritative
> description is [docs/ARCHITECTURE_LOCAL_SHELL.md](docs/ARCHITECTURE_LOCAL_SHELL.md).

## Floe 1.7 product scope

The active milestone connects layered dependency environments, package installation and media processing to the existing task and workspace experience. The media workbench is a single-asset editor with preview, trim, operation settings, export and shared task progress; a professional multitrack editor is outside this milestone.

Environment layers are `session > project > shared > base`. They organize dependencies, data and lifecycle. Native Python, Node and shell code running inside the App is not separated by a strong per-environment process security boundary. App file operations still enforce their own path and permission checks.

The milestone remains unfinished. Candidate package/model catalogs must not be advertised as runnable downloads before signing, installation and real execution are verified. See [status](docs/FLOE_1_7_IMPLEMENTATION_STATUS.md) and [compatibility](docs/FLOE_1_7_COMPATIBILITY.md).

### Media workflow preview

<img src="docs/evidence/floe-1.7/native-media-workbench.png" width="360" alt="Floe media workbench source player and saved trim range">

The development workbench keeps source playback and editing parameters together. This iOS Simulator capture uses synthetic media; it illustrates the connected preview/trim surface, while complete navigation, shared jobs and device acceptance remain open. See the [user guide](docs/USER_GUIDE.md) for the current workflow.

## Purpose

Floe Agent is a bring-your-own-key AI agent workspace for iPhone and iPad. It brings model conversations, Files documents, image operations, SSH terminals, and VNC sessions into one auditable task flow without requiring a Floe account or a Floe-operated proxy.

The primary users are technically capable individuals who understand API keys, model endpoints, remote hosts, and the consequences of granting an agent access to files or machines.

## Product promise

A user should be able to configure a provider, start a real streaming task, understand what the agent is doing, approve or stop consequential actions, reconnect to remote work, and verify the result from a native mobile interface.

Floe Agent is designed around three commitments:

- **Your models:** connect directly to supported providers with credentials you control.
- **Your files:** work with documents and images through Apple's Files ecosystem.
- **Your machines:** connect only to computers you own or are authorized to operate.

## Current capabilities

- OpenAI Responses and Chat Completions compatible APIs.
- Anthropic Messages compatible APIs.
- iOS 27 Apple Foundation Models plus curated, user-downloaded Qwen and Gemma MLX models with local-only resource policies.
- Native streaming conversations with visible tool activity and recoverable state.
- Files, document, and image workflows.
- Independent vision, image-generation and image-editing roles, including OpenAI Images and Google Gemini Images with editable proxy Base URLs.
- App-managed private workspaces, Files project workspaces, and lightweight native Git/GitHub source control.
- SSH, SFTP, jump hosts, terminal sessions, and SSH-tunneled VNC.
- Scope-aware human approval, optional approval-model review, reusable bounded grants, and explicitly enabled time-bounded full-control modes.
- Keychain storage for secrets and private CloudKit synchronization for eligible configuration.
- Bounded bundled Python and JavaScript execution, plus declarative Skills that cannot load native plug-ins or enlarge the compiled tool catalog.
- English and Simplified Chinese interfaces.

## Current development focus

The preceding workflow upgrade added a Discover/Installed plugin surface, contextual batch task management, an isolated all-workspace file manager, inline PDF reading, mobile canvas corrections, and truthful live execution feedback. Word, Excel, and PowerPoint remain one Office tool family; PDF is separate.

Editing correctness takes priority over appearance: supported edits must retain intended content, formatting and object positions, survive save/reopen, preserve unrelated content and report conflicts. Full advanced Office editing remains pending offline-engine qualification and integration; the basic native editor does not establish desktop-document parity. See [scope, screenshots and verification status](docs/WORKFLOW_UPGRADE.md).

## Explicit boundaries

Version 1 does not include Floe accounts, ads, behavioral analytics, model resale, a hosted proxy, downloaded native plug-ins, an unrestricted shell/process environment, Git history rewriting/force operations, RDP, VBA, ActiveX, or Office cloud collaboration.

The Apple Foundation Model is available only when the operating system reports it ready on an eligible iOS/iPadOS 27 device. Downloaded local models are optional and device-memory dependent. Floe must show the real availability or resource reason when either path cannot run; it must not describe an unimplemented or uncompiled feature as a device failure.

Routine read-only and bounded local operations should not wait for model approval. Destructive actions, credentials, uploads, payments, broad remote mutation and other consequential operations remain explicitly scoped and reviewable. A vague diagnostic request can authorize safe discovery, but never silently grants destructive or credential access.

iOS may suspend background work. Floe Agent must report that honestly and must never imply that an unmanaged SSH, VNC, or remote task remains connected when its state is unknown.

## Release baseline

- Platform: iOS and iPadOS 26 or newer.
- Distribution: free and open source.
- Backend: no Floe-operated account, model proxy, or remote relay.
- Telemetry: no advertising or third-party behavioral analytics SDKs.
- Status: prerelease; releases may be available for testing but are not supported for production use.

Detailed architecture, milestones, verification criteria, and release gates are in the [workflow-upgrade record](docs/WORKFLOW_UPGRADE.md).
