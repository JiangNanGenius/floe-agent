# Product

<!-- impeccable:product-schema 1 -->

## Platform

ios

## Users

Floe Agent is designed first for technically capable individual users who already understand API keys, model endpoints, SSH hosts, and the consequences of granting an agent access to files or machines. They use an iPhone or iPad to start, supervise, approve, and review work performed by AI models and explicitly authorized remote computers.

## Product Purpose

Floe Agent is a free, open-source, bring-your-own-key AI agent workspace for iPhone and iPad. It combines user-selected model providers, Files documents, image operations, SSH terminals, and VNC sessions in one auditable task flow without a Floe account or Floe-operated proxy.

Success means a user can configure a provider, start a real streaming task, understand what the agent is doing, approve or stop consequential actions, reconnect to remote work, and verify the result from a native mobile interface.

## Positioning

Floe Agent combines provider-neutral AI orchestration with direct, user-owned access to Files, terminals, and VNC. Credentials and configuration stay under the user's Apple account and devices; Floe does not proxy inference or remote-control traffic.

## Operating Context

- Short mobile check-ins and approvals while an agent performs longer work.
- Focused iPad work with keyboard, pointer, split view, terminal, files, and remote desktop.
- Multiple model providers using OpenAI Responses, OpenAI Chat Completions, or Anthropic Messages wire formats.
- Documents and images opened from Files, including iCloud Drive and third-party file providers.
- SSH connections to computers the user owns or is authorized to operate, optionally through jump hosts, with VNC tunneled through SSH.

## Capabilities and Constraints

- Minimum deployment target is iOS/iPadOS 26.0; supported device family is iPhone and iPad.
- Launch languages are English and Simplified Chinese, following the system language.
- Provider metadata may sync through private CloudKit and API keys may opt into synchronizable iCloud Keychain. Conversations, hosts, terminal logs, VNC frames, and detailed audit output remain local by default.
- Approval modes are human approval, approval model, and time-bounded full control for one host. A separate catastrophic-action gate always intercepts high-confidence broadly destructive commands such as an unscoped `rm -rf`.
- The app may execute compiled on-device tools. Arbitrary model-provided code may run only on an explicitly authorized remote host.
- iOS background suspension is reported honestly; the app never promises an unmanaged SSH or VNC connection remains alive.
- Version 1 excludes accounts, ads, analytics, model resale, a hosted proxy, native downloaded plugins, arbitrary on-device execution of downloaded/model-generated code, RDP, VBA, ActiveX, and Office cloud collaboration. Installed Skills are validated declarative instruction/knowledge packages rather than executable native plugins.
- Public distribution excludes mainland China and France.

## Brand Commitments

- Product name: **Floe Agent**.
- Subtitle: **Private AI Agent Workspace**.
- Tagline: **Your models. Your files. Your machines.**
- The existing flowing cyan-blue-violet loop app icon remains the brand mark.
- Interface direction: Manus-like task progression combined with the quiet, professional, inspectable workflow of Codex, translated into native iOS rather than copied visually.
- Voice is calm, direct, precise, and never theatrical. Security states use concrete language and avoid false reassurance.

## Evidence on Hand

- A modular Swift 6 framework with provider wire adapters, persisted agent state machine, approval policies, CloudKit/Keychain configuration sync, SSH jump/PTY support, VNC Metal rendering, Files working-copy support, tests, and a successful internal TestFlight build.
- A production app icon at `FloeAgent/FloeApp/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png`.
- Floe Agent 1.2.0 (build 11), a signed App Store Connect/TestFlight upload, a paired GitHub unsigned IPA, and release evidence including tests, SBOM, license inventory, secret scan, and provenance.
- Current architecture and usage references in `docs/ARCHITECTURE_OVERVIEW.md`, `docs/USER_GUIDE.md`, and `docs/USER_GUIDE.zh-CN.md`; older validation and delivery reports remain historical evidence.
- No testimonials, customer logos, benchmarks, pricing claims, or hosted-service claims may be invented.

## Product Principles

1. Make the task, current state, next decision, and evidence legible at a glance.
2. Keep user credentials, files, and machines under user control.
3. Prefer honest interruption and recoverability over pretending work continued.
4. Make powerful access explicit, scoped, time-bounded, and stoppable.
5. Use native iOS conventions so professional depth does not become control-panel clutter.

## Accessibility & Inclusion

All production surfaces support Dynamic Type, VoiceOver, Increased Contrast, Reduce Motion, keyboard navigation, pointer input, light and dark appearance, portrait and landscape, and iPad multitasking. Every interactive target is at least 44×44 points, and status is never communicated by color alone.
