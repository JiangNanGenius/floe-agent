# WorkBuddy greedy implementation plan

This plan tells WorkBuddy how to maximize completed, testable product value in one implementation run. “Greedy” means continue through the next safe, useful vertical slice whenever time and build health allow. It does not mean bypassing safety gates, inventing capabilities, or triggering cloud distribution.

## Operating contract

- Work only on `agent/alpha-daily` in `/Volumes/TECLAST/IOS AI AGENT`. Do not create another worktree, clone, repository copy or alternate workspace.
- Read `PRODUCT.md`, `DESIGN.md`, `docs/ALPHA_DAILY_PLAN.md`, existing audit/validation reports and package structure before editing.
- Preserve user changes and MPL-2.0 licensing. Never print, commit or transmit secrets.
- Prefer small compilable commits with descriptive messages. Push the branch after meaningful checkpoints.
- Do not merge PRs, rewrite published history, change App Store regions, trigger Xcode Cloud/TestFlight or make legal/export declarations.
- Do not stop for cosmetic ambiguity. Use the locked design direction and native iOS conventions.
- Do not use placeholder live data. Empty, unavailable and unsupported are legitimate states.

## Phase 0 — Establish truth and baseline

1. Confirm clean worktree, current branch and remote.
2. Inventory modules, tests, M0 diagnostics, package dependencies and current schemas.
3. Run the baseline package tests and a simulator build; record exact commands and results.
4. Convert the plan into a short internal checklist and keep it current.

Gate: existing behavior is understood and baseline failures are documented before new code.

## Phase 1 — Production shell and persistence v3

1. Introduce a production `AppEnvironment` with explicit dependency ownership and test doubles.
2. Add append-only schema v3 migration for conversations, messages, content parts, attachments, run events, usage, structured errors and checkpoints.
3. Add store interfaces and SQLite implementations with deterministic ordering and cancellation-safe writes.
4. Add migration/relaunch/recovery tests, including v1/v2 fixtures.
5. Keep M0 diagnostics accessible under More for internal builds.

Gate: package tests and app compile pass; old data migrates without loss.

## Phase 2 — Provider configuration and discovery

1. Implement provider factory and presets for OpenAI Responses/Chat, Anthropic Messages, Ark-compatible, Alibaba-compatible and custom.
2. Build provider list/editor using metadata in the database/CloudKit and secrets in Keychain.
3. Add connection test, capability flags, non-sensitive headers, model discovery where safe, and manual model fallback.
4. Extend streaming request/response types for typed multimodal content, usage and structured errors while retaining current compatibility.
5. Add fixture-based contract tests for every protocol and redaction tests for logs/errors.

Gate: provider configuration is usable without hard-coded credentials and contract tests pass offline.

## Phase 3 — Real conversation and agent thread

1. Implement conversation list/detail, message composer, attachments and persistent streaming.
2. Support cancel, retry, model switch, partial-output recovery, rate-limit/context errors and checkpoints.
3. Model assistant, tool, terminal, file, approval, error and status events as one chronological thread.
4. Connect the first tools: read-only Files, local image operations and authorized host commands.
5. Implement approval decisions, scoped full control and independent catastrophic command gate with tests.

Gate: at least one real provider can complete a persisted streaming conversation; fixture paths cover all providers.

## Phase 4 — Replace diagnostics UI with the daily-use experience

1. Implement locked iPhone tabs and iPad three-column hierarchy.
2. Build Home workbench, task list, thread detail, composer, provider setup, empty states and actionable errors.
3. Follow the design craft floor: system typography, semantic colors, 44pt targets, limited glass, opaque reading surfaces, native navigation, no nested-card dashboard.
4. Add Dynamic Type, VoiceOver labels/actions, keyboard shortcuts, pointer support, Reduce Motion and dark mode.
5. Use a string catalog for English and Simplified Chinese. Eliminate hard-coded production labels.
6. Add previews or fixtures for empty/loading/streaming/approval/completed/failed/disconnected states.

Gate: core journeys work on both iPhone and 13-inch iPad layouts without clipping or inaccessible controls.

## Phase 5 — SSH terminal and VNC completion

1. Complete host CRUD, Keychain secrets, jump hosts and explicit TOFU host-key review.
2. Wire SwiftTerm to real PTY streams, including paste, resize, selection, keyboard and session retention outside view lifecycle.
3. Add reconnect and honest background/suspended/unknown behavior.
4. Wire VNC over SSH with render/input/status/FPS/disconnect/emergency stop.
5. Add state-machine, reconnect, host-key and catastrophic-gate tests.

Gate: a configured host can be connected, operated and stopped; no silent host-key acceptance.

## Phase 6 — Files and image workflows

1. Implement Files picker, bookmark recovery, recent files, Quick Look, working copies, Save As and conflict-safe writeback.
2. Implement local image preview, undo, crop, rotate, resize, conversion, compression, adjustment and metadata removal.
3. Add `ImageProviderAdapter` foundations and capability-aware remote operations for OpenAI/Ark/Alibaba where their current adapter contract supports it.
4. Label unsupported remote operations rather than emulating success.
5. Add bookmark, image determinism, cancellation and writeback tests.

Gate: a user can round-trip a local document and image without losing the source or permission.

## Phase 7 — Hardening and handoff

1. Resolve compiler warnings introduced by this branch.
2. Run full package tests, app unit/UI tests, iPhone and iPad simulator smoke runs, Release build, secret scan, pin and license checks.
3. Inspect logs and persisted fixtures for secrets/private content.
4. Audit UI against `DESIGN.md`; fix clipped text, inconsistent states, contrast and focus order.
5. Push the branch and verify GitHub CI. If CI fails, fix it before stopping.
6. Write `docs/workbuddy/IMPLEMENTATION_REPORT.md` using `REVIEW_HANDOFF.md`.

Gate: report contains commit SHAs, exact test evidence, implemented journeys and honest remaining gaps.

## Priority when time is constrained

Maintain vertical coherence in this order:

1. Production shell + persistence + provider + real streaming chat.
2. Approval/run thread + polished iPhone/iPad UI.
3. SSH terminal production path.
4. Files/local images.
5. VNC refinements and remote image adapters.

Never leave the repository broken to begin a lower-priority phase. If a lower-priority item cannot be completed honestly, leave a compile-safe interface, explicit unavailable UI, tests for the boundary, and document the gap.
