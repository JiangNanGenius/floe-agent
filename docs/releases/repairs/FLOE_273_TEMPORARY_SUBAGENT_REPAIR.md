# Floe 1.7.32 (273) — temporary chat, CAD, subagents, crashes and Linux-guest repairs

Status: **local qualification complete; exact-source device archive built and delivered to internal Floe QA (2026-10-15).**
The arm64 Simulator App compiled with Xcode 27. `project.yml` and its generated
project declare **1.7.32 (273)**. The final focused App run passed 15 XCTest cases
and 113 Swift Testing cases in 13 suites. Earlier component, real-guest and UI
proofs are recorded at their actual source stage below; this is not a claim that
the entire historical matrix was rerun on one final binary. The candidate device
archive was built from the frozen source `29937dc025267bacd89434cc092b3906c99b93ee`
(tag `v1.7.32`), signed/uploaded through the repository local-artifact workflow
without an App rebuild, and independently read back as Apple build
`f0b719ad-c418-4c50-bba0-48ab45aa4147` `VALID`, unexpired, `IN_BETA_TESTING` in the
existing internal Floe QA group. No external beta, production or content publication
was performed.

This note records user-visible changes from the temporary-chat / full-subagent / crash /
Linux-guest performance round, together with the honest validation matrix: what was
executed, at what scope, and what is still pending.

## 1. Temporary chat (RAM-only) complete behavior

- **Normal chat surface, not a separate mode.** Temporary chat reuses the ordinary
  message list, composer and model picker, and adds a compact top-header entry/badge menu
  instead of a persistent banner. Voice input stays available; attachment staging is not.
  The launchpad entry starts a temporary chat directly and carries the typed launchpad text
  into it.
- **Storage ownership.** A verified-empty ordinary conversation converts in place; a
  conversation that owns any durable resource (messages, files, workspace, staged
  attachment, run/settings) starts a separate RAM-hosted session and is never modified.
  Temporary conversations, runs, queued inputs, drafts and personal-query pagination
  snapshots live in RAM-only stores; they stay out of history, persistent drafts, memory
  writes, notifications and the app's shared on-disk caches. Force-quit/termination does
  not restore them.
- **Read-only tool ceiling with real discovery.** Every currently authorized tool that is
  a verified safe read stays available (public web retrieval, personal-data queries,
  discovery/skill reads, configured inspections). Mixed tools are narrowed to their
  audited read actions in the model-facing schema and re-checked at execution; writes,
  sends, code execution, installs, VM lifecycle, background jobs and delegation fail
  closed with an explicit reason. Unconfigured provider-backed search tools are not
  advertised; the previous fixed web pair could collapse to an empty catalog.
- **Lifecycle.** Backgrounding/locking is not a leave and preserves the live session;
  switching chat, New Task or another destination destroys it immediately, cancels owned
  runs even mid-generation, and revokes RAM-only query snapshots. `Keep as saved` is a
  single atomic promotion (messages + queued follow-ups + unsent draft, no resend) whose
  failure leaves the temporary session recoverable; late callbacks from a destroyed
  session cannot act on a replacement.

## 2. Subagents and shared Linux environment

- **Full parent authority + autonomous discovery.** A delegated child holds the parent's
  actual effective tool ceiling, not a reduced mode, and cannot delegate again. The child
  now starts from a small seed (tool discovery, skills, checklist and shell entry points)
  and loads working definitions through `tools.list` / `tools.search` and
  `skill.list` / `skill.search` / `skill.read` inside its own versioned discovery state;
  `skill.read` activates declared workflow dependencies in the child. A full catalog
  serialized hundreds of kilobytes and could not fit the bounded frozen-schema allowance
  (48 KiB); loaded definitions are admitted/dropped/evicted inside the real wire-byte
  budget, an oversized single definition is reported for that definition only, and
  sibling/parent discovery state is never mutated.
- **Shared environment, per-client results.** A parent run and its children can share one
  Linux environment through native processes and per-request PTY sessions — no
  VM-per-child and no OS multi-user model. Results, working directories, standard I/O,
  exit status and cancellation belong to the requesting session; cancelling one child's
  own token interrupts only its in-flight command, and stopping the environment is a
  separate lifecycle action. The guest channel keeps control frames (BEGIN/END/FAILED)
  under output pressure, console overflow fails closed with a recorded event instead of
  silently corrupting output, and `exec.shell`'s per-run `env` argument is now really
  applied to Linux guests. Native shell sessions are keyed per trusted client so identical
  provider call ids from the parent and two children cannot collide.

## 3. Crash repairs

- **Build 271 (notification SIGABRT).** The faulting app frame symbolicated to
  `BackgroundRunCoordinator.userNotificationCenter(_:didReceive:)` with the build-271
  dSYM; the crash reporter's crypto-looking labels fall outside the loaded image ranges.
  The `didReceive` completion-handler path was already fixed in the 272 line; this round
  moves the remaining `willPresent` delegate callback off the compiler-generated async
  bridge onto the completion-handler selector (same presentation answer, delivered
  synchronously exactly once).
- **Build 272 (composer layout SIGSEGV).** Symbolication showed the main thread exhausting
  its stack inside SwiftUI layout: `ComposerReturnField.measuredNaturalHeight` called
  `ensureLayout` on the live TextKit container from `sizeThatFits`, and the same
  ~29-frame layout/notification cycle repeated ~126 times (~3,675 frames). The fix makes
  measurement side-effect-free — detached TextKit under the existing content/width memo,
  no live-container mutation from measurement, and the scroll-state flag deferred and
  coalesced to the latest view — with behavior regressions for wrap/scroll.

## 4. Linux guest performance

The prior archive log contains `-Os` invocations, but its response files are no longer
available to reconstruct the final effective flag. A fixed,
same-guest benchmark (identical script hash, 3 raw runs per binary, guest-side timers,
1 vCPU / 512 MiB / 9p) compared like-for-like `-O2` and `-Os` builds of the identical
source set:

| Workload (guest seconds, median of 3) | `-O2` | `-Os` | Difference |
| --- | --- | --- | --- |
| sha256 over 128 MiB | 20.379 | 22.969 | `-O2` ≈11.3% faster |
| 32 MiB read + hash | 5.407 | 6.040 | `-O2` ≈10.5% faster |
| other workloads (memory touch, raw read/write, files, LCG) | — | — | within noise; no reproducible `-Os` win |

Consequently `Package.swift` now adds a **Release-only `-O2`** compiler flag for the
engine target (source unchanged; images, boot pair, kernels and licenses untouched).
This is a host/native-guest-engine measurement, not iPad performance. Profiling shows
~99.9% of emulator samples in the single-threaded interpreter dispatch loop, so no safe
source-level optimization was pursued.

## 5. Validation matrix (what actually ran)

| Area | What was executed | Result | Status |
| --- | --- | --- | --- |
| Temporary tool policy (module) | FloeTools policy suite + `--filter Temporary` + full FloeTools module | 12/12 + 25/25 passed; 100 tests / 13 suites passed | passed (module scope) |
| App files touched by temporary UI | `swiftc -parse` on every touched App/test file | parse OK each | parse only |
| Notification bridge | Production bridge executed on host (extracted module, strict Swift 6) | 7/7 passed (completion exactly once, main-actor routing, cold/repeat cases) | passed (host scope) |
| Shared-VM multi-client transport | Host multiplex harness: real runner + production channel | 8/8 scenarios passed (real overlap 0.54 s, distinct tokens/PIDs, env/cwd/streams separation, one-cancel isolation, console EOF) | passed (host scope) |
| FloeExecution module | Full module suite after the guest-channel changes | 302 tests / 42 suites passed (559 XCTest case passes) | passed (module scope) |
| Native shell session keys | Eight `LocalShellService` keys use the per-client token; four App regression cases | included in the focused App run below | passed (Simulator App scope) |
| Standalone host protocol | `host_protocol_check.sh` (repaired extraction) | 113 checks, 0 failures; router 18/0; lifecycle 5/0 | passed (host scope) |
| Guest benchmark | Fixed script, two binaries, 3 raw runs each + profile | medians in §4; profile captured | passed (host/native engine scope) |
| Runtime subagent work | Full runtime suite before the final discovery-receipt/lifecycle corrections | 506 tests / 44 suites passed in 36.934 s; the earlier hung run remains incomplete | historical module evidence; final corrections tested in App |
| App integration | Full arm64 Simulator App compilation; temporary policy/lifecycle, composer, notification, voice, shell isolation and subagent regressions | 167 tests / 18 suites passed in 10.003 s, including five final discovery/lifecycle regression cases | passed (Simulator App scope, before CAD changes) |
| Real Linux guest | Child Shell/Python, autonomous tool/Skill discovery to a guest artifact, parent/two-child concurrency and browser takeover guard | final combined run: 4 tests / 1 suite passed in 622.695 s; original fixture failure retained | actual guest in Simulator App; scripted model, not a real LLM |
| Shared-guest concurrency | Parent and two children genuinely overlapped; distinct sessions, cwd/env/output, shared-file writing, ownership denial, lifecycle busy and scoped cancellation | targeted corrected case passed; original failure retained | passed (actual guest, Simulator App) |
| Default-review document flow | One Human/ASK runtime through real PDF edit/export and media capabilities/read/propose/apply/readback/export, with custom service-owned store root; repository destination negative case | 2 App cases passed (0.340 s), no per-edit approval in the ordinary flow; repository output still waits | passed (Simulator App); scripted provider |
| CAD additions | Real Runtime/tool/host apply, Unicode names, 2D Worker edits, staged Canvas scope, continuous 3D loop, measurement, STEP/STL/GLB binary checks and reimport | 11 App XCTest cases passed (2.901 s); 10 concurrency cases passed (7.574 s) | passed (Simulator App); default-review policy additions pending |
| Final policy/tool integration | Actual runtime parent/child policy, all typed targets, Office tool/executor and real export host, media store/parity, remote automatic-route diagnostics | 113 Swift Testing cases / 13 suites passed (8.628 s), plus 15 XCTest cases (4.335 s), zero skipped | passed (Simulator App); earlier five assertion issues retained and fixture corrections recorded |
| Apple state | GET-only discover run 38677174783 (2026-10-15T03:37:26Z) | latest 1.7.31/272 `VALID`; no 273 upload existed then | pre-delivery candidate state |
| Apple state (delivered) | Independent GET-only `verify-testflight` run 38717806031 (2026-10-15T10:06:16Z) | build `f0b719ad-c418-4c50-bba0-48ab45aa4147` `VALID`, unexpired, one group `Floe QA` (internal), `IN_BETA_TESTING`, unexpected groups 0 | internal Floe QA availability confirmed |

## 6. Delivery gates (implementation qualification complete; internal delivery completed)

1. **Source freeze and reconciliation** — completed: the round's 94 owned files were staged
   explicitly from the primary's source whitelist, every hash re-verified, committed as
   `29937dc025267bacd89434cc092b3906c99b93ee` and pushed with the annotated tag `v1.7.32`;
   protected untracked files were left untouched. The final local qualification records the five
   earlier fixture assertion issues and their corrections; no business guard was weakened to
   obtain a pass.
2. **Local device artifact** — completed: Xcode 27.0 (27A266a) Release iphoneos arm64 archive
   with `CODE_SIGNING_ALLOWED=NO` from the frozen tag; app + extension `1.7.32 (273)`; the new
   FloeTinyEMU Release response file ends `-fno-modules -O2` (last optimization flag); the
   archive, raw app, all ten dSYMs and hashes were retained before signing
   (`Local/Artifacts/build273/`, transport sha256 `0fc1e741…`).
3. **Internal distribution** — completed: the existing artifact was signed/uploaded by
   `release-unsigned-ipa.yml` local-artifact route (run 38715266826, `app_rebuilt=false`), and
   independent GET verification confirmed Apple `VALID`, unexpired and available to existing
   Floe QA. Device archive, upload and internal availability remained separate gates.

Known open gate (not a delivery blocker, owner decision): `scripts/license_inventory.sh --check`
fails on this frozen source because the new test-only `ZIPFoundation` Xcode package is declared
with `exactVersion` while the checker requires an immutable `revision:`. The App does not link
that package; the fix belongs in the next round's `project.yml` (the frozen tag is not edited).

Real provider/model and physical-device testing remain **not performed in this
round**. Scripted-provider tests do not establish real-LLM decisions or device
responsiveness. Internal Floe QA delivery is the authorized scope; these recorded
limits are not a claim of physical-device acceptance.

## 7. Evidence corrections and limits

- Original failures are retained, not rewritten: the hung runtime suite, the earlier
  parse/test-target failures and the interrupted helper are recorded as they happened.
- Lane C's private source-ready record carried a freeze time later than the primary's
  review snapshot; the round treats the actual file modification time and the primary's
  hash snapshot as authoritative and leaves the original record unchanged.
- Lane C's self-reported cleanup (~8.6 GB, rounded) is not an independently re-measured
  free-space gain and is not quoted as exact.
- The earlier archived build's compiler invocation is not reconstructible from retained
  logs (response files were removed), so the `-Os` comparison rests on the fixed benchmark
  above; the older `-Os` log is historical context only. The 273 App archive satisfied the
  follow-up: its retained FloeTinyEMU Release response file ends `-DXcode -fno-modules -O2`,
  so the engine shipped with the new Release flag (last optimization flag wins).
- After all module builds finished, the repository lock was restored byte-for-byte to
  the baseline schema-1, 32-pin file; the App workspace lock remains unchanged.
- Standalone host tests do not prove App/UI behavior. Actual App/UI tests are listed
  separately above; none of these establishes device performance, real model inference
  or Apple distribution state.
- The real-guest and initial UI suites were retained from their affected-component
  binaries. Final policy/CAD/tool changes received a full local App object build and
  the relevant App-hosted tests; unchanged broad suites were not mechanically rerun.

## 8. References

- User guides: [English](../../USER_GUIDE.md) · [中文](../../USER_GUIDE.zh-CN.md)
- Local build/release path: [Local build and TestFlight delivery](../testflight/LOCAL_BUILD_RELEASE.md)
- Build and acceptance: [Floe 1.7 build and acceptance](../../FLOE_1_7_BUILD_AND_ACCEPTANCE.md)
