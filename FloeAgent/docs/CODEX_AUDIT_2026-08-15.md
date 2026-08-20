# Floe Agent Codex audit — 2026-08-15

## Scope

- Reviewed WorkBuddy's `afb0bc7..1a7a6e3` implementation diff and the full affected execution paths.
- Built the native iOS application, exercised the onboarding and model-settings flows, and reviewed the iPad/iPhone presentation against the supplied screenshots and Floe design rules.
- Kept the existing `agent/alpha-daily` worktree and preserved the existing shared Xcode scheme.

## Product and reliability corrections

- Restored the normal provider-settings model refresh action. It resolves an existing provider key from local or synchronized Keychain storage, keeps an entered key in memory until Save, shows progress/errors, and exposes refresh from both the provider form and searchable model picker.
- Replaced unreliable model-row tap handling with explicit native selection toggles and made Home observe provider/model changes immediately after the settings sheet saves.
- Added system speech-to-text to the shared chat composer with localized permission copy, partial transcription, explicit stop state, on-device recognition when available, and audio-session cleanup.
- Made the iPad Home experience chat-first: the middle column is the conversation list and the detail column is the active thread or new-task composer.
- Kept the composer editable without a configured model. Only AI Send is gated, and the setup guide remains directly accessible.
- Preserved dismissible model editing and added readable 32K, 64K, 128K, 256K and 1M context presets plus output-token presets.
- Fixed missing app-target linkage/imports, Swift 6 isolation errors, settings bindings, workspace async calls, UI-test packaging, and localization/privacy resources that prevented a native build or test run.
- Set build `1.0 (6)` and declared only exempt standard encryption so App Store Connect does not require a redundant export-compliance questionnaire for every upload.
- Made interactive setup dismissal synchronously flush its launch marker before the durable preference write, so an immediate force-quit cannot resurrect onboarding.

## Security corrections

The diff scan found eleven reachable issues; all were corrected before release:

1. Removed model-facing on-device JavaScript execution from production registration. Explicit test-only opt-in remains.
2. Remote Python approval now displays the exact script before execution.
3. SSH stdout and stderr now share a bounded output budget.
4. Markdown quote parsing has a recursion-depth bound.
5. Streaming Markdown parsing has a bounded working window.
6. Workspace approval is bound to the workspace that was visible when approval was requested.
7. Workspace search applies the same secret-file denylist as direct reads.
8. Tool execution receives and enforces the canonical runtime scope instead of trusting duplicate JSON arguments.
9. SSH timeout/cancellation watchers are cancelled on completion and no nil-token watcher is created.
10. Workspace listing/search enumeration is bounded before sorting or returning results.
11. Patch coordinates use overflow-safe arithmetic and reject malicious values without trapping.

Additional checks confirmed provider deletion removes its Keychain secret and SSH/VNC credentials use distinct, device-local Keychain accounts.

## Verification evidence

- Swift package suite: 361 tests passed across 13 test runs (the opt-in live credential test is skipped in ordinary offline runs).
- Debug application build: passed for the iPad Air 13-inch simulator with Swift 6 complete concurrency checking.
- UI automation covers first-launch skip, pull-down dismissal, relaunch persistence, guide reopening, model-free composer access, voice-entry presence, and provider-settings model refresh.
- Live Volcengine Ark adapter smoke: `/models` discovery and a real streamed turn passed using a credential injected from macOS Keychain.
- Live iPad Air 13-inch app flow: added Volcengine, discovered 129 models, searched and selected `doubao-seed-2-1-pro-260628`, saved it as the default, sent a Home task, reached `completed`, and persisted the assistant reply `FLOE_LIVE_UI_OK`.
- Final generic-device Release build passed. TestFlight processing results are recorded in App Store Connect build history.

## Honest remaining device checks

- Speech recognition quality and microphone routing require a physical device; Simulator validates the UI and permission surface only.
- Live SSH/VNC, iCloud/CloudKit propagation, and providers other than the verified Volcengine account still depend on reachable user-owned hosts/accounts and are intentionally not simulated as successes.
- User-authored local JavaScript/Python execution needs a separate, explicitly invoked isolation design. Model-generated code is deliberately not executed on iOS.
