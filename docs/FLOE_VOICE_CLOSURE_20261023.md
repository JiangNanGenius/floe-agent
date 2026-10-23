# Floe voice closure — 2026-10-23

Baseline: `bcc50a01` (1.7.47 / 288). This is the next implementation batch;
the baseline's build and simulated-I/O tests do not establish actual microphone
or physical-device speech acceptance for these repairs.

## Contract

- Continuous voice opens directly in the current conversation. Ordinary chat
  persists normally; the existing Temporary Chat remains RAM-only. Fix voice
  identity propagation without replacing the Temporary Chat subsystem.
- Prove microphone buffers and recognizer readiness before Listening. Bound
  recoverable startup/restart attempts, surface real recognition failures and
  complete short utterances without depending exclusively on partial text.
- Replace the large output pack with the auditioned small enhanced speech model.
  Validate reference voices before exposing them. Previews synthesize live.
  Segment natural sentences and bound audio buffering.
- Show download bytes, percentage and measured transfer speed. Validate and
  load the replacement before retiring the old pack; retain recoverability,
  respect active leases and user selection changes, and resume cleanup safely.
- Normal cancellation is not a Memory error. Keep current valid data and fence
  stale callbacks. Preserve actionable errors for genuine read/write failures.
- User profile and SOUL.md retain current content, one previous activated copy,
  with no pending-confirmation step. Background automatic updates apply directly;
  keep the automatic-update switch and Restore Previous in More. Remove visible
  revision numbers/history. Changes and trimming are transactional and preserve
  edit-conflict checks; stale background generation cannot overwrite manual edits.
- Put Updates in a separate final group of the Settings sidebar. Consolidate
  the former Internal Prompts and General content-update entries there.
- Offer Import to Notes / Import to Task / Import to Canvas for ambiguous external shares and
  document-open requests. Explicit Notes/task pickers keep their destination.
  Task and Canvas imports support an existing target or a new one. Search task titles,
  preserve the selected task's draft, and never auto-send/run. Cancelling never
  creates an empty task or canvas.
  Preserve original file bytes, durable handoff receipts, retry idempotency,
  existing drafts and Temporary Chat restrictions; never auto-send a task.
- Keep normal product copy concise in English and Simplified Chinese. Raw
  model identifiers, provenance and diagnostics belong in opened details.

## Current milestones

| Milestone | State |
| --- | --- |
| Live continuous voice and direct entry | Code ready; full-App and actual microphone checks pending |
| Enhanced speech pack, voices and migration | Code ready; native repeated-synthesis repair verified on Mac; unified App qualification pending |
| Memory cancellation and bounded personalization history | Code ready; unified qualification pending |
| Settings navigation and message-owned speech errors | Code ready; App/UI checks pending |
| Notes/task/Canvas destination for inbound documents | Code ready; durable draft and Canvas recovery checks pending |
| Unified Swift 6/App build, behavior and UI/audio qualification | Pending |
| Versioned delivery, merge and cleanup | Pending |

## Completed component evidence

- The enhanced output model's Core ML prefill now uses bounded batches of 16
  rows and a single-row tail. Native Mac evidence covers 12 repeated sessions,
  12 varied sessions, three cancellation/reuse cycles, and six actual
  load/synthesize/join/release cycles. The last six sessions plateaued at
  0.24 MB growth per session, ending at 105.5 MB resident memory. These are native
  host measurements, not full-App iOS memory or physical microphone acceptance.
- Nine reference styles passed native Chinese, English, Japanese and mixed-text
  generation checks (36 outputs). Product previews remain live synthesis;
  qualification recordings are not bundled in the App.
- Physical-phone testing is currently deferred at the user's request. The Mac
  phone-audio relay was stopped; this does not qualify the new microphone path.

## Verification and closeout

Complete the coherent source batch before unified relevant tests and a full
local App build. Keep genuine microphone/audio proof separate from injected
buffers and Simulator UI proof. Cover cancellation, stale generations,
recognizer restart, quiet/short speech, Temporary Chat, playback ownership,
mixed-language synthesis, silent automatic updates, transactional history, migration interruption and
download recovery. Reuse prior unaffected acceptance; do not repeat the whole
matrix per small fix.

After qualification use an unused version/build and immutable source. Verify
internal TestFlight availability, external submission, unsigned GitHub assets
and Feather independently. No production App Store publication is authorized
by this batch. Retain exact artifacts/symbols and essential failure evidence;
merge/push main and remove only merged task-owned branches and unused outputs.
Remove completed milestones from the active list and retain their evidence.
