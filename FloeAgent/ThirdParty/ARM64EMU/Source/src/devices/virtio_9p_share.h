/* SPDX-License-Identifier: Apache-2.0 */
/* Copyright 2026 Floe contributors */
/* virtio-9p live share-slot lifecycle (standalone, no engine types).
 *
 * One 9P device == one share slot for the whole machine lifetime: the guest
 * probes the slot at boot, so the device must exist before the OS is up.
 * Projects join and leave by attaching/detaching a pinned host root to a
 * slot — the machine and its other projects are never restarted for one
 * project's sake.
 *
 * This header is the pure state machine behind that lifecycle so the focused
 * qualification tests can exercise it without a Machine:
 *
 *   DETACHED --attach(root pinned by caller)--> ATTACHED
 *   ATTACHED  --detach(force=0, no open handles)--> DETACHED
 *   ATTACHED  --detach(force=1)-------------------> DETACHED   (drain)
 *
 * Generation fences: attach and detach both bump the generation. A guest fid
 * remembers the generation it was created under; p9s_fid_live() tells the
 * device to answer every stale-fid operation with ESTALE. A replaced root
 * therefore can never be reached through a fid bound to the older root, and
 * a detached-then-reattached slot can never serve an old project through a
 * leftover handle. The device owns the actual handle close/dup timing; this
 * struct only counts them so detach can refuse BUSY honestly.
 */
#ifndef A64_VIRTIO_9P_SHARE_H
#define A64_VIRTIO_9P_SHARE_H

#include <stdbool.h>
#include <stdint.h>

enum {
    P9_SHARE_DETACHED = 0,
    P9_SHARE_ATTACHED = 1,
    P9_SHARE_DRAINING = 2
};

typedef struct P9Share {
    int      state;           /* P9_SHARE_* */
    uint64_t generation;      /* bumped on every attach/detach; never 0 */
    uint32_t guest_uid;       /* synthetic owner presented to the guest */
    uint32_t guest_gid;
    bool     ro;
    uint32_t open_handles;    /* live host-side fid handles (fd or DIR*) */
} P9Share;

static inline void p9s_init(P9Share *s) {
    s->state = P9_SHARE_DETACHED;
    s->generation = 1;
    s->guest_uid = 0;
    s->guest_gid = 0;
    s->ro = false;
    s->open_handles = 0;
}

/* Bind a freshly pinned host root. Only a detached slot accepts; the caller
 * validates the slot tag and pins the descriptor before calling. Returns 0
 * or -1 (EBUSY) when the slot is still attached. */
static inline int p9s_attach(P9Share *s, uint32_t guest_uid, uint32_t guest_gid,
                             bool ro) {
    if (s->state != P9_SHARE_DETACHED) return -1;
    s->guest_uid = guest_uid;
    s->guest_gid = guest_gid;
    s->ro = ro;
    s->open_handles = 0;
    s->state = P9_SHARE_ATTACHED;
    s->generation++;               /* old fids go stale */
    return 0;
}

/* Release the slot. force=0 refuses while the guest holds host handles so a
 * normal project close never tears open files out from under it; force=1
 * drains immediately (the caller closes the handles) and the guest sees
 * ESTALE on its stale fids. Returns 0 or -1 (EBUSY). */
static inline int p9s_detach(P9Share *s, bool force) {
    if (s->state != P9_SHARE_ATTACHED) return -1;
    if (s->open_handles != 0 && !force) return -1;
    if (s->open_handles != 0) s->state = P9_SHARE_DRAINING;
    s->open_handles = 0;
    s->state = P9_SHARE_DETACHED;
    s->generation++;               /* replacement cannot reuse old fids */
    return 0;
}

/* A fid created under generation G stays live only while the slot generation
 * is unchanged. */
static inline bool p9s_fid_live(const P9Share *s, uint64_t fid_generation) {
    return s->state != P9_SHARE_DETACHED && fid_generation == s->generation;
}

#endif /* A64_VIRTIO_9P_SHARE_H */
