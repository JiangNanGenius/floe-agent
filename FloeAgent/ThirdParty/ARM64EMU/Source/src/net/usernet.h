/* SPDX-License-Identifier: Apache-2.0 */
/* Copyright 2026 Sylirre */
/* Modified by Floe contributors, 2026-11-10: mature network backend,
 * bounded event integration and virtual-NIC scheduling/offloads. */
/* usernet: user-mode NAT backend for the virtio-net device.
 *
 * The simplified in-tree IPv4-only TCP/UDP
 * stack is replaced by pinned libslirp 4.9.7 (commit
 * ce12dcddf710a71dc0de6450ec95edbadf8e9f66, BSD-3-Clause) behind this exact
 * header. The Ethernet contract below is unchanged, so
 * the NIC offload path hands normalized ordinary Ethernet frames to
 * usernet_input().
 *
 * Fixed topology preserved from the previous stack: guest 10.0.2.15/24,
 * gateway/host 10.0.2.2, DNS 10.0.2.3. Guest flows are terminated by libslirp
 * and proxied through ordinary nonblocking host sockets — no TAP, no TUN, no
 * privileges, no process execution, no downloaded code.
 *
 * ABI policy
 * ----------
 * Every symbol and every struct layout that existed before this candidate is
 * preserved byte-for-byte. New capability is added ONLY through the
 * explicitly versioned structs below (UserNetWaitRequest/UserNetWaitResult,
 * UserNetDnsInfo, UserNetConfig). No pre-existing `reserved` field is ever
 * reinterpreted, and floe_ae_net_info in include/floe_arm64emu.h is untouched.
 *
 * Threading contract (unchanged, now load-bearing)
 * ------------------------------------------------
 * usernet_input(), usernet_poll(), usernet_guest_reset(),
 * usernet_add_hostfwd(), usernet_remove_hostfwd() and usernet_fill_wait()
 * mutate backend state and MUST run on the single machine coordinator thread,
 * serialized by the existing session/parallel quiescence rules. In the
 * parallel runtime every guest MMIO access to virtio-net is serviced by the
 * coordinator through the RPC_BUS mailbox (Bridge/parallel_runtime.c:294
 * machine_bus_service), so hart workers never enter this backend directly.
 * usernet_get_stats() and usernet_get_dns_info() are the only calls safe from
 * an arbitrary thread: they read atomically published snapshots and never
 * touch libslirp's internal socket lists.
 */
#ifndef USERNET_H
#define USERNET_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct UserNet UserNet;

typedef bool (*usernet_output_fn)(void *opaque, const uint8_t *frame, size_t len);

/* guest_mac: the MAC the device advertises in config space, so frames can
 * be addressed to the guest before it ever transmits. dns_server: host-order
 * IPv4 of the resolver guest DNS relays to, or 0 to probe the host. Returns
 * NULL only on allocation failure (all owned state is released then). */
UserNet *usernet_new(usernet_output_fn output, void *opaque,
                     const uint8_t guest_mac[6], uint32_t dns_server);
/* Full teardown: closes every host descriptor libslirp owns, frees the
 * deferred-TX queue, the timers, the poll set and the instance. The output
 * callback is never invoked after this returns. Safe on a quiet machine
 * before device destruction, and safe to call on a partially built instance. */
void     usernet_destroy(UserNet *un);
/* Bind a loopback host listener (TCP) or socket (UDP) forwarding to
 * 10.0.2.15:guest_port. Returns 0, or -errno on failure (EADDRINUSE when the
 * host port is taken, EMFILE/ENFILE, ENOMEM...). Rules persist across guest
 * reboots; usernet_remove_hostfwd closes and drops one. -ENOBUFS when the
 * rule table is full (FLOE_AE_MAX_NET_FORWARDS), which the bridge maps to
 * FLOE_AE_UNSUPPORTED exactly as before. */
int      usernet_add_hostfwd(UserNet *un, bool is_udp,
                             uint16_t host_port, uint16_t guest_port);
int      usernet_remove_hostfwd(UserNet *un, bool is_udp, uint16_t host_port);
/* Feed one ordinary Ethernet frame (no virtio header, no FCS) from the guest
 * TX queue. Frames are dropped, never queued unboundedly; see the bounded
 * per-VM socket ceiling in UserNetConfig. */
void     usernet_input(UserNet *un, const uint8_t *frame, size_t len);
/* Nonblocking driver, called from machine_tick / virtio_net_poll. Flushes
 * deferred TX, runs libslirp's TCP/IP timers and dispatches real host socket
 * readiness. Always pairs one fill with one dispatch. */
void     usernet_poll(UserNet *un);
/* Guest-driven device reset (warm reboot): tear down all flows but keep
 * host-side listeners and sockets that outlive the guest. */
void     usernet_guest_reset(UserNet *un);

/* Resolver relay target actually in use (host-order IPv4), or 0 when guest
 * IPv4 DNS cannot be served and will be refused. Cheap and thread-safe: reads
 * a published snapshot, never probes inside the call. */
uint32_t usernet_dns_server(UserNet *un);
/* Live counters (never atexit). Any pointer may be NULL. Thread-safe.
 * tcp_conns/udp_flows count the distinct host descriptors libslirp asked to
 * have polled at the most recent fill, by socket type. */
void     usernet_get_stats(UserNet *un,
                           uint64_t *in_frames, uint64_t *out_ok,
                           uint64_t *out_refused,
                           unsigned *tcp_conns, unsigned *udp_flows);
/* DEPRECATED, kept only so an unpatched Bridge/runtime.c or
 * Bridge/parallel_runtime.c still links and still parks correctly. Returns a
 * bare descriptor snapshot with no interest mask and no deadline, which is
 * exactly the information loss this candidate fixes. New callers must use
 * usernet_fill_wait(). Descriptors are NOT duplicated: the caller must hold
 * backend quiescence, as the two existing wait sites do. */
int      usernet_wait_fds(UserNet *un, int *fds, int max);

/* ---- versioned readiness-wait ABI (v2) -----------------------------------
 *
 * Purpose: feed BOTH runtime wait sites (Bridge/runtime.c floe_ae_wait_event
 * and Bridge/parallel_runtime.c parallel_epoch) with the exact descriptors,
 * the exact per-descriptor interest mask libslirp wants, and libslirp's own
 * next-timer deadline — instead of the previous fd-only POLLIN|POLLERR|POLLHUP
 * snapshot that could never wake on a write-ready descriptor.
 *
 * Lifecycle: one usernet_fill_wait() produces one snapshot. The snapshot is
 * consumed by exactly one poll(2) in the waiter and then discarded; the
 * backend re-fills before every dispatch, so a fill that is never dispatched
 * cannot corrupt state. A fill MAY close descriptors that libslirp has let
 * expire (UDP/ICMP idle timeout), so it requires the same quiescence as
 * usernet_poll().
 */
#define USERNET_WAIT_ABI 2u

/* Descriptor plus the interest mask to hand to poll(2). `events` uses the
 * ordinary POLLIN/POLLOUT/POLLPRI/POLLERR/POLLHUP values from <poll.h>. */
typedef struct UserNetWaitFd {
    int fd;
    int events;
} UserNetWaitFd;

/* Caller asks the backend to duplicate every descriptor into the snapshot, so
 * the waiter owns independent references and a descriptor closed by another
 * path can never be polled through a reused number. The caller then owns and
 * must close all `count` descriptors. On failure no descriptor is duplicated. */
#define USERNET_WAIT_F_DUP 0x1u

/* Set in UserNetWaitResult.flags when `timeout_ms` is a real libslirp timer
 * deadline rather than "nothing pending". */
#define USERNET_WAIT_R_TIMER_ARMED 0x1u
/* Set when libslirp's notify callback fired since the last fill: a send
 * buffer drained below its half-full mark, so slirp can accept more guest
 * data. The waiter should re-enter the driver promptly. */
#define USERNET_WAIT_R_NOTIFY (0x1u<<1)
/* Set when the deferred guest-TX queue still holds frames the device RX ring
 * refused. The returned timeout is clamped so the retry is prompt. */
#define USERNET_WAIT_R_TX_PENDING (0x1u<<2)
/* Set when `wanted` exceeded `capacity`. The returned timeout is clamped to a
 * bounded short value so descriptors that did not fit are still serviced
 * promptly instead of being starved. Never a silent loss. */
#define USERNET_WAIT_R_TRUNCATED (0x1u<<3)
/* Set when the backend has been shut down or was never usable. count == 0 and
 * timeout_ms == 0; the waiter must not sleep. */
#define USERNET_WAIT_R_DEAD (0x1u<<4)

typedef struct UserNetWaitRequest {
    uint32_t struct_size;   /* == sizeof(UserNetWaitRequest) */
    uint32_t abi;           /* == USERNET_WAIT_ABI */
    uint32_t capacity;      /* number of entries `entries` can hold */
    uint32_t flags;         /* USERNET_WAIT_F_* */
    UserNetWaitFd *entries; /* caller-owned array of `capacity` */
    uint64_t reserved[4];   /* must be zero; nonzero => -EINVAL */
} UserNetWaitRequest;

typedef struct UserNetWaitResult {
    uint32_t struct_size;   /* == sizeof(UserNetWaitResult) */
    uint32_t abi;           /* == USERNET_WAIT_ABI */
    uint32_t count;         /* entries written, <= capacity */
    uint32_t wanted;        /* descriptors libslirp asked for in total */
    uint32_t truncated;     /* 1 when wanted > count */
    uint32_t timeout_ms;    /* next network deadline; UINT32_MAX = none */
    uint64_t generation;    /* stable while the fd set and interests match */
    uint32_t flags;         /* USERNET_WAIT_R_* */
    uint32_t reserved32;
    uint64_t reserved[4];
} UserNetWaitResult;

/* Fill `out` and up to req->capacity entries. Returns 0, or -errno
 * (-EINVAL bad argument, -EAGAIN backend busy in a nested fill, -ESHUTDOWN
 * backend already torn down). Never returns a descriptor libslirp does not
 * own. */
int usernet_fill_wait(UserNet *un, const UserNetWaitRequest *req,
                      UserNetWaitResult *out);

/* ---- versioned resolver visibility (v1) ---------------------------------
 *
 * usernet_dns_server() can only express an IPv4 relay target. On an IPv6-only
 * host the reachable resolver is IPv6, so the honest answer for the IPv4 field
 * is 0 while IPv6 DNS is in fact available. This struct reports both, plus
 * whether a DNS64/NAT64 synthesized mapping is in use.
 */
#define USERNET_DNS_ABI 1u

typedef struct UserNetDnsInfo {
    uint32_t struct_size;   /* == sizeof(UserNetDnsInfo) */
    uint32_t abi;           /* == USERNET_DNS_ABI */
    uint32_t v4_valid;      /* an IPv4 relay target is in use */
    uint32_t v4_addr;       /* host-order IPv4, 0 when !v4_valid */
    uint32_t v4_port;       /* network order, 0 when !v4_valid */
    uint32_t v6_valid;      /* an IPv6 relay target is in use */
    uint8_t  v6_addr[16];   /* network order, zero when !v6_valid */
    uint32_t v6_port;       /* network order, 0 when !v6_valid */
    uint32_t v6_scope_id;
    uint32_t nat64_active;  /* a synthesized IPv6 mapping is being used for
                             * IPv4 destinations on this host */
    uint8_t  nat64_prefix[16]; /* informational; never hardcoded, always
                                * discovered through the public resolver */
    uint32_t nat64_prefix_len;
    uint32_t ipv6_guest_enabled; /* guest IPv6 stack is configured on */
    uint64_t reserved[4];
} UserNetDnsInfo;

int usernet_get_dns_info(UserNet *un, UserNetDnsInfo *out);

/* ---- versioned creation configuration (v1) --------------------------------
 *
 * usernet_new() keeps its exact legacy behaviour. usernet_new_with_config()
 * adds the bounded per-VM resource ceilings and the explicit dual-stack /
 * resolver overrides the whole-network scope requires. Passing a NULL config
 * or an unknown abi is -EINVAL, never a silent fallback.
 */
#define USERNET_CFG_ABI 1u

/* Enable the guest IPv6 stack (SLAAC/RA, DHCPv6, NDP, ICMPv6). This internal
 * creation flag is independent of host-side NAT64 for an IPv4-only guest.
 * Integration selects it at the existing NIC constructor; no public Floe C ABI
 * or Swift configuration extension is required. */
#define USERNET_CFG_F_IPV6      0x1u
/* Refuse guest connections to host loopback. Default OFF, preserving the
 * existing behaviour where 10.0.2.2 reaches host loopback services. */
#define USERNET_CFG_F_NO_LOOPBACK 0x2u
/* Restrict the guest: no outbound Internet at all, only the forwarded rules. */
#define USERNET_CFG_F_RESTRICTED 0x4u

/* Defaults chosen to be strictly larger than the previous stack's ceilings
 * (128 TCP + 64 UDP + 8 ICMP + 16 listeners = 216 descriptors) while staying
 * finite and bounded per VM. */
#define USERNET_DEF_MAX_SOCKETS   512u
#define USERNET_DEF_POLL_CAPACITY 512u
#define USERNET_MAX_SOCKETS       4096u
#define USERNET_MAX_POLL_CAPACITY 4096u
/* Hard ceiling on the deferred guest-TX queue, so a guest that stops draining
 * its RX ring can never make the host grow without bound. */
#define USERNET_DEF_TX_QUEUE_FRAMES 64u
#define USERNET_DEF_TX_QUEUE_BYTES  (2u * 1024u * 1024u)

typedef struct UserNetConfig {
    uint32_t struct_size;   /* == sizeof(UserNetConfig) */
    uint32_t abi;           /* == USERNET_CFG_ABI */
    uint32_t flags;         /* USERNET_CFG_F_* */
    uint8_t  guest_mac[6];
    uint16_t if_mtu;        /* 0 => 1500 */
    uint16_t if_mru;        /* 0 => 1500 */
    /* Explicit resolver overrides, deep-copied. NULL asks for host probing.
     * dns_server is a dotted-quad IPv4; dns_server6 is an RFC 5952 IPv6
     * literal, optionally "%scope". A configured override is used verbatim and
     * is never replaced by a fabricated public resolver.
     *
     * dns_server_v4 is the numeric equivalent of dns_server in HOST byte order,
     * kept so the existing virtio-net plumbing (Machine.dns_server, already a
     * host-order uint32 parsed by the bridge) can be forwarded without a
     * pointless int->string->int round trip. When both are given the string
     * wins; when both are absent the host resolver is probed. */
    const char *dns_server;
    const char *dns_server6;
    uint32_t dns_server_v4;
    /* Finite per-VM ceilings. 0 selects the USERNET_DEF_* default. Values
     * above USERNET_MAX_POLL_CAPACITY are clamped with the clamp reported in
     * usernet_get_stats()'s extended counters. */
    uint32_t max_sockets;
    uint32_t poll_capacity;
    uint32_t tx_queue_frames;
    uint32_t tx_queue_bytes;
    uint64_t reserved[4];   /* must be zero; nonzero => NULL return */
} UserNetConfig;

UserNet *usernet_new_with_config(usernet_output_fn output, void *opaque,
                                 const UserNetConfig *cfg);

/* ---- extended, versioned counters (v1) -----------------------------------
 * usernet_get_stats() keeps its legacy five outputs. This reports the bounded
 * resource accounting the whole-network scope needs. All fields are atomically
 * published snapshots and safe to read from any thread. */
#define USERNET_STATS_ABI 1u

typedef struct UserNetExtStats {
    uint32_t struct_size;   /* == sizeof(UserNetExtStats) */
    uint32_t abi;           /* == USERNET_STATS_ABI */
    uint64_t in_frames;         /* guest frames accepted */
    uint64_t in_dropped_short;  /* runt / malformed frames rejected */
    uint64_t in_refused_ceiling;/* refused because the socket ceiling was hit */
    uint64_t out_ok;            /* frames the device RX ring accepted */
    uint64_t out_refused;       /* frames the device RX ring refused */
    uint64_t out_deferred;      /* refused frames queued for a later flush */
    uint64_t out_dropped_queue; /* refused frames dropped, TX queue full */
    uint64_t icmp_errors_sent;  /* ICMP/ICMPv6 errors returned to the guest */
    /* Listener polls withheld by the stock compatibility backpressure path.
     * In the hooks-on shipping profile this stays zero: listeners remain
     * polled and libslirp's admit hook accepts/closes excess clients promptly. */
    uint64_t accept_suppressed;
    uint64_t in_refused_guest;  /* guest-initiated new flows refused */
    uint64_t polls;             /* usernet_poll() calls */
    uint64_t poll_syscalls;     /* actual poll(2) calls made by the driver */
    uint64_t wait_fills;        /* usernet_fill_wait() calls */
    uint64_t wait_truncated;    /* fills that could not represent every fd */
    uint64_t timers_armed;      /* libslirp timers currently armed */
    uint64_t timer_expiries;    /* timer callbacks delivered */
    uint32_t live_sockets;      /* host descriptors currently owned */
    uint32_t max_live_sockets;  /* high-water mark */
    uint32_t socket_ceiling;    /* configured ceiling */
    uint32_t poll_capacity;     /* effective poll capacity */
    uint64_t reserved[4];
} UserNetExtStats;

void usernet_get_ext_stats(UserNet *un, UserNetExtStats *out);

#ifdef FLOE_USERNET_TEST_HOOKS
/* QUALIFICATION ONLY, absent from a shipping build: turn off the adapter-side
 * listener suppression so a test can prove the patched libslirp's own admit hook
 * refuses an inbound accept at the ceiling, independently of this layer. */
void usernet_test_set_listener_suppression(UserNet *un, bool on);
#endif

#ifdef SLIRP_FLOE_HOST_HOOKS
/* Diagnostics that prove the embedder hooks in the patched libslirp
 * (patches/0002-floe-host-hooks.patch) are actually invoked, not merely
 * present. These symbols do not exist in a stock-libslirp build, so a
 * qualification run against the patched library is distinguishable from one
 * against the unpatched library by link success alone. Any pointer may be
 * NULL. */
#define USERNET_HOOK_ABI 1u
void usernet_get_hook_stats(UserNet *un, uint64_t *admit_refused,
                            uint64_t *nat64_mapped, uint64_t *dns_used);
#endif

#endif
