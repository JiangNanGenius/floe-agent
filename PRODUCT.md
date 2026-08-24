# Product Overview

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

Detailed architecture, milestones, verification criteria, and release gates are in the [development plan](docs/DEVELOPMENT_PLAN.md).
