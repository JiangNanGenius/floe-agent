# TinyEMU Runtime v2

Runtime v2 separates durable Linux environments from temporary emulator
instances. A Conversation references an Environment and a Workspace. The
Environment owns persistent Linux changes; a TinyEMU VM is only a leased
execution resource.

## Durable layout

```text
Application Support/Floe/Runtime/v2/
├── layout.json
├── registry/
│   ├── runtime.sqlite
│   └── migrations/
├── images/
│   ├── manifests/
│   ├── blobs/sha512/
│   └── expanded/
├── environments/<environmentID>/
│   ├── metadata.json
│   ├── system/{delta.header,delta.bitmap,delta.data}
│   ├── data/
│   ├── services.json
│   ├── ports.json
│   └── state/last-shutdown.json
├── workspaces/
│   ├── owned/<workspaceID>/
│   ├── refs/<workspaceID>.json
│   └── scratch/<scratchID>/
├── cache/{apt,pip,npm,cargo,staging}/
├── runtime/{vm,queues,downloads,scratch,tmp}/
├── recovery/{migrations,quarantine,trash}/
└── logs/
```

`runtime.sqlite` records relations between conversations, environments,
workspaces, images, blobs, services, ports, queues and leases. Environment
sidecars are recovery inputs. `runtime/vm`, downloads, logs and caches are
rebuildable and are never the source of user state. External workspaces keep a
security-scoped reference; Floe does not copy the user's project. Credentials
are referenced by approved credential identifiers and never enter this tree.

## Image and system state

- BIOS, kernel, initrd and RootFS artifacts are SHA-512 content-addressed.
- The verified RootFS base is read-only and stored once.
- Every environment owns a 64 KiB block CoW delta. The delta is the only
  authoritative source of guest system changes such as APT packages, `/etc`,
  `/usr/local` and guest language environments.
- The logical system disk starts at 16 GiB and may grow to 32 GiB. Physical
  storage reflects written delta blocks rather than a full disk per environment.
- The host's Runtime v2 `cache/` tree is rebuildable; of its kinds only blob
  `staging` is populated today. Guest package caches and build temporaries
  (pip/XDG/npm caches under `/floe/env/cache`, `TMPDIR=/floe/env/tmp`) live
  inside each environment's persistent layer, so they survive restarts but are
  not deduplicated across environments. Downloads may be cached; **installed
  state is never shared** between environments.

## Software templates and pinned environments

A software template is an immutable, content-addressed record of a complete
verified disk plus its real package listing and qualification provenance — not
a mutable "golden VM" and not a cache. Registering identical content is
idempotent; different content under the same name is a new version, and an
existing version is never overwritten. Garbage collection runs only on verified
versions with zero references (environment, catalog, build, recovery or
quarantine) past the grace window, and quarantines rather than deletes; a
direct environment pin protects its version.

An environment that carries a pin boots exactly that `template_id`, version and
digest or fails closed (`templatePinUnavailable`, `templateBaseImageMismatch`);
pin changes are refused while a lease is held, and unpinned environments keep
base-image behavior. Only private changes are captured per environment: a
pinned environment's delta is bound to the template version's immutable disk,
so an environment never absorbs another version's or another environment's
state.

Delivery state: no App flow currently creates a pinned environment — current
environments boot the verified base image, and the pinning/provenance
machinery is exercised by module tests. The official `basic` and `dev-document`
templates report `dependency-missing` because their complete installed-disk and
recipe artifacts are still pending, so no preinstalled-package template is
selectable yet.

## Migration and recovery

Legacy discovery covers old images, per-environment disks and private task
layers. Migration copies into staging, verifies digests and delta
materialization, writes the new registry rows in a transaction, then atomically
switches references. Old data remains as `cleanupPending` recovery material
until the new layout has opened successfully. The same image ID with a different
digest is quarantined and never overwritten. Startup creates every configured
9P host directory before TinyEMU validates its shares.

The registry may point only to verified files. A failed clean stop keeps the
environment and its disk in `QUARANTINED`; another VM cannot open that delta
until the previous process, emulator thread and disk handle are proven closed.

## Lease, pool and lifecycle

```text
STOPPED -> STARTING -> RUNNING -> IDLE -> STOPPING -> STOPPED
                                      \-> QUARANTINED
```

An environment has at most one writable `ExecutionLease`. Commands, terminals
and background services for that environment stay on the same VM so they share
the guest process space, filesystem, network and localhost. Concurrent guests
are bounded by the device quota (four VMs on supported iPads, fewer on smaller
devices); an environment over the quota waits in a cancellable queue. Inside
one guest the command channel admits up to eight concurrent ordinary commands,
and interactive terminal sessions are tracked per environment on the same VM.
This is guest process concurrency, not TinyEMU SMP.

When no command, terminal or registered background service remains, the
environment enters `IDLE`. After the idle budget, Floe requests guest shutdown,
flushes the filesystem, captures the delta, closes the disk and releases the
lease. VM RAM and CPU state are not snapshotted. Restartable services use the
service registry and are launched again after the environment boots.

## Memory and local-model arbitration

The device pool quota is a fixed per-hardware table (iPad 8 GiB: 4 vCPU /
2048 MiB / 4 VMs; 12 GiB: 4 / 3072 MiB / 4; 16 GiB and above: 4 / 4096 MiB / 4;
smaller devices and iPhone sizes get smaller quota sets), clamped to the
process's usable core count. A new environment requests one vCPU and a 256 MiB
RAM tier; the pool admits only combinations inside the current pressure and
headroom budget and returns the granted shape, and temporary shortages queue
cancellably. Guest RAM is fixed when the machine is created; until safe balloon
support exists, a tier change uses stop, flush and restart. SMP-capable boot
comes only from a verified image manifest: the current pinned image declares no
SMP capability, so a dual-hart request fails closed with an actionable reason
rather than booting one hart silently, and the performance tier that would
widen the quota is not enabled.

MLX local inference and TinyEMU share a process-wide heavy-runtime arbiter.
Linux admission waits for local inference to be idle and verifies the release:
an engine that is logically retained by a durable task but physically idle is
unmapped for the Linux start and reloads its pinned snapshot on the next model
turn, while genuinely active inference is never cancelled — the guest stays
queued, and if the model is still active after the bounded wait the start fails
with a truthful "model is still in use" error instead of deadlocking. In the other direction, starting a local model while Linux environments are
running asks for confirmation (listing the affected commands, terminals and
services) before stopping them; when every active guest belongs to the
requesting task's own disposable tool guest and no service exists, that guest
is released automatically and the continuation proceeds, while a foreign,
user-started, quarantined or racing guest still takes the explicit
confirmation. An idle local model unloads after two minutes; memory pressure may
release idle resources but does not terminate an active command.

## Background services and ports

Each environment exposes one “allow background running” preference. While an
active VM is backgrounded, PiP reports the environment, runtime ID, measured
CPU and memory, command/service counts and forwarded ports. Closing PiP ends
that background keep-alive and starts safe VM shutdown without changing the
saved preference.

TCP forwards support fixed ports and dynamic allocation from 49152–65535, at
most 16 rules per VM. Rules persist with the environment and are restored after
boot; conflicts are reported or dynamically reassigned. Floe does not configure
UPnP, router state or a public Internet endpoint.

## Verification boundary

Module compilation, migration fixtures and policy tests establish code and
storage contracts. They do not prove real-iPad background survival, PiP
presentation, LAN reachability, VM pressure behavior or guest filesystem
durability. Those remain device acceptance items for the matching immutable
TestFlight build.

The next integration is not covered by the delivered build's evidence either.
The native IDE editor and the compressed-archive engine have module tests plus a
cloud simulator UI run (iPad: native save/cold-reopen, Web fallback, DXF and DWG
all passed); the compact-width re-run, real-device keyboard/IME behavior and any
device archive work remain open. Templates, pinning and the pool are
module-tested, but no App flow creates a pinned environment yet, dual-hart boot
fails closed pending a real SMP guest image, the six-vCPU tier is disabled, and
the PiP identity/service repairs still owe dropped-stream and pending
start/stop fixes. None of this is device acceptance.
