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

## Planned capabilities

- OpenAI Responses and Chat Completions compatible APIs.
- Anthropic Messages compatible APIs.
- Native streaming conversations with visible tool activity and recoverable state.
- Files, document, and image workflows.
- SSH, SFTP, jump hosts, terminal sessions, and SSH-tunneled VNC.
- Human approval, approval-model, and explicitly enabled time-bounded full-control modes.
- Keychain storage for secrets and private CloudKit synchronization for eligible configuration.
- English and Simplified Chinese interfaces.

## Explicit boundaries

Version 1 does not include Floe accounts, ads, behavioral analytics, model resale, a hosted proxy, downloaded plugins, arbitrary on-device code execution, RDP, VBA, ActiveX, or Office cloud collaboration.

iOS may suspend background work. Floe Agent must report that honestly and must never imply that an unmanaged SSH, VNC, or remote task remains connected when its state is unknown.

## Release baseline

- Platform: iOS and iPadOS 26 or newer.
- Distribution: free and open source.
- Backend: no Floe-operated account, model proxy, or remote relay.
- Telemetry: no advertising or third-party behavioral analytics SDKs.
- Status: pre-release Alpha; no supported public binary.

Detailed architecture, milestones, verification criteria, and release gates are in the [development plan](docs/DEVELOPMENT_PLAN.md).
