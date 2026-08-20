# Floe Agent Daily-Use Alpha — Codex Audit

**Audit baseline:** `401a18062b43806a16667a4bed4278b9dadee202`  
**Date:** 2026-08-14  
**Scope:** WorkBuddy changes since `892879b5d3230f5a50abd7f1fbbd4dea9f02ac99`  
**Status:** Independent pre-fix review; findings below describe the audited baseline, not later remediation.

## Post-review implementation update

The same working session remediated the release-blocking navigation and approval defects and the reportable security findings discovered in the baseline. The implementation now includes:

- one router-owned conversation-open path for iPhone and iPad, including selected-run projection;
- a real iPad Chat detail surface and an intentional Home detail surface;
- exact pending `ToolCall` transport from runtime snapshot to approval UI, plus scope/expiry enforcement before execution;
- separate, device-local SSH and VNC Keychain namespaces;
- current iCloud preference reflected in provider secret references, transient connection testing, provider-secret deletion, URL-user-info rejection, and secret-header rejection;
- bounded model, image, SSE, provider-event, payload, and streamed-text processing, including HTTPS/private-network image URL policy and redirect revalidation;
- exact configured-key redaction before provider errors enter SQLite;
- live-only stream deltas with one canonical final assistant message;
- fail-closed catastrophic-gate fallback and a blocking persistence-recovery state;
- UTType-based attachment classification so imported images reach the editor;
- a true SwiftTerm `UIViewRepresentable` PTY surface with raw input and resize forwarding;
- a redesigned, localized onboarding flow and iPad task workbench.

The formal security diff scan of baseline `401a180` closed with eight reportable findings (six medium, two low). All eight have corresponding remediations in this working tree. Two unreachable architectural candidates—approval-object mismatch and provider-image URL SSRF—were also remediated before production tool/image wiring can activate them.

Still open after this batch: production agent tool runners remain intentionally undiscoverable, recent-file restoration is not implemented, VNC connection state still needs handshake-owned transitions, and product-selectable approval modes still need a settings surface. These remain the next milestone rather than being represented as completed behavior.

## Executive summary

The Alpha has a materially stronger foundation than M0: schema v3 is append-only, provider secrets stay behind Keychain references, the app uses semantic system colors, remote session ownership is no longer tied to view lifetime, and unsupported Office/remote-image behavior is generally labelled honestly. A local iOS 27 Release simulator build for the 13-inch M4 iPad completed successfully.

It is not yet a usable daily Alpha. The primary Chat journey does not navigate into a newly-created conversation, the iPad detail column never renders selected content, no production agent tool has a working executor, and approval UI reconstructs a different local-scope call instead of showing the exact pending host/path scope. These are release-blocking because they affect the product's main journey and its security boundary.

## Scorecard

| Area | Score | Notes |
| --- | ---: | --- |
| Accessibility | 2/4 | Semantic labels and minimum targets are present, but no running VoiceOver/Dynamic Type verification or UI-test bundle exists. |
| Performance | 2/4 | Session buffers are bounded, but every streamed text delta becomes a durable event and a UI row; terminal refresh repeatedly decodes the full buffer. |
| Appearance and theming | 3/4 | Good semantic palette and system materials; the information architecture and empty states still feel unfinished. |
| Platform conformance | 2/4 | Native SwiftUI navigation and document picker are used, but the terminal is not a terminal emulator and some navigation state is disconnected. |
| Adaptivity | 1/4 | Five-tab phone shell exists; the advertised iPad workbench has a permanently static detail column. |
| **Total** | **10/20** | **Acceptable foundation, not Alpha-ready.** |

## Findings

### P0 — Primary conversation flow cannot open the created thread

- `FloeAgent/FloeApp/App/FloeAgentApp.swift:71-80` creates an unbound `NavigationStack` for each tab.
- `FloeAgent/FloeApp/Chat/ConversationListView.swift:107-112` only assigns `selectedConversationID`; it neither activates the row's `NavigationLink` nor appends to a bound navigation path.
- `FloeAgent/FloeApp/Home/HomeWorkbenchView.swift:158-170` has the same behavior after sending a task or opening an active run.

Impact: the main “create/send task → see agent thread” journey stops at the list/root screen on iPhone. This is a release blocker.

Remediation: make `AppRouter` own the Chat navigation path, expose a single `openConversation` operation, and route Home, Chat list, and run selection through it. Keep iPad selection separate from phone path pushes.

### P1 — iPad three-column detail is permanently a placeholder

`FloeAgent/FloeApp/App/FloeAgentApp.swift:122-130` always returns `ShellPlaceholderView`; selected conversation, terminal, VNC session, and file IDs are never projected into column three.

Impact: the 13-inch iPad experience described in the implementation report is not implemented. The large-screen workbench cannot show master and detail together.

Remediation: render a destination-specific detail from router selection, beginning with `ThreadDetailView` for Chat and honest empty states when nothing is selected.

### P1 — Agent tools are advertised through a catalog but cannot execute

- `FloeAgent/FloeApp/Remote/ConversationCenter.swift:118-138` always injects `CatalogToolExecutor`.
- `FloeAgent/Sources/FloeAgentRuntime/AgentRuntime.swift:39-56` always returns a failed result: “No runner registered”.
- No production `ToolCatalog.register` call or application executor was found.

Impact: the app can stream model text, but it is not yet an agent that can operate Files, images, SSH, or VNC. Claims that these abilities are connected to agent execution are inaccurate.

Remediation: add an application-owned executor and an explicit allowlisted descriptor registry. Each runner must validate its typed arguments and `ToolScope`, enforce the selected host/path, pass catastrophic command checks, and return bounded/redacted output. Until a runner exists, do not expose its descriptor to a provider.

### P1 — Approval UI loses the exact tool-call identity and scope

- `FloeAgent/Sources/FloeAgentRuntime/ConversationRunService.swift:139-146` persists only tool name and reason.
- `FloeAgent/FloeApp/Remote/ConversationCenter.swift:292-323` rebuilds a new call from `{}` with `.local` scope and uses the event UUID as the call ID.

The runtime later executes its original pending call, so the user can approve a card that displays a materially different scope from the operation that will run.

Impact: this violates the product's explicit-authorization boundary for remote hosts and files. It is security-sensitive even before real runners are connected.

Remediation: carry the original pending `ToolCall` and reason in the service snapshot, use that exact value for display and approval, and persist a safe structured summary containing original call ID and scope. Never reconstruct executable authority from a display event.

### P1 — Toggling iCloud Keychain can leave a stale secret reference

`FloeAgent/FloeApp/Providers/ProviderEditorViewModel.swift:99-106` reuses an existing `SecretReference` wholesale. When the user changes `syncEnabled`, the saved profile can retain the previous `synchronizable` flag while the secret is moved to the other Keychain domain. `ConversationCenter` then resolves credentials using the stale flag.

Impact: a correctly-entered API key may appear missing after Save; the configuration metadata and secret location disagree.

Remediation: preserve only the stable Keychain account and always rebuild the reference with current `syncEnabled`. Add a test for local→iCloud and iCloud→local edits.

### P1 — Picked images are classified as documents, so image editing is unreachable

`FloeAgent/FloeApp/Files/FilesCenter.swift:61-79` reads the content type but always creates `AttachmentRef(kind: .document)`. The Files UI only offers the image editor for `.image`.

Impact: PNG/JPEG import succeeds but cannot enter the shipped image-edit path.

Remediation: infer attachment kind from `UTType` conformance and test at least PNG, JPEG, plain text, PDF, and unknown binary types.

### P1 — The terminal surface is not SwiftTerm

`FloeAgent/FloeApp/Terminal/TerminalView.swift:71-119` is a `ScrollView` containing `Text` plus a separate `TextField`. No SwiftTerm view, delegate, ANSI parser, PTY-size callback, or terminal keyboard bridge is used by the app.

Impact: ANSI/cursor applications, interactive shells, selection, terminal resizing, and common control keys do not behave as a terminal. The implementation report should not call this a SwiftTerm surface.

Remediation: bridge SwiftTerm through `UIViewRepresentable`, feed the bounded session byte stream into the emulator, send terminal input as bytes, and propagate terminal dimensions to the SSH channel.

### P1 — Streamed assistant text is persisted and rendered twice

`ConversationRunService` appends one `.assistantText` run event per provider delta and later persists the completed assistant message. `ThreadDetailView` renders persisted messages and all run events, while also showing the live stream tail.

Impact: completed replies can appear duplicated, long answers create hundreds or thousands of rows, and SQLite/UI work scales with token chunks instead of messages.

Remediation: coalesce durable stream checkpoints, render a single live assistant block while running, and render only the canonical final message after completion. Preserve a bounded partial recovery checkpoint for interrupted runs.

### P2 — New-task attachment control is inert

The Home composer shows an attachment affordance but does not open the picker or associate an attachment with the created conversation.

Impact: the Home surface promises a workflow that cannot be completed.

Remediation: wire the control to the shared document picker and pass selected attachment IDs into message parts, or hide it until that data path is complete.

### P2 — Recent files are process-memory only

`FilesCenter.recentFiles` starts empty and is never restored from the attachment store.

Impact: relaunch loses the Files home history even though the v3 schema has attachment persistence.

Remediation: persist imported attachment metadata and reload it during bootstrap; retain security-scoped bookmark refresh behavior.

### P2 — VNC can be marked connected before the protocol handshake succeeds

The session center updates its registry after asking the owner to connect, while the owner reports transport/protocol state asynchronously.

Impact: UI and recovery metadata can show a usable VNC session during a failed or incomplete handshake.

Remediation: make the owner publish authoritative state transitions and update the registry only from those transitions.

### P2 — Approval modes are not product-configurable

Every conversation run uses `HumanApprovalPolicy()` regardless of the planned human/model/full-control modes. Full-control expiry and local-auth activation are not surfaced in the production shell.

Impact: the app does not implement the requested control modes. This is safer than silently enabling them, but incomplete.

Remediation: model the execution mode explicitly, default to human approval, require local authentication and visible expiry for full control, and keep the catastrophic gate independent of the mode.

### P2 — Errors and bootstrap fallback are too quiet

Conversation reload errors are swallowed, and `AppEnvironment` can fall back to an in-memory database while bootstrap continues. The UI does not consistently gate production actions on `persistenceReady`.

Impact: data can appear missing without explanation, and a user may act in a non-durable session.

Remediation: expose a recoverable persistence/reload error state, label in-memory fallback, and disable durable/remote actions until bootstrap has completed.

### P2 — Provider connection test can leave an orphan Keychain secret

Testing a connection persists the entered API key before the user taps Save. Dismissing the editor can leave a secret with no saved provider profile.

Impact: unnecessary credential residue and confusing later sync status.

Remediation: use the entered key as an in-memory test credential; write Keychain only during Save, or remove the staged secret on cancel.

### P3 — Local Release warnings and stale comments

The Release build reports unnecessary `await` expressions in SSH/terminal code and an unused VNC click variable. Several shell comments still say T02–T05 will replace placeholders although those phases have landed.

Impact: low, but warnings hide future regressions and comments mislead reviewers.

## Positive evidence

- Local command-line Release build succeeded for `platform=iOS Simulator` on `iPad Air 13-inch (M4)` with iOS 27.
- The theme uses semantic colors and system materials rather than fixed light-mode surfaces.
- Keychain references, secret redaction, append-only migrations, bounded terminal output, explicit host-key handling, and a catastrophic-action gate are present.
- Remote session owners live above views, so navigation alone does not intentionally kill SSH/VNC sessions.
- Unsupported Office editing and unsupported remote-image operations are labelled instead of faking completion.
- WorkBuddy kept the branch organized into reviewable commits and pushed a green CI baseline.

## Remediation order

1. Fix navigation and real iPad detail projection.
2. Preserve exact approval identity/scope and repair Keychain sync references.
3. Make image import reach the image editor and remove duplicated stream rendering.
4. Add real, scoped tool runners; keep unimplemented tools undiscoverable.
5. Replace the faux terminal renderer with SwiftTerm and reconcile VNC state from owner callbacks.
6. Add an app-target UI smoke suite for iPhone and 13-inch iPad, then run local Release, GitHub CI, Xcode Cloud, and TestFlight build 3 in that order.

## Distribution and cloud-build guardrails

- Do not trigger Xcode Cloud while local Release or GitHub CI is red.
- Stop or cancel superseded cloud workflows so compute hours are not left running.
- TestFlight/public availability must exclude mainland China and France, per project distribution requirements.
