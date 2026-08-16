# Floe Agent 可日用 Alpha 大迭代计划

> [!NOTE]
> 历史 Alpha 执行计划。其中五 Tab 导航已经被 1.2.x 的“新建任务”统一工作台取代；当前结构以[架构总览](ARCHITECTURE_OVERVIEW.md)为准。

Status: approved for implementation

Branch: `agent/alpha-daily`

Base: `agent/m0-validation` at `579669f`

Distribution: internal TestFlight only after local and GitHub validation

## Outcome

Turn the validated framework and diagnostic shell into a coherent daily-usable Alpha: users can configure a real BYOK provider, stream a conversation, inspect an agent run, approve tools, work with Files, operate an SSH terminal, open a VNC session, perform basic image operations, and recover from disconnects from a polished native iPhone/iPad interface.

The iteration is intentionally broad. It must complete vertical user journeys rather than add disconnected abstractions. A partially implemented feature must clearly say unavailable; no demo data may masquerade as live state.

## Definition of done

A build is an Alpha candidate only when all are true:

- Fresh install can complete onboarding without creating a Floe account.
- A user can add and test at least OpenAI, Anthropic and one compatible/custom provider, choose a model, and optionally enable iCloud Keychain sync for the secret.
- A user can create a conversation, receive real streamed text, cancel, retry, switch model, and see useful provider errors.
- A run thread persists assistant messages, tool events, approvals, evidence, usage and terminal outcomes across relaunch.
- A user can create a host, accept an SSH host key, connect to a real PTY, resize, paste, reconnect, and clearly see disconnected/unknown state.
- VNC tunneled through SSH can connect, render, accept touch/keyboard input and stop immediately.
- Files import/export uses security-scoped access and working copies; local image crop/rotate/resize/convert/compress is usable and undoable.
- Approval modes are scoped and auditable. Full control is time-bounded to one host, while the catastrophic command gate remains independent.
- iPhone and iPad use the locked information architecture and pass core VoiceOver, Dynamic Type, dark mode, Reduce Motion and keyboard checks.
- Tests, secret scan, Release build and both simulator smoke runs pass with no known P0/P1 defect.

## Product scope

### Navigation and app environment

- Replace the M0 diagnostics root with a production `AppEnvironment` that owns persistence, provider registry, conversations, runs, approvals, files and remote sessions.
- iPhone tabs: Home, Chat, Files, Hosts, More.
- iPad: three-column split view with functional sidebar, task/session list and detail.
- Keep diagnostics reachable from More in debug/internal builds.

### Persistence v3

- Add an append-only schema v3 migration; preserve and test v1/v2 data.
- Persist conversations, messages, typed multimodal content parts, attachments, run events, usage, structured errors and checkpoints.
- Add interfaces: `ConversationStore`, `RunStore`, `ProviderAdapterFactory`, `ImageProviderAdapter`, `RemoteSessionRegistry`.
- Never persist raw API keys, passwords or private-key passphrases in the database or logs.

### Providers and real chat

- Provider presets: OpenAI Responses, OpenAI Chat Completions, Anthropic Messages, Volcengine Ark-compatible, Alibaba Model Studio-compatible and custom compatible endpoint.
- Provider editor includes protocol, base URL, API key, non-sensitive headers, model, capability flags, connection test and optional iCloud Keychain sync.
- Use `/models` discovery where supported and a safe manual-model fallback where it is not.
- Support streaming text, structured content parts, attachments, cancel, retry, disconnect recovery, rate-limit errors, context overflow, usage and model switching.
- Ensure wire contracts are fixture-tested without live credentials.

### Agent run and approvals

- Represent every run as a chronological, foldable event thread.
- First enabled tools: read-only Files access, basic image operations and command execution on an explicitly authorized host.
- Approval UI shows action, scope, host/path, risk rationale, expiry and exact decision.
- Approval modes: human, approval model, and full control for a single host and explicit duration.
- Catastrophic gate always blocks obvious broadly destructive commands independently of full control. Avoid simplistic substring-only parsing; normalize shell form and fail closed for high-confidence destructive patterns.
- Persist decision and evidence without secret-bearing payloads.

### SSH, terminal and VNC

- Complete host CRUD, Keychain-backed password/key secret references, jump hosts and TOFU host-key review.
- Integrate SwiftTerm as a real PTY: keyboard, paste, selection, resize and session ownership outside the view lifecycle.
- Add stateful reconnect behavior and honest connected/disconnected/suspended/unknown states.
- Complete VNC through SSH: status, render, touch/keyboard input, FPS indicator, disconnect and emergency stop.
- Never claim iOS background execution guarantees the platform does not provide.

### Files, documents and images

- Implement document picker, security-scoped bookmark recovery, recent files, Quick Look, working-copy writeback and Save As.
- This iteration provides safe Office open/preview/writeback infrastructure, not a fake full Office editor. Collabora integration remains later work.
- Implement local image import, preview, undo, crop, rotate, resize, format conversion, compression, basic adjustment and metadata removal.
- Add remote image adapter foundations for OpenAI, Volcengine and Alibaba; expose only operations actually supported by the selected provider.

### UI and localization

- Follow `PRODUCT.md`, `DESIGN.md` and `docs/design/reference/`.
- Home: compact new-task composer, active tasks, pending approvals, recent sessions and connection status.
- Chat/run detail: streamed answer plus assistant/tool/terminal/file/approval/error/checkpoint evidence in one timeline.
- Use system navigation and SF Symbols. Apply glass only to chrome and composer; keep content opaque and readable.
- Ship English and Simplified Chinese strings. No hard-coded user-facing strings in production views.

## Explicit non-goals for this iteration

- Full Collabora/Office editing bundle.
- Autonomous computer-use over VNC.
- Rust helper or downloaded plug-in runtime.
- Floe account, backend, hosted proxy, analytics, ads, IAP or model resale.
- Public TestFlight, App Store submission or distribution-region changes.
- Automatic merge of existing pull requests.

## Verification gates

1. Run the existing Swift package test suite before structural work.
2. Compile/test after every implementation phase; do not allow a long-lived broken main branch.
3. Add migration, provider fixture, cancellation, recovery, approval, SSH state and image-pipeline tests.
4. Add iPhone and iPad UI smoke tests for empty/loading/streaming/approval/error/disconnected states.
5. Run `scripts/secret_scan.sh`, pin/license checks and the Release build.
6. Validate on iPhone and 13-inch iPad simulators. Record limitations that require a physical device.
7. Push implementation commits and let GitHub CI pass.
8. Do **not** trigger Xcode Cloud during implementation. After Codex review and all gates pass, manually run it once, confirm the instance stops, then place build `1.0 (3)` in `Floe QA`.

## Stop conditions requiring owner input

Pause only for a decision that changes legal/export compliance, App Store distribution, paid infrastructure, new account/backend collection, secret disclosure, or destructive repository history. Ordinary implementation choices should follow the committed product and design documents.
