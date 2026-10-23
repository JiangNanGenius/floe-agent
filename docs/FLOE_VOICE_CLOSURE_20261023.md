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
| Apple external beta review | Build 289 submitted to existing publictest1; independently confirmed WAITING_FOR_BETA_REVIEW |

All implementation, qualification, distribution and cleanup work in this batch
is complete. The only remaining external state is Apple beta review. No timer
or automatic production release was created.

Validation uses the one existing canonical iPad Simulator. The user explicitly
requires Simulator-only agent validation and prohibits using their physical
iPhone. Actual physical microphone, on-device inference and subjective voice
quality remain unverified limitations, rather than a hardware waiting gate.

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
- The user requires Simulator-only validation. The Mac phone-audio relay is stopped;
  no physical-device voice acceptance is claimed.
- Full Swift 6 App/test-target object compilation passed with Xcode 27.1
  (`27A9275`) at `1e34d43e`. All 407 scoped App-host checks passed with
  zero failures, skips or omitted declared functions. Coverage includes final
  speech ownership, voice startup/restarts/cancellation, model migration and
  cleanup, Memory cancellation, transactional personalization retention,
  import destination ownership, durable draft reconciliation and Canvas recovery.
  Original failed runs and crash evidence remain retained.
- Hardware-dependent resource readings are controlled only in synthetic lease
  tests; separate checks prove zero-memory and critical-thermal refusal preserves
  installed files and leaves no lease. Production defaults continue reading the
  actual device. This does not qualify physical speech inference.
- The canonical iPad Simulator's actual Files share extension saved the synthetic
  PDF, and Floe offered Notes, Task and Canvas. Task search and existing/new
  Canvas choices were observed; cancellation preserved the original draft and
  attachment. The fixture was moved to recoverable private evidence afterward.
  These checks do not prove destination commit/recovery or physical-device I/O.
- Final iPad picker inspection confirmed readable labels for unnamed tasks and
  preserved the original draft after cancellation. Compact root navigation and
  speech settings were inspected on the same canonical iPad; this is not an
  actual iPhone geometry check. All task-owned synthetic inputs were moved into
  recovery storage, and the task-started Simulator was shut down afterward.
- Generic `iphoneos` Release compilation passed at `855ec031` with Xcode 27.1.
  The arm64 App and 13 symbol bundles were saved immediately. All five App/
  extension products report 1.7.48 (289), `iphoneos`, and matching symbols.
  This was the pre-archive milestone. The final archive below retained 14
  symbol bundles. Its generic product copy and build cache were retired after
  verified recovery packaging and distribution; no rebuild is pending.

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

## Build 289 archive milestone

The immutable `v1.7.48` tag resolves to
`855ec031a396e6a5c4d62017c9bad527349ee62a`. Local Xcode 27.1
(`27A9275`, iphoneos 27.1) archive and package checks passed for all five
App/extension bundles at 1.7.48 (289). The App and 14 symbol bundles were
preserved before packaging. The private transport is 975,150,016 bytes with
SHA-256 `7c51a6107dc0368518ec6e7b0c1fa3a19259f9aafabfaf1219eb26378f6f038e`.
This milestone is not signing, Apple processing, beta availability or public
installation acceptance. The formal App Store submission is unchanged.

The finished archive build cache was removed after artifact export and an
open-file check: 8,540,770,304 allocated bytes; measured free-space increase
8,493,486,080 bytes. The existing six Simulators are all shut down; none was
created, reset or deleted. Existing app data and other owners' devices remain
protected. Public beta reviewer text is recorded separately from the immutable
App source in `docs/public-beta/build289/REVIEW_NOTES.txt`.

## Build 289 completed delivery

- Internal TestFlight: signing/upload run [39913579809](https://github.com/JiangNanGenius/floe-agent/actions/runs/39913579809)
  completed. Independent inspection confirmed Apple `VALID`, unexpired and
  `IN_BETA_TESTING` in the existing Floe QA group.
- External TestFlight: the existing owner Safari session submitted Build 289
  once to `publictest1`. GET-only inspection
  [39918186738](https://github.com/JiangNanGenius/floe-agent/actions/runs/39918186738)
  independently confirmed group attachment, `WAITING_FOR_BETA_REVIEW`, one
  `pending_review` submission and no reported issues. This is submission,
  not approval or external installability. The existing public link remains
  [unchanged](https://testflight.apple.com/join/nz6qeT2J).
  The earlier API attachment attempt returned 403 before submission; its failure
  is retained. No credential permissions were expanded or duplicate submission made.
- [Stable unsigned Release v1.7.48](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.7.48)
  is published and latest. Its canonical IPA is 811,867,163 bytes, SHA-256
  `c8982b1e8c4b8615af6cf521c6226998ba432d14fc816c820cc0b002ccda3117`.
  Independent download verification passed source/tag binding, checksum,
  arm64 iPhoneOS executable, bundle version and latest pointer checks.
- Publishing run [39915579553](https://github.com/JiangNanGenius/floe-agent/actions/runs/39915579553)
  completed its awaited Feather reusable job. Independent live feed read-back
  matched the exact IPA URL, size, source `855ec031` and checksum. Public assets
  contain only the unsigned IPA, checksum and minimal provenance.
- Source is merged and pushed to main; the completed task branch was removed
  locally and remotely after ancestry checks. The annotated release tag remains
  immutable. Later reviewer-copy, policy and completion records are separate
  from the frozen App artifact source. Production App Store state is unchanged.

## Final retained artifacts and cleanup

The current unsigned IPA/checksum, exact original App ZIP, normalized recovery
transport with all 14 DWARF symbol bundles, provenance, archive metadata,
original failures and focused qualification evidence remain retained. Build 288
is retained as the necessary rollback package. Full ZIP CRC and SHA-256 checks
passed before redundant uncompressed products were removed.

Task-owned Simulator DerivedData, finished device/archive build cache, transfer
staging, obsolete generic device product and redundant uncompressed archive/App
copies were removed. Measured free-space increases at those cleanup boundaries
were 7,117,766,656 internal bytes, 8,493,486,080 internal bytes, and respectively
2,449,408, 2,168,156,160 and 2,000,773,120 external bytes. These are observed
filesystem deltas, not a claim that nominal allocated sizes were all reclaimed
on APFS. Shared useful dependency caches and qualified model inputs are retained.
The private transport draft was deleted after both consumers finished; the
public release and immutable tag were independently checked afterward.

Final inventory confirms no booted Simulator and no Device Hub, QuickTime,
iPhone Mirroring or xcodebuild process. Only the existing canonical iPad was
used; no Simulator was created, cloned, erased or deleted. Existing Simulator
apps/data, independent worktrees and the user's physical phone remain untouched.
