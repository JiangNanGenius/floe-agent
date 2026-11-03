/* SPDX-License-Identifier: MPL-2.0
 *
 * Floe root-capture guard: an independently-running bound inside the pinned
 * tcpdump helper.
 *
 * The guard is not a wrapper and does not spawn a child. It is compiled into
 * the same AArch64 PIE as tcpdump and starts one detached POSIX thread after
 * tcpdump has parsed its options and installed its signal handlers. That
 * thread has three independent stop conditions:
 *
 *   1. EOF/HUP on stdin (fd 0). The root server owns the write end of the
 *      ProcessBuilder pipe and does not close it; when the server is killed,
 *      the kernel closes the write end and the helper sees an exact liveness
 *      signal without PID polling or PID-reuse races.
 *   2. A monotonic deadline derived from the server-supplied, validated
 *      duration bound.
 *   3. An output file size bound, with RLIMIT_FSIZE as the kernel backstop.
 *
 * On a stop condition the guard writes one fsynced stop record to
 * "<pcap>.guard", asks tcpdump to stop through its own SIGTERM handler
 * (pcap_breakloop), and then guarantees process exit within a fixed grace
 * even if capture cleanup is stuck. The partially written PCAP is preserved.
 *
 * Configuration is read once from stdin before capture starts:
 *
 *   floe-guard-v1 <maxMillis> <maxBytes> <absoluteOutputPath>\n
 *
 * maxMillis is 1..600000 and maxBytes is 4096..268435456. A missing,
 * malformed, mismatched or out-of-range line fails closed; there is no
 * permissive default. The path must be exactly the -w path passed to
 * tcpdump by the server.
 */
#ifndef FLOE_CAPTURE_GUARD_H
#define FLOE_CAPTURE_GUARD_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define FLOE_GUARD_CONFIG_SCHEMA "floe-guard-v1"
#define FLOE_GUARD_SIDECAR_SCHEMA "floe.capture-guard.v1"
#define FLOE_GUARD_VERSION 1

/* Hard upper bounds; anything above is rejected, never clamped down into an
 * accidental permissive capture. The server's own limits are lower. */
#define FLOE_GUARD_MAX_MILLIS 600000ULL          /* 10 minutes */
#define FLOE_GUARD_MAX_BYTES (256ULL * 1024ULL * 1024ULL)
#define FLOE_GUARD_MAX_PATH 4096
#define FLOE_GUARD_MAX_CONFIG 4096

struct floe_guard_config {
    uint64_t max_millis;
    uint64_t max_bytes;
    char output_path[FLOE_GUARD_MAX_PATH];
};

/* Pure parser used by install and by the host contract test. Returns 0 on
 * success, -1 on any malformed/out-of-range field. The line may end with a
 * single '\n' and must otherwise contain exactly one record. */
int floe_capture_guard_parse_config(const char *line, struct floe_guard_config *out);

/* Installs the guard into the current process. Must be called after tcpdump's
 * signal handlers are installed and before capture output is opened.
 * [wfile] is tcpdump's -w argument (may be NULL, which fails closed).
 * Returns 0 when the guard thread is running and the ready record is durable.
 * Any other value means the helper must not continue; the caller reports a
 * startup error. */
int floe_capture_guard_install(const char *wfile);

/* Test seam: the reason whitelist shared by production and contract tests.
 * Returns a stable reason string for a known stop line, otherwise NULL. */
const char *floe_capture_guard_stop_reason(const char *line);

/* The identity record retains the exact build-time hashes even after
 * llvm-strip --strip-all. The verifier searches for the magic prefix. */
#define FLOE_GUARD_IDENTITY_MAGIC "FLOE_CAPTURE_GUARD_V1|"
#define FLOE_GUARD_ABI "arm64-v8a"

#ifdef __cplusplus
}
#endif

#endif /* FLOE_CAPTURE_GUARD_H */
