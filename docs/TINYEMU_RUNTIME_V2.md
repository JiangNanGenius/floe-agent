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
- APT, pip, npm and Cargo downloads may use shared caches; installed state is
  never shared between environments.
- Build temporaries and package caches use the environment data layer or shared
  cache, avoiding the small guest root and `/tmp` limits seen in Build 221.

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
the guest process space, filesystem, network and localhost. Up to four VMs run
at once; a fifth environment waits in a cancellable queue. One environment may
run up to eight ordinary commands and four interactive terminals inside its
single guest. This is guest process concurrency, not TinyEMU SMP.

When no command, terminal or registered background service remains, the
environment enters `IDLE`. After the idle budget, Floe requests guest shutdown,
flushes the filesystem, captures the delta, closes the disk and releases the
lease. VM RAM and CPU state are not snapshotted. Restartable services use the
service registry and are launched again after the environment boots.

## Memory and local-model arbitration

Devices with at least 12 GiB of physical memory receive a 2 GiB VM pool;
others receive 1.5 GiB. VM requests use 256, 512, 768 or 1024 MiB tiers, and
the resource manager admits only combinations within the current pressure
budget. TinyEMU guest RAM is fixed when the machine is created. Until safe
balloon support exists, a tier change uses stop, flush and restart.

MLX local inference and TinyEMU share a process-wide heavy-runtime arbiter.
Linux waits for an active local inference/tool continuation to finish before
admission. Starting a local model reports affected Linux commands, terminals
and services before a user-authorized stop. An idle local model unloads after
two minutes; memory pressure may release idle resources but does not terminate
an active command.

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
