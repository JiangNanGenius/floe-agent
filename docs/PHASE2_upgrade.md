# Phase 2 — existing persistent-disk runner upgrade (component consumer)

Date: 2026-09-21. Owner: upgrade worker (`codex/tinyemu-phase2-upgrade`).
Scope: `LinuxGuestRegistry.swift`, `LinuxGuestRuntimeImage.swift`,
`LinuxGuestImageStore.swift` (unchanged: the verifier iterates
`declaredArtifacts`, which now includes the runner), `LinuxGuestService.swift`
manifest schema (commit `5409e009`, frozen), the standalone focused check in
`FloeAgent/LinuxGuest/tests/RunnerUpgradeCheck.swift` +
`runner_upgrade_check.sh`, and this document.

The channel (`LinuxGuestCommandChannel.swift`) and the VM runtime
(`TinyEMUGuestRuntime.swift`) are dependency snapshots owned by the engine
worker (`../tinyemu-phase2-engine`); they are compiled by the check but never
committed here.

## Problem

One guest image is a verified catalog artifact (`<root>/<imageID>`), and each
environment boots its **own mutable clone** of the base disk
(`<writable>/LinuxGuest/disks/<environmentID>/disk.img`). A runner-only
component release replaces `/usr/local/bin/floe-exec` inside the image; the
clone an environment already owns does not change, so its runner stays at the
old protocol. Resetting the clone would destroy the user's packages and files,
and a disk prepared from a different base image used to be a hard
`diskOriginConflict`.

## Manifest contract (shared with the component pipeline)

`LinuxGuestService.swift` (commit `5409e0096bcd352ea515508005355c4c24b4ac52`,
schema must not move while the pipeline builds):

- `runnerArtifact`: `LinuxGuestImageArtifact` with `role: "runner"` (a distinct
  role; `disk` is rejected), `path` relative to the image directory
  (`floe-exec-riscv64`), `sha512`, `bytes`. It is a declared artifact, so the
  verifier hashes it with the same path/containment/symlink/size/digest checks
  as bios/kernel/initrd/disk, and the verifier cache fingerprint covers it.
  `artifactDigest(role: .runner)` falls back to `runnerArtifact`, so the
  pipeline does not need a duplicate `artifacts` entry (an explicit entry is
  accepted only if all three fields agree).
- `runnerCapabilities`: the verbatim CAPS payload, e.g.
  `runner=2.0.0 protocol=3 maxCommands=8 maxSessions=4`; it must declare
  `protocol >= 3` or the manifest fails qualification.
- `compatibleOrigins`: array of exactly `imageID` + `artifactSHA512` +
  `artifactBytes`. The pipeline writes the pinned predecessor
  (`floe-debian13-riscv64-202609202607`, disk SHA-512
  `31553063cacc88ae9a963456ff1f46ab5455ba28844a31dbd03b22f0fb18daa59c3e0fa98a975e7b95e9a67accdc9bf671e6de1b9a3e4e12a7291d3edaa519e7`,
  3085959168 bytes). Older manifests without these keys keep decoding.
- Artifact paths containing `..` or resolving outside the image directory are
  rejected as escapes (not merely "missing").

## Upgrade path (registry)

`TinyEMULinuxGuestRegistry.start` → `ensureGuestRunnerCurrent`:

1. **Live probe, every start.** The booted runner is probed with FLOE-HELLO on
   the production channel, bounded by `LinuxGuestLimits.runnerProbeTimeout`
   (default 60 s boot/negotiation budget: `handle.start()` only launches the
   VM thread, so a fresh interpreter boot can take tens of seconds before the
   runner reads the console; shorter values are test overrides, never
   production). The runner-upgrade ledger
   (`runner.json` next to the disk) is *recorded* after a successful live
   answer/upgrade and **never** used to skip the probe: a stale ledger with a
   silent runner still upgrades.
2. **Protocol 3 answer** → `acceptExternalNegotiation`, the session keeps the
   channel. No reboot, no disk write.
3. **Legacy runner** → require the verified `runnerArtifact` +
   `runnerCapabilities`, load the bytes through
   `LinuxGuestRuntimeImagePreparer.loadVerifiedArtifact` (containment, symlink,
   regular-file, size and SHA-512 checks before anything is read), then switch
   the **one** channel into legacy serial mode
   (`enterLegacySerialMode()`), where HELLO is skipped and one exchange runs at
   a time.
4. **In-guest install** (bounded by one 300 s upgrade deadline, 8 MiB artifact
   cap, per-step timeouts):
   - staging: the environment's writable layer is the guest's `floe-env` 9p
     share (`/floe/env`); the host writes the verified runner there and the
     guest copies it with `cp` (the share path is derived from
     `LinuxGuestPathMap`, never a hard-coded `/floe`). If the share is absent
     or the copy fails, the fallback uploads base64 chunks through the console
     into the guest's `/tmp` tmpfs and decodes there.
   - `sha512sum` **inside the guest** must match the manifest digest, so a
     truncated or corrupted upload never replaces the live runner.
   - the old runner is kept as `/usr/local/bin/floe-exec.prev`; the new binary
     is copied to `.new` and promoted with a same-directory `mv` (atomic), with
     `sync` before the rename. Cleanup removes the staging directory; the host
     staging file is always removed, on success and failure.
5. **Reboot**: host-side `handle.stop()` + `handle.start()`. `stop()` does not
   finish the console stream and the reader is never cancelled — cancelling a
   for-await reader finishes `AsyncStream` permanently (verified with a real
   probe: after cancelling, `yield` returns `.terminated` and a replacement
   iterator gets `nil`). Instead the **single router** keeps reading, and
   `resetRouterState()` drops the old boot's buffered frames, section owner and
   token streams at the boundary; `leaveLegacySerialMode()` restores
   protocol-3 negotiation.
6. **Verify** the rebooted runner's CAPS equals the manifest's
   `runnerCapabilities` before the session exists; only then is the channel
   handed to the session and the ledger written. Any failure leaves the
   persistent disk untouched with an honest error and closes the VM.

## Disk adoption without data loss

`LinuxGuestRuntimeImagePreparer.reuseExistingDisk` accepts an existing disk
only when `origin.json` matches the current image (image id + disk SHA-512) or
one `compatibleOrigins` entry on **all three** fields. The mutable disk and the
original `origin.json` are preserved byte-for-byte (the origin is the honest
record of the bytes the clone came from); an unrelated origin is still a
`diskOriginConflict` and nothing is overwritten.

## Truthful stop and quarantine

`stopGuest`/`resetGuest` do not report a stop the engine did not perform. The
registry marks the environment's teardown in flight before its close awaits
(so a concurrent `startGuest` cannot slip past the removed session and boot a
second VM on the same disk), then after closing both the channel and the
handle it asks `handle.isRunning()`. `TinyEMUGuestMachine.stop()` may time out
and deliberately keep a VM whose run loop did not leave its last slice; in
that case the session and its admission reservation are retained, the
environment is quarantined, `guestStatus.running` stays true and
`lastError`/`lastResetSharedImpact` say the VM is still running and that no new
guest will start on that disk. A later `stopGuest` retries and, once the VM
really stops, releases the slot and records the truthful "stopped and
destroyed" impact. `startGuest` on a quarantined environment throws
`LinuxGuestError.stopFailed` instead of booting on the live disk.

## Bounded admission

Per-command/session caps do not bound process memory when every environment
owns a VM, so `LinuxGuestLimits` adds `maxActiveGuests` (default 4) and
`maxGuestRAMMB` (default 1536; two 512 MB guests still fit) and the registry
reserves both **before** any disk copy or VM creation, covering starts in
flight. A refusal (`LinuxGuestError.capacityReached`) never stops another
guest and never waits; `LinuxGuestStatus.activeGuestCount` /
`reservedGuestRAMMB` report the current usage. A duplicate concurrent start of
the same environment is refused (`guestBusy`) instead of creating a second VM,
a stop requested during a start tears the start's own handle down, and every
failure path releases its reservation.

## Verification (actual, 2026-09-21)

`bash FloeAgent/LinuxGuest/tests/runner_upgrade_check.sh` (extracts the
production declarations verbatim, `swiftc -swift-version 6` strict object
compile of the module, then builds and runs the check):

```
==> strict typecheck (swift-version 6, object emit) of the extracted module
==> compiling upgrade check (swift-version 6, object emit) and linking
==> running existing-disk upgrade checks

checks passed: 16, failures: 0
==> all runner upgrade checks passed
```

Covered (all against the extracted production code and a scripted guest
console that models one immutable console stream per VM):

| Check | Assertion |
| --- | --- |
| compatible predecessor origin | disk bytes, inode and `origin.json` unchanged; boot paths resolve |
| unrelated origin | `diskOriginConflict`, disk bytes unchanged |
| runner artifact contract | `runner` role required (`disk` rejected), capabilities must declare protocol ≥ 3 |
| verifier | missing / wrong-size / wrong-digest / symlinked / escaping runner rejected; fingerprint follows the runner bytes |
| old manifests | decode without the new keys |
| share staging | one console reader, share copy used, in-guest digest verified, `.prev` kept, promotion atomic, host staging removed, disk + origin preserved, ledger written, post-reboot command succeeds |
| console fallback | share copy failure and no-share descriptors upload chunks and reconstruct the verified bytes |
| live probe | current runner: no install, no reboot, one reader, ledger kept truthful |
| ledger trust | stale ledger cannot skip the probe; upgrade still runs and the disk is preserved |
| missing artifact | `runnerUpgradeRequired`, disk preserved, VM closed, slot released |
| unverified bytes | wrong digest / symlink never reach the guest; install failure stops with the disk preserved |
| admission | duplicate concurrent start refused; count and RAM budget refuse without stopping running guests; slots release on stop |
| refused stop | a VM that refuses to stop keeps `running` true, retains the session and its admission slot, reports the quarantine in status, refuses a new start on the same disk, and a retried stop recovers |

Limits: the check is a host-side scripted-console integration check, not
guest-image qualification and not riscv64 execution; the real runner/component
boot evidence comes from the component pipeline's guest protocol check and the
cloud App build.

## Follow-ups

- App catalog: the primary updates the default image id/archive digest to the
  new component release after the cloud build.
- The upgrade runs in-guest `sha512sum`, `cp`, `mv`, `base64`, `printf` and
  `sync` from the Debian userland; a guest missing them fails the upgrade
  closed and leaves the old runner in place (`.prev` and the live binary are
  untouched until the final rename).
