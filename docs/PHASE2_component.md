# TinyEMU phase 2 — Linux guest runner component update pipeline

Status: **implemented, not dispatched**. No workflow run, no release, no cloud
artifact exists for this pipeline yet; the section "Verified locally" lists
exactly what was executed and what was only inspected. The primary agent owns
the dispatch decision and publication.

Scope of this document: the runner-only Linux guest component update
(`.github/workflows/linux-guest-runner-update.yml` and
`FloeAgent/scripts/linux-guest-runner-update/`). The guest engine, adapter and
app wiring live in their own work streams
(`codex/tinyemu-phase2-engine`, `codex/tinyemu-phase2-adapter`).

## Goal

Ship a new Floe Linux guest component that replaces only the guest runner
(`/usr/local/bin/floe-exec`) with the protocol-3, concurrency-capable runner,
reusing the already published whole-disk image instead of rebuilding Debian:
kernel, bbl, userland packages, and the cross toolchain stay byte-identical to
the base component.

Base component (published prerelease, verified against the GitHub API on
2026-09-21 — all 13 assets, sizes and SHA-256 digests matched):

| Pin | Value |
| --- | --- |
| tag | `floe-linux-guest-20260920.1` |
| target commit | `b9cffd427a6ba32f9bc9fd6a5197e6f33ef00707` |
| image archive | `floe-linux-guest-floe-debian13-riscv64-202609202607.zip` |
| archive sha512 / bytes | `ad691732…34a` / `572643214` |
| manifest sha512 | `8e111276…cdc` |
| bbl / kernel / disk sha512 | `f467da0f…cc`, `4e969132…f8`, `31553063…e7` |

## Pipeline

| File | Responsibility |
| --- | --- |
| `.github/workflows/linux-guest-runner-update.yml` | preflight (read-only, also the registration-push path) + draft-only update job |
| `verify_base_release.py` | workflow/tag policy, base release pins, target-commit pipeline + runner + engine contract |
| `pipeline_contract.py` | shared parsers: runner constants/CAPS, `Role` enum, toolchain records |
| `build_runner.sh` | cross-build static riscv64 runner + relink object + constants + toolchain records |
| `prepare_image.sh` | fetch/verify base archive, verify member set, replace only `floe-exec` via `install-into-image.sh` |
| `guest_protocol_check.py` | generate the timed guest script; assert the boot transcript + 9p share |
| `package_component.py` | manifest with runner upgrade fields, catalog ZIP, relink + reused-source archives, sums |
| `selfcheck.py` | offline synthetic checks of all of the above (runs as a workflow step before any download) |

Workflow order: preflight → self-check → cross toolchain pinned to the base
component → runner build → cross-toolchain correspondence gate (before the
572 MB download) → base image fetch + single-binary injection → TinyEMU host
build → one real guest boot + focused protocol check → package → **draft**,
prerelease release (never `latest`, never `--clobber`, unique tag).

Cross-toolchain correspondence: the job downloads the digest-pinned base
`runner-relink` (225 KB) and `toolchain-source` (47 MB) assets, installs the
exact package versions the base records name, and compares this run's resolved
owning packages (compiler, `libc.a`, `libgcc.a`, cross libc) against the base
`toolchain-versions.txt`. A mismatch fails the job, so the base
toolchain-source asset is never claimed as corresponding source without
evidence. `package_component.py` repeats the comparison as a second gate.

## Artifact and protocol contract

Image archive members (deterministic order, CRC-verified on read-back):
`manifest.json`, `bbl64.bin`, `kernel-riscv64.bin`, `disk.img`, and the new
standalone `floe-exec-riscv64`.

The manifest carries the engine upgrade contract in addition to the normal
artifact digests:

```json
"runnerArtifact": {
  "role": "runner",
  "path": "floe-exec-riscv64",
  "sha512": "<128 hex of the exact bytes in the archive>",
  "bytes": 123456
},
"runnerCapabilities": "runner=2.0.0 protocol=3 maxCommands=8 maxSessions=4",
"compatibleOrigins": [
  {"imageID": "floe-debian13-riscv64-202609202607",
   "sha512": "31553063…e7", "bytes": 3085959168}
]
```

* `runnerCapabilities` is the **verbatim** CAPS payload the guest answered
  during this run, and the packager refuses to write it unless it equals the
  CAPS string implied by the runner source constants of the same commit.
* `runnerArtifact.role` must stay inside the engine's
  `LinuxGuestImageArtifact.Role` enum or the manifest would not decode. The
  engine owns a **distinct `runner` case** (the upgrade manifest/lifecycle
  work); the pipeline writes exactly that role and fails closed when the case
  is missing, so the runner artifact can never collide with the `disk`
  artifact or its verifier. `RUNNER_ARTIFACT_ROLE` stays as an explicit,
  validated override.
* The compatible-origin field is read from the target commit's
  `LinuxGuestService.swift` / `LinuxGuestRuntimeImage.swift`: the package
  prefers `compatibleOrigins` and the other documented names, and otherwise
  accepts **any** array-of-struct property on `LinuxGuestImage` whose element
  has stored properties for the image id, the SHA-512 and the byte size (the
  engine's own key spelling is used verbatim, e.g. `imageID` +
  `artifactSHA512` + `artifactBytes`). It declares the **pinned base image**
  as the verified runner-only predecessor; its values come from the pinned base
  manifest bytes (`manifest-base.json`, whose own SHA-512 is verified), never
  from notes. A runner-only update changes the disk digest, so without this
  record an existing environment disk would be rejected instead of upgraded.
  The packager fails closed when no recognizable origin array exists or when
  the values do not match the pins.
* `LinuxGuestRegistry.ensureGuestRunnerCurrent` consumes `runnerArtifact` +
  `runnerCapabilities` to replace the runner inside an existing environment
  disk and reboot, instead of wiping the disk. The preflight fails closed if
  the target commit's engine lacks the fields or the registry consumer.
* App side: `LinuxComponentUpdatePolicy.updateNeededReason`
  (`FloeAgent/FloeApp/Execution/LinuxComponentUpdatePolicy.swift`) parses the
  installed image manifest, reads `protocol=` from `runnerCapabilities` and
  reports an update whenever it is missing or below protocol 3 — the exact
  field this pipeline writes, so an old disk is flagged for in-guest upgrade
  instead of being silently reused.
* Every manifest digest (bbl, kernel, disk, runner) is verified against the
  actual bytes while packaging, and the archive is re-read and re-hashed before
  the package is saved.

Protocol check (one boot, ~2 minutes, focused on the runner contract — not the
package/SMP/UI matrix): framed `FLOE-HELLO` → `FLOE-CAPS` answer and END;
4-way concurrent EXEC behind a real 9p-file barrier — the success marker is
printed only after all four start-files were re-checked, and the bounded wait
expiring prints `FLOE_CC<n>_NO_OVERLAP` plus exit 7, so a serialized runner
fails the check twice; targeted `FLOE-SIGNAL … TERM` → exit 143; legacy raw
`0x03` interrupt-all → exit 130 twice with immediate channel recovery; two
concurrent chunked-`OPEN` PTY sessions with per-token `FLOE-IN` routing;
chunked `SPAWN` background service with `FLOE-PID` and ≥2 ticks in the 9p log;
honest `END 3` for unknown `ALIVE`/`KILL` pids. Kernel panic, `FLOE-FAILED`,
protocol-2 "guest is busy", table overflow, a barrier timeout and a wrong
cancel exit code are forbidden markers. The host's `--until` marker is the
runner's terminal `FLOE-END p3done 0` frame (written by
`guest_protocol_check.py generate --terminal-out`), not the guest's last
printf: `floe_vm_host` stops on the first marker substring in the console
stream, so waiting for `FLOE_P3_DONE` could end the boot before the final END
frame is transcribed, while the assert still requires both. `qualified: true`
in the manifest is written only from this real boot verdict (`failures == 0`);
a dry run cannot produce it.

## Licenses and corresponding source

* Runner source (MPL-2.0) travels in the relink archive with the relocatable
  object, exact link command, constants and `RELINK.md` (LGPL-2.1 §6).
* Kernel/bbl/Debian userland are unchanged bytes in the reused disk, so their
  corresponding-source assets are referenced from the published base release
  with digests re-fetched at package time (`REUSED-SOURCES.json`, plus the
  toolchain comparison). No zero-gap claim is made beyond those verified
  digests.
* The new release never overwrites the base tag or its assets; the base release
  keeps serving every unchanged source bundle.

## Ready execution inputs

1. `target_commit`: full 40-hex SHA of the integrated commit containing this
   pipeline, the protocol-3 runner, and the engine `runnerArtifact` /
   `runnerCapabilities` contract (preflight verifies all of it).
2. `component_tag`: new unique `floe-linux-guest-…` tag, no leading `v`, never
   `latest`, not `floe-linux-guest-20260920.1`.
3. `image_id`: new unique id embedded in the manifest and archive name, e.g.
   `floe-debian13-riscv64-<date><rev>`; must differ from
   `floe-debian13-riscv64-202609202607`.
4. Dispatch `linux-guest-runner-update` from the source branch with those
   inputs. The job creates a **draft prerelease**; publishing, catalog pinning
   and TestFlight/App work remain with the primary agent.

## Verified locally (2026-09-21)

* `selfcheck.py` — PASSED: contract parsers, timed-script shape against the
  real `floe_vm_host` limits, synthetic protocol-3 pass plus protocol-2 /
  missing-marker / barrier-timeout fail-closed, and a full
  `package_component.py` round trip on tiny fixtures including the fail-closed
  cases (CAPS/source mismatch, toolchain drift, engine without the artifact
  contract, without a distinct runner role, without a compatible-origin array,
  plus two origin-schema variants and an unusual field name).
* `verify_base_release.py` registration-push mode — 0 failures against the
  live API (13/13 base assets, tag/release free, workflow contract).
* `verify_base_release.py` dispatch mode:
  * against the old base commit — fails closed with the expected findings
    (pipeline files, protocol-3 runner, engine contract);
  * against the current engine work tree — fails closed with exactly the two
    pending engine dependencies (no distinct `runner` role, no recognizable
    compatible-origin array);
  * against the same tree with those two schema pieces added — 0 failures,
    recording `role=runner` and `compatibleOrigins` over
    `LinuxGuestImageCompatibleOrigin` (imageID/sha512/bytes).
* `prepare_image.sh` — base ZIP verification, member-set gate, and the
  member-tamper fail-closed path exercised with a synthetic archive (the
  injection step itself refuses to run outside Linux CI).
* `actionlint`, YAML parse, `py_compile`, `bash -n` — clean.

## Open items

* Cloud dispatch has not run; the real guest boot, toolchain pin availability
  and release upload are unverified until the coordinator dispatches.
* The upgrade manifest/lifecycle schema is owned by helper job
  `job-f036006c7339406c` in `../tinyemu-phase2-upgrade` (the main engine work
  tree keeps Registry/RuntimeImage/Service/ImageStore frozen). The pipeline
  derives the final schema from the integrated sources and currently fails the
  preflight closed until the distinct `runner` role and the compatible-origin
  array land; a CLI steer with the exact expectations was sent to that job.
* The adapter's TinyEMU host must build from the target commit
  (`FloeAgent/Qualification/TinyEMULinux/floe_vm_host.c`); the preflight checks
  the file and the workflow builds it before the boot.
