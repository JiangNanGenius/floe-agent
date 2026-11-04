// floe_project_supervisor.h — Floe resident-ARM64 guest project/task supervisor contract.
//
// One physical guest Machine hosts N isolated projects. A trusted in-guest
// supervisor (started by init) owns project lifecycle, per-project rootfs
// overlays, cgroup2 trees and per-project runner processes. Every project
// gets one UNMODIFIED protocol-3 floe-exec channel on its own virtio console;
// the supervisor owns a separate control console speaking the versioned
// project-control frames defined here.
//
// Design authority (settled user direction + coordinator guidance, 2026-11-05;
// ownership model corrected against kernel source 2026-11-05, this closure):
//   * Keep the ordinary exec.shell/jobs/PTY frames untouched: one existing
//     floe-exec channel per project instead of mutable global active-project
//     state on a single console.
//   * Rootfs/mount setup is owned by the trusted supervisor; task processes
//     run with the proven namespace/cgroup limits of the 2026-11-04 isolation
//     POC (read-only common lower, per-project ext4 overlay, cpu/memory/pids
//     cgroup ceilings, cgroup.kill cancellation that reaps double-fork/setsid
//     descendants).
//   * Explicit validated projectID/taskID/generation on every control frame;
//     a missing or foreign ID fails closed (END 125/126). There is no default
//     project and no implicit routing.
//   * New projects join after boot without rebooting active peers: PROJOPEN
//     mounts the overlay and spawns the project's runner at runtime.
//   * This is dependency/data/lifecycle isolation, NOT a native-code security
//     sandbox. Network stays the existing guest NAT; there is deliberately no
//     new network policy fence.
//
// Ownership and capability model (CORRECTED 2026-11-05 compile closure)
// ---------------------------------------------------------------------
// The source-only draft of 2026-11-05 idmapped the overlay rootfs and the
// cgroup2 bind with mount_setattr(MOUNT_ATTR_IDMAP). That design was checked
// against the kernel source and is NOT kernel-supported on the target:
//
//   * fs/overlayfs/super.c sets FS_USERNS_MOUNT only; FS_ALLOW_IDMAP appears
//     only on master AFTER v6.18 (checked v6.12..v6.18 tags). Any released
//     kernel, including Debian trixie ARM64 6.12, rejects
//     mount_setattr(MOUNT_ATTR_IDMAP) on an overlay mount with EINVAL.
//   * kernel/cgroup/cgroup.c marks cgroupfs FS_USERNS_MOUNT only, never
//     FS_ALLOW_IDMAP: a cgroup2 bind mount cannot be idmapped on any kernel.
//
// Requiring an idmap the kernel refuses, and calling the resulting fail-
// closed END 126 a working feature, is exactly what must not happen. The
// smallest working design — explicitly authorized because this is NOT a
// hostile-native-code sandbox — is therefore:
//
//   * NO user namespaces, NO idmapped mounts, NO capset/setns dance at all.
//     The Machine keeps its single initial user namespace; project tasks run
//     as the guest's own root (uid 0). apt/dpkg work natively against the
//     Debian tree, exactly as they do in the classic single-console runner.
//   * Per-project separation comes from:
//       - a private ext4 overlay rootfs (immutable base lower + per-project
//         upper/work on the ext4 state root): installed packages and files of
//         project A are physically absent from project B's view;
//       - a private cgroup subtree /sys/fs/cgroup/floe/<id>/tasks with
//         pids.max FLOE_PROJECT_PIDS_MAX, so one project can never exhaust
//         the shared Machine's process budget;
//       - a private chroot (the project rootfs), a private console and a
//         private runner process per project;
//       - per-task tmpfs on /tmp inside each task's private mount namespace,
//         so parallel apt/pip tasks never share temp lock files.
//   * Per-task ceilings stay the fixed constants below (1.0 core, 256 MiB,
//     64 pids); TASKKILL / command cancel end in cgroup.kill, which reaps
//     double-fork/setsid escapees a process-group signal cannot reach (the
//     POC's A1 proof). Cancel-A-leaves-B-running is a cgroup property, not a
//     heuristic.
//   * Cross-project uid DAC separation between guests is deliberately NOT
//     claimed: all tasks are guest root. The boundary between projects is
//     the chroot + private mount table + cgroup tree, i.e. dependency/data/
//     lifecycle separation, not a uid security fence. The PID namespace is
//     shared machine-wide (a per-task pid namespace would break the runner's
//     kill(-pgid) escalation), so /proc inside a project shows Machine-wide
//     process metadata; project DATA stays isolated in each overlay.
//
// Native 9P owner semantics required (declared, unchanged authority):
//   * workspace exports (tag floe-ws-<slot>) use plain 9p2000.L: ownership is
//     presented as the mounting root, host mode bits apply; the host must
//     allow guest read/write for the mounting root (today's default).
//   * Project state lives on the ext4 state root only, NEVER on 9P.
//   * No host uid must equal a guest uid; guest chown is never passed
//     through to the Darwin host. Stricter workspace mapping, if ever
//     needed, must be specified by the native side; the guest does not
//     invent 9P idmapping.
//
// The POC distinction is preserved: the primitive proved namespace/cgroup/
// project-data isolation only. It did NOT prove full rootfs package-install
// isolation, production protocol integration, exhaustion behaviour or a host
// security boundary, and this supervisor makes no such claim either.
//
// Provenance: namespace/cgroup structure adapted from the verified
// Local/Private/linux-project-isolation-prototype-20261104 primitive
// (MPL-2.0 POC); this file and floe_project_supervisor.c are Floe production
// source. The fd-fix invariant (dup2(same fd) must clear FD_CLOEXEC
// explicitly, unrelated descriptors must not survive fork) is carried over
// unchanged.

#ifndef FLOE_PROJECT_SUPERVISOR_H
#define FLOE_PROJECT_SUPERVISOR_H

#include <stddef.h>
#include <stdint.h>

// ---------------------------------------------------------------------------
// Versions and table bounds (host mirror MUST match exactly)
// ---------------------------------------------------------------------------

#define FLOE_SUPERVISOR_VERSION "1.0.0"
// The supervisor control channel extends the runner wire protocol
// additively: data channels stay protocol 3; the control channel answers
// CAPS with protocol=4 so a protocol-3-only host can detect and refuse the
// new layout deterministically.
#define FLOE_SUPERVISOR_PROTOCOL 4

// Maximum concurrently open projects. Each project owns one console, one
// runner, one overlay and one cgroup subtree, so the table is bounded by
// the native console share budget. The host mirror is
// LinuxGuestProjectLimits.maximumProjects.
#define FLOE_MAX_PROJECTS 8
// Per-project runner concurrency is the existing runner table
// (MAX_CONCURRENT_COMMANDS 8 / MAX_CONCURRENT_SESSIONS 4); the supervisor
// only tracks cancel/kill by taskID, so it mirrors the same ceilings.
#define FLOE_MAX_PROJECT_TASKS 8
#define FLOE_MAX_PROJECT_SESSIONS 4

// Longest accepted projectID / taskID / generation token. IDs are opaque
// printable-ASCII labels supplied by the trusted host; they are validated
// and then used to build real paths, so the bounds are tight.
#define FLOE_MAX_PROJECT_ID 64
#define FLOE_MAX_TASK_ID 96
// Generation: decimal u64 text, so 20 digits.
#define FLOE_MAX_GENERATION 24

// Per-task cgroup ceilings. These are fixed supervisor constants applied to
// every task cgroup; a task that exceeds them is throttled/OOM-killed by
// the kernel, never by a heuristic, and one runaway task cannot starve the
// other projects sharing the machine. cpu.max is written "<quota> <period>".
#define FLOE_TASK_CPU_PERIOD_US 100000
#define FLOE_TASK_CPU_QUOTA_MAX_US 100000 // 1.0 core ceiling per task
#define FLOE_TASK_PIDS_MAX 64
#define FLOE_TASK_MEMORY_MAX_BYTES (256LL * 1024 * 1024)

// Settled user direction (2026-11-05): CPU and RAM are unified settings on
// the ONE shared local Linux runtime; project screens manage their own
// files, dependencies and tasks. There is therefore deliberately NO
// per-project cpu/memory quota in the PROJOPEN spec and no per-project
// machine shape: the machine shape is one host-owned admission setting.
// The project cgroup exists for lifecycle (cgroup.kill of the whole
// project) and pids containment only.
#define FLOE_PROJECT_PIDS_MAX 256

// Wire bounds shared with the runner protocol: one control envelope is
// reassembled with the same chunked framing (CHUNK/RUN) and the same
// 256 KiB envelope ceiling as EXEC.
#define FLOE_CTRL_MAX_PAYLOAD (256 * 1024)
#define FLOE_CTRL_MAX_CHUNKS 4096
#define FLOE_CTRL_MAX_INBOUND (256 * 1024)
#define FLOE_CTRL_MAX_TOKEN 96
#define FLOE_CTRL_IO_CHUNK 32768

// Leases serialize destructive project operations (PROJDROP, and package
// transactions the host runs per project). A lease is a host-side,
// supervisor-recorded token; bounded lifetime so a dead host cannot wedge a
// project forever.
#define FLOE_LEASE_MAX_MS (10 * 60 * 1000)
#define FLOE_LEASE_RENEW_GRACE_MS (60 * 1000)

// ---------------------------------------------------------------------------
// Identity validation (pure contract — implementation is in the .c)
// ---------------------------------------------------------------------------

// Valid projectID: [A-Za-z0-9] then up to 63 more of [A-Za-z0-9._-].
// No leading '/', no '..', no bytes outside printable ASCII. The ID is a
// LABEL, not a path: after validation the supervisor builds paths as
// "<state>/projects/<id>/..." with the validated label, so traversal and
// symlink/foreign-ID inputs are rejected before any filesystem use.
// Returns 1 when valid.
int floe_project_id_valid(const char *id);

// Same rules as the projectID, plus the runner-token width; taskIDs travel
// on control frames only (data-channel task identity stays the protocol-3
// console token).
int floe_task_id_valid(const char *task);

// Strict decimal u64 (1..20 digits, no sign, no space). 0 is accepted as a
// real generation number but a MISSING generation field is rejected by the
// frame parser before this is called.
int floe_generation_valid(const char *generation);

// ---------------------------------------------------------------------------
// Frame vocabulary (control console only; data consoles unchanged)
// ---------------------------------------------------------------------------
//
// Every control frame carries the project identity it acts on explicitly:
//
//   \x1eFLOE-PROJOPEN  <token> <projectID> <generation> <payloadBytes> <chunks>\x1e\n
//   \x1eFLOE-PROJCLOSE <token> <projectID> <generation>\x1e\n
//   \x1eFLOE-PROJDROP  <token> <projectID> <generation>\x1e\n
//   \x1eFLOE-PROJSTAT  <token>\x1e\n
//   \x1eFLOE-TASKKILL  <token> <projectID> <generation> <taskID>\x1e\n
//   \x1eFLOE-LEASE     <token> <projectID> <generation> <renew|release> <leaseID>\x1e\n
//   \x1eFLOE-PING      <token>\x1e\n
//
// plus the shared handshake/transfer frames HELLO, CHUNK, RUN. Replies use
// the existing guest frame names (CAPS/BEGIN/OUT/ERR/END/FAILED) plus one
// new asynchronous notice:
//
//   \x1eFLOE-EVENT <projectID> <generation> <kind> <detail...>\x1e\n
//
// where <kind> is one of: runner-died | task-unreaped | lease-expired |
// recovered. EVENT never carries command output; the host treats it like
// FAILED for liveness decisions.
//
// PROJOPEN payload = the standard u32 fieldCount table:
//   field 0: baseRootfs   (absolute immutable lower dir; MUST equal the
//                         supervisor-configured base rootfs — a frame can
//                         never redirect a project onto a foreign tree)
//   field 1: workspaceDir (absolute path inside the project rootfs view, or
//                         empty for the project home)
//   field 2: nativeShareSlot (single decimal 0..7 reserved by the host)
// No resource fields: the machine shape is one shared host-owned setting.
// The slot binds floe-ws-<slot> and hvc(slot+1); foreign/busy slots fail.
//
// Exit codes on the control channel reuse the runner vocabulary:
//   0 ok; 3 unknown projectID/generation/taskID; 125 table full / malformed
//   identity / malformed payload; 126 setup failure (mount/chroot/cgroup);
//   127 refused (lease held, refcount > 0, base rootfs mismatch).

// ---------------------------------------------------------------------------
// Runner environment handed over by the supervisor (guest-internal ABI)
// ---------------------------------------------------------------------------
//   FLOE_CGROUP_TASKS       absolute delegated task-cgroup dir
//                           (<project cgroup>/tasks); presence activates
//                           project isolation in the runner
//   FLOE_PROJECT_ID         validated project label (diagnostics only)
//   FLOE_PROJECT_GENERATION validated generation (diagnostics only)
// (The 2026-11-05 draft additionally exported FLOE_PROJECT_USERNS_FD and
// FLOE_TASK_UID_BASE for the idmapped-mount model; both were removed with
// that model and are never set.)

// ---------------------------------------------------------------------------
// Native/host requirements this contract depends on (other owners)
// ---------------------------------------------------------------------------
// * One live Machine; 1-5 CPUs; owned disk with an ext4 data area mounted by
//   init at the state root; independently addressed virtio consoles and 9P
//   share lifecycles (native device worker); existing guest NAT untouched.
// * Kernel >= 5.14 (cgroup.kill); Debian trixie ARM64 6.12 qualifies with
//   huge margin. No idmapped-mount, user-namespace or overlay-idmap kernel
//   feature is required anywhere in this design.
// * init starts floe-supervisord (a small static binary, no Debian PID 1
//   dependency) on console 0 and passes the trusted roots:
//     floe.base=<abs dir>      immutable base rootfs (read-only lower), a
//                              DEDICATED subtree (e.g. <mnt>/base) so the
//                              overlay lower never contains the project's own
//                              upper/work siblings
//     floe.state=<abs dir>     ext4 state root (project overlays, leases)
//     floe.workspace=<abs dir> shared workspace root (may equal state)
//     floe.runner=<abs path>   trusted floe-exec binary, bind-mounted ro into
//                              each project root at /usr/local/bin/floe-exec
//   All four are absolute, init-owned and validated; when floe.base or
//   floe.state is missing the supervisor still starts and answers CAPS, but
//   PROJOPEN fails with END 126 — never a fake success string.
// * Per-project consoles: the supervisor opens /dev/hvcN for the project it
//   spawns and dups it over the runner's stdio. Consoles the native side did
//   not export simply do not exist; the supervisor never creates devices.
//   8 projects + 1 control console = 9 virtio consoles (coordinator note
//   2026-11-05: native side to raise the console cap to 9).
// * Per-project workspace share (required before successful PROJOPEN): a 9p2000.L export
//   tagged floe-ws-<slot>, mounted by the supervisor at /workspace
//   before PROJOPEN reports success. Ownership is presented as the mounting
//   root (guest root); host mode bits apply; the host must allow guest
//   read/write for the mounting root. When the share is absent the project
//   keeps a private in-rootfs /workspace and the PROJOPEN answer records
//   share=private. The PROJOPEN workspaceDir payload field selects the
//   in-project working directory ("/workspace" by default).
// * Project runtime view: fresh proc/sysfs, a MINIMAL private /dev
//   (null/zero/full/random/urandom/tty + devpts with a ptmx symlink — no
//   devtmpfs, so other projects' consoles never appear inside this
//   project), tmpfs on /tmp and /dev/shm, and a bind of ONLY this
//   project's cgroup subtree at /sys/fs/cgroup. The PID namespace stays
//   shared machine-wide (per-task pid namespaces would break the runner's
//   kill(-pgid) escalation and PTY job control); accidental cross-project
//   control is prevented by the minimal /dev, the scoped cgroup view and
//   the private mount/chroot instead.

#endif // FLOE_PROJECT_SUPERVISOR_H
