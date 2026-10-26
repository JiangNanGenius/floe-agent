// FloeExecution — Linux guest loopback startup provisioning.
//
// The pinned Debian guest's PID 1 runner (floe_exec.c) provisions eth0 only;
// the kernel creates `lo` but nothing brings it UP or assigns 127.0.0.1. A
// guest-local client that dials 127.0.0.1 (exec.localService supervisor
// checks, webapp self-fetches, MCP-over-guest-HTTP) then routes the SYN out
// eth0 into slirp, which dials the HOST loopback of the same port — hanging
// the guest self-fetch while the host-side forward of the same port stays
// healthy. Actual run evidence (2026-10-26, LOCALHTTP28-ACTUAL-EVIDENCE):
// lo flags 0x8/down, no 127 local route, `127.0.0.1 via 10.0.2.2 dev eth0`;
// one stdlib-only provisioning restores every self-HTTP probe.
//
// This helper owns exactly one bounded, idempotent, guest-local repair frame
// issued once per real boot from `TinyEMULinuxGuestRegistry.performStart` —
// after the runner handshake/reboot settles and before the session registers,
// so no exec/local-service workload can observe a guest whose 127.0.0.1 still
// leaks out eth0. It touches only `lo`; it never modifies eth0, non-local
// routes, resolv.conf, host forwards, host networking, or the `net=` status
// vocabulary the runner reports.

import Foundation

/// Outcome of one per-boot loopback provisioning attempt. Recorded on the
/// registry and on the session for diagnostics; it never gates guest
/// availability and never redefines the reported network status.
enum LinuxGuestLoopbackProvisioningOutcome: String, Sendable {
    /// `lo` is UP and 127.0.0.1/8 now answers as a kernel local route.
    case provisioned
    /// The guest already had `lo` UP with 127.0.0.1 (a future runner image
    /// that provisions loopback itself, or a same-generation re-entry):
    /// nothing was changed.
    case skippedAlreadyHealthy
    /// The image exposes neither `ip` (iproute2 — shipped in the pinned
    /// image, used by its own stage-1 installer and positively confirmed in
    /// the running guest) nor the pinned `python3` package, so no repair
    /// could run at all.
    case failedNoProvisioningTool
    /// A provisioning tool ran but the post-check (IFF_UP plus 127.0.0.1 in
    /// /proc/net/fib_trie) still fails — reported honestly; the guest is
    /// otherwise exactly as usable as before.
    case failedRepairRejected
    /// The frame completed but printed no recognizable marker (a scripted
    /// console, or a guest shell that could not run the repair verbatim).
    case failedUnrecognized
    /// The frame itself could not complete (channel error, timeout silence,
    /// guest FAILED, or a closing console). When this left the single
    /// console poisoned, the registry abandons the boot under the existing
    /// poisoned-console contract instead of registering an unusable guest.
    case failedCommandUnavailable
}

enum LinuxGuestLoopbackProvisioning {
    /// One bounded frame. The repair itself is milliseconds; the budget only
    /// covers a guest still busy with boot IO. Deliberately far below the
    /// 60 s runner-probe budget and the committed 8 s guest-HTTP ceilings it
    /// protects; it is a startup cost, never a per-command overhead.
    static let commandTimeout: TimeInterval = 10
    /// The script prints exactly one marker line; keep the ceiling tight so
    /// a misbehaving guest cannot flood the boot path.
    static let maxOutputBytes = 4096

    /// Guest-side repair: validate, repair only when needed, validate again.
    /// Idempotent (the healthy-state check is pure procfs, so a second run on
    /// an already-healthy or already-repaired guest is a cheap no-op) and
    /// guest-local only (`lo` never shares state with eth0 or the host).
    ///
    /// Tool preference mirrors the image's own tooling, inspected rather
    /// than assumed: the pinned Debian image ships iproute2 (`ip` is used by
    /// guest-stage1-install.sh and answered inside the running guest,
    /// DIAG_IP=yes); the pinned `python3` image package is the proven
    /// fallback — the same stdlib ioctls the runner itself uses for eth0,
    /// demonstrated live by the 2026-10-26 diagnostic. procfs supplies the
    /// validation reads on every Linux kernel, so the healthy-state check
    /// has no userspace-tool dependency at all.
    static let shellCommand = """
if [ -r /sys/class/net/lo/flags ] && [ -r /proc/net/fib_trie ] \\
    && [ $(( $(cat /sys/class/net/lo/flags) & 1 )) -eq 1 ] \\
    && grep -q -w 127.0.0.1 /proc/net/fib_trie 2>/dev/null; then
    echo FLOE_LOOPBACK=skipped-already-healthy
    exit 0
fi
repair_rc=1
if command -v ip >/dev/null 2>&1; then
    if ip link set lo up >/dev/null 2>&1 \\
        && ip addr replace 127.0.0.1/8 dev lo >/dev/null 2>&1; then
        repair_rc=0
    fi
fi
if [ "$repair_rc" -ne 0 ] && command -v python3 >/dev/null 2>&1; then
    if PYTHONDONTWRITEBYTECODE=1 python3 -c '
import fcntl, socket, struct
sk = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
name = b"lo" + b"\\x00" * 14
flags = struct.unpack("16sH22s", fcntl.ioctl(sk, 0x8913, name + b"\\x00" * 24))[1]
for op, addr in ((0x8916, "127.0.0.1"), (0x891C, "255.0.0.0")):
    sa = struct.pack("HH4s8s", socket.AF_INET, 0, socket.inet_aton(addr), b"\\x00" * 8)
    fcntl.ioctl(sk, op, name + sa + b"\\x00" * 8)
fcntl.ioctl(sk, 0x8914, struct.pack("16sH22s", name, flags | 1, b"\\x00" * 22))
'; then
        repair_rc=0
    fi
fi
if [ "$repair_rc" -ne 0 ]; then
    if ! command -v ip >/dev/null 2>&1 && ! command -v python3 >/dev/null 2>&1; then
        echo FLOE_LOOPBACK=failed-no-tool
    else
        echo FLOE_LOOPBACK=failed-still-down
    fi
    exit 0
fi
if [ -r /sys/class/net/lo/flags ] && [ -r /proc/net/fib_trie ] \\
    && [ $(( $(cat /sys/class/net/lo/flags) & 1 )) -eq 1 ] \\
    && grep -q -w 127.0.0.1 /proc/net/fib_trie 2>/dev/null; then
    echo FLOE_LOOPBACK=provisioned
else
    echo FLOE_LOOPBACK=failed-still-down
fi
exit 0
"""

    /// Marker vocabulary printed by the guest script. Exactly one line is
    /// the contract; more than one distinct marker (or a marker on a
    /// nonzero exit) means the frame did not run as written and must never
    /// be read as success.
    private static let markers: [String: LinuxGuestLoopbackProvisioningOutcome] = [
        "FLOE_LOOPBACK=skipped-already-healthy": .skippedAlreadyHealthy,
        "FLOE_LOOPBACK=provisioned": .provisioned,
        "FLOE_LOOPBACK=failed-no-tool": .failedNoProvisioningTool,
        "FLOE_LOOPBACK=failed-still-down": .failedRepairRejected,
    ]

    /// Maps the guest's marker line to the host-side outcome. Honest by
    /// construction: a nonzero exit, a missing marker, or anything other
    /// than exactly one marker line (duplicates or conflicts) classifies as
    /// failure — success is only ever returned for one clean marker on a
    /// zero exit, so truncated or mangled output can never masquerade as a
    /// provisioned guest.
    static func outcome(from result: LinuxCommandResult) -> LinuxGuestLoopbackProvisioningOutcome {
        guard result.exitCode == 0 else { return .failedUnrecognized }
        // A successful frame prints one complete marker line. Reject a
        // clipped, suffixed or conflicting reply rather than finding a
        // success substring inside an incomplete response.
        let marker = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return markers[marker] ?? .failedUnrecognized
    }
}
