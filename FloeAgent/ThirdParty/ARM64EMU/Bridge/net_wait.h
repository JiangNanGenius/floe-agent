/* SPDX-License-Identifier: MPL-2.0 */
/* Shared readiness-park helper for the two runtime wait sites.
 *
 * Header-only on purpose: both Bridge/runtime.c (floe_ae_wait_event) and
 * Bridge/parallel_runtime.c (parallel_epoch's hart-busy wait) need the exact
 * same behaviour, and a header needs no build-manifest change to be picked up
 * by either translation unit.
 *
 * What this fixes
 * ---------------
 * The previous code snapshotted bare descriptors through usernet_wait_fds()
 * and polled every one of them with POLLIN|POLLERR|POLLHUP. A host descriptor
 * that the backend wants to write to — a connect() still in progress, or a
 * send buffer with room again — therefore could never wake the park, so the
 * guest stalled until its own CPU/RTC/budget deadline. The snapshot also
 * carried no network deadline, so the backend's own timers (delayed ACK at
 * 2 ms, slowtimo at 499 ms, IPv6 RA) were not represented, and it was capped
 * at a fixed 128 descriptors with a silent overflow.
 *
 * This helper asks the backend for the descriptor set, the per-descriptor
 * interest mask libslirp actually computed, and the next network deadline,
 * through the versioned USERNET_WAIT_ABI 2 API. Nothing here reinterprets an
 * existing reserved field and nothing in include/floe_arm64emu.h changes.
 *
 * Degraded states are explicit
 * ----------------------------
 * If the readiness set cannot be represented completely — the fill failed, an
 * allocation failed, the set had to degrade to the wake pipe alone, or the
 * backend reported truncation — this helper must NOT sleep on the caller's
 * budget as though the network had nothing pending. floe_ae_wait_event accepts
 * up to 60 s, so losing the socket and timer set and then sleeping that long
 * would stall the guest. Every such state clamps the park to a bounded short
 * retry while still watching the control wake pipe, so a control signal is
 * never delayed and a persistent failure can never become an unbounded sleep.
 *
 * Descriptor lifetime
 * -------------------
 * USERNET_WAIT_F_DUP makes the backend hand back dup(2) references, so this
 * function owns independent descriptors for the whole poll and a descriptor
 * the backend closes can never be polled through a reused number. This
 * function closes exactly what it received, on every path including the fill
 * error path and allocation failure.
 *
 * The snapshot itself is taken under the quiescence the two call sites already
 * establish: floe_ae_wait_event has incremented s->waiters (so hostfwd
 * add/remove, share attach/detach and destroy all return FLOE_AE_BUSY), and
 * parallel_epoch services every guest bus access on this same coordinator
 * thread through the RPC_BUS mailbox, so no other thread is inside the backend.
 */
#ifndef FLOE_AE_NET_WAIT_H
#define FLOE_AE_NET_WAIT_H

#include "embedded_internal.h"
#include "../Source/src/net/usernet.h"

#include <limits.h>
#include <poll.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* Hard ceiling on the descriptors one park will represent. Generous relative
 * to the backend's own bounded socket ceiling (USERNET_DEF_MAX_SOCKETS); if the
 * backend ever reports more it sets USERNET_WAIT_R_TRUNCATED and the park
 * degrades to the bounded retry below rather than sleeping on a partial set. */
#define AE_NET_WAIT_FD_CEILING 4096u

/* Bounded retry for every degraded state. Short enough that a lost socket or
 * timer deadline cannot matter, long enough that a persistent allocation
 * failure cannot turn into a spin loop (<=100 wakeups/s), and the control wake
 * pipe stays in the set throughout so host input/stop is never delayed. */
#define AE_NET_WAIT_DEGRADED_RETRY_MS 10u

/* Park until the session wake pipe is signalled, one of the backend's
 * descriptors becomes ready for the interest the backend asked for, or the
 * earliest real deadline expires.
 *
 * wait_ns is the caller's own remaining budget in nanoseconds (0 = do not
 * sleep, matching the previous behaviour). Returns true when the wake pipe
 * reported readiness and the caller should drain it.
 *
 * `un` may be NULL (network disabled): the park then degrades to the wake pipe
 * plus the caller's deadline. With neither, it still performs a legal timed
 * sleep — poll() with nfds == 0 — because returning immediately would turn the
 * caller's park into a busy spin and burn a core on a WFI-idle guest. */
static inline bool ae_net_wait_park(AESession *s, UserNet *un, uint64_t wait_ns) {
    if (!s) return false;

    UserNetWaitResult res;
    memset(&res, 0, sizeof(res));
    res.struct_size = sizeof(res);
    UserNetWaitFd *fds = NULL;
    bool filled = false;
    /* True whenever the readiness set we are about to sleep on does not fully
     * represent the backend's descriptors and deadlines. */
    bool degraded = false;

    if (un) {
        fds = (UserNetWaitFd *)malloc(sizeof(*fds) * AE_NET_WAIT_FD_CEILING);
        if (!fds) {
            degraded = true;                 /* cannot even hold the request */
        } else {
            UserNetWaitRequest req;
            memset(&req, 0, sizeof(req));
            req.struct_size = sizeof(req);
            req.abi = USERNET_WAIT_ABI;
            req.capacity = AE_NET_WAIT_FD_CEILING;
            req.flags = USERNET_WAIT_F_DUP;
            req.entries = fds;
            /* res.count is authoritative for how many dup'd descriptors this
             * function owns, on the success path and on the error path. */
            filled = (usernet_fill_wait(un, &req, &res) == 0);
            if (!filled) degraded = true;
            else if (res.truncated ||
                     (res.flags & USERNET_WAIT_R_TRUNCATED) != 0)
                degraded = true;
        }
    }

    /* ---- deadline: the caller's budget and the backend's next network timer
     * ---- */
    uint64_t eff_ns = wait_ns;
    if (filled && (res.flags & USERNET_WAIT_R_DEAD) == 0) {
        if (res.timeout_ms == 0) {
            eff_ns = 0;                      /* the backend wants an immediate re-run */
        } else if (res.timeout_ms != UINT32_MAX) {
            uint64_t net_ns = (uint64_t)res.timeout_ms * 1000000ULL;
            if (net_ns < eff_ns) eff_ns = net_ns;
        }
        /* UINT32_MAX means "no network deadline": sleep on the caller's own. */
    }
    if (degraded) {
        uint64_t retry_ns = (uint64_t)AE_NET_WAIT_DEGRADED_RETRY_MS * 1000000ULL;
        if (retry_ns < eff_ns) eff_ns = retry_ns;
    }

    /* ---- build the poll set: wake pipe first, then the backend's descriptors
     * with the exact interests it asked for ---- */
    const uint32_t owned = res.count;   /* dup'd descriptors this call must close */
    uint32_t want_total = owned + (s->wake_pipe_ready ? 1u : 0u);
    uint32_t fds_in_set = owned;
    struct pollfd stack_fallback[1];
    struct pollfd *pf = NULL;
    bool used_fallback = false;
    int pipe_idx = -1;
    uint32_t total = 0;

    if (want_total > 0) pf = (struct pollfd *)malloc(sizeof(*pf) * want_total);

    if (!pf && s->wake_pipe_ready) {
        /* Allocation failure must not lose the control wake. Degrade to the
         * pipe alone rather than skipping the park, and mark the set
         * incomplete so the deadline is clamped below. */
        pf = stack_fallback;
        used_fallback = true;
        want_total = 1;
        fds_in_set = 0;
        degraded = true;
    } else if (!pf && owned > 0) {
        /* No wake pipe and no memory for the descriptor array: the network
         * set is unrepresentable. Fall through to a bounded timed sleep. */
        fds_in_set = 0;
        degraded = true;
    }

    if (degraded) {
        uint64_t retry_ns = (uint64_t)AE_NET_WAIT_DEGRADED_RETRY_MS * 1000000ULL;
        if (retry_ns < eff_ns) eff_ns = retry_ns;
    }

    if (pf) {
        uint32_t k = 0;
        if (s->wake_pipe_ready && k < want_total) {
            pipe_idx = (int)k;
            pf[k].fd = s->wake_pipe[0];
            pf[k].events = POLLIN | POLLERR | POLLHUP;
            pf[k].revents = 0;
            k++;
        }
        for (uint32_t i = 0; i < fds_in_set && k < want_total; i++) {
            pf[k].fd = fds[i].fd;
            pf[k].events = (short)fds[i].events;
            pf[k].revents = 0;
            k++;
        }
        total = k;
    }

    int ready = 0;
    if (eff_ns) {
        int timeout_ms;
        if (eff_ns >= (uint64_t)INT_MAX * 1000000ULL) timeout_ms = INT_MAX;
        else timeout_ms = (int)((eff_ns + 999999ULL) / 1000000ULL);
        if (timeout_ms <= 0) timeout_ms = 1;
        if (total > 0) {
            ready = poll(pf, (nfds_t)total, timeout_ms);
        } else {
            /* Nothing to watch (network disabled, or an unrepresentable set).
             * poll() with nfds == 0 is a legal pure timed sleep and preserves
             * the previous park semantics; skipping it would spin. */
            struct pollfd none[1];
            ready = poll(none, 0, timeout_ms);
        }
    }

    bool pipe_ready = (ready > 0 && pipe_idx >= 0 &&
                       (pf[pipe_idx].revents & (POLLIN | POLLERR | POLLHUP)) != 0);

    /* Close exactly the descriptors the backend duplicated for us. This runs
     * on every path, including the fill error path and allocation failure. */
    for (uint32_t i = 0; i < owned; i++) {
        if (fds && fds[i].fd >= 0) close(fds[i].fd);
    }
    if (!used_fallback) free(pf);
    free(fds);
    return pipe_ready;
}

#endif /* FLOE_AE_NET_WAIT_H */
