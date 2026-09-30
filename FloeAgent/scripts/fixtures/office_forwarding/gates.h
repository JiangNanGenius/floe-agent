/* Deterministic gates around the REAL pinned fakeSocket entry points.
 *
 * The extracted forwarding-loop code (original and patched variants) is
 * compiled with the three calls that form the two race windows renamed to
 * floe_gate_* at the preprocessor level, so the loop text stays byte-faithful
 * while the harness can freeze one consumer exactly inside a window:
 *
 *   window 1: fakeSocketPoll returned POLLIN  ->  fakeSocketAvailableDataLength
 *   window 2: fakeSocketAvailableDataLength   ->  fakeSocketRead
 *
 * Disarmed gates are thin pass-throughs into the real implementation. An
 * armed gate holds only the FIRST caller (one-shot); every later caller
 * passes, so a second consumer can race ahead deterministically.
 */
#pragma once

#include <poll.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

int floe_gate_poll(struct pollfd *fds, int nfds, int timeout);
ssize_t floe_gate_available(int fd);
ssize_t floe_gate_read(int fd, void *buf, size_t nbytes);

#ifdef __cplusplus
}
#endif

/* Harness-side control (not part of the production path): */
void floeGateReset();
/* Arm a one-shot hold at the named point: "after_poll", "after_available",
 * or "before_read". */
void floeGateArm(const char *point);
/* Wait until a gated call has entered the hold (bounded; returns 1 on
 * timeout so a scenario fails loudly instead of hanging). */
int floeGateWaitEntered(const char *point, int timeoutMs);
/* Release the held caller. */
void floeGateRelease(const char *point);
/* Passive instrumentation: number of poll calls that went through the gate
 * (spin detection) and number of records delivered to the JS sink. */
long floeGatePollCount();
