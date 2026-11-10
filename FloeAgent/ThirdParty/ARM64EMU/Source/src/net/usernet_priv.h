/* SPDX-License-Identifier: Apache-2.0 */
/* Copyright 2026 Sylirre */
/* Modified by Floe contributors, 2026-11-10: mature network backend,
 * bounded event integration and virtual-NIC scheduling/offloads. */
/* usernet internals: the libslirp 4.9.7 adapter state shared between
 * usernet_core.c (lifecycle / API / input), usernet_poll.c (fill-dispatch
 * pairing, deferred TX, timers, bounded ceilings) and usernet_host.c (Apple
 * resolver discovery and DNS64/NAT64 mapping).
 *
 * All addresses and ports are HOST byte order in this header's own fields;
 * libslirp's own structures keep network order and are only touched through
 * its public API. */
#ifndef USERNET_PRIV_H
#define USERNET_PRIV_H

#include "usernet.h"
#include "usernet_host.h"

#include <errno.h>
#include <netinet/in.h>
#include <poll.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#include <slirp/libslirp.h>
#ifdef SLIRP_FLOE_HOST_HOOKS
/* Present only when libslirp was built with this lane's
 * patches/0002-floe-host-hooks.patch. Without it the adapter compiles and runs
 * against stock libslirp and the hook code below does not exist. */
#include <slirp/floe_host_net.h>
#endif

/* ---- fixed topology (host byte order), unchanged from the previous stack ---- */
#define UN_IP(a,b,c,d) (((uint32_t)(a) << 24) | ((uint32_t)(b) << 16) | \
                        ((uint32_t)(c) << 8) | (uint32_t)(d))
#define UN_IP_HOST   UN_IP(10,0,2,2)     /* gateway; also reaches host loopback */
#define UN_IP_DNS    UN_IP(10,0,2,3)     /* virtual DNS, relayed to the real one */
#define UN_IP_GUEST  UN_IP(10,0,2,15)
#define UN_NET       UN_IP(10,0,2,0)
#define UN_NETMASK   0xffffff00u

#define UN_MTU_DEFAULT 1500
#define UN_MAX_FRAME   (14 + UN_MTU_DEFAULT)

#define UN_ETH_IP    0x0800
#define UN_ETH_IPV6  0x86dd
#define UN_ETH_ARP   0x0806
#define UN_IPP_ICMP  1
#define UN_IPP_TCP   6
#define UN_IPP_UDP   17

/* Guest IPv6 prefix handed out by libslirp's RA when USERNET_CFG_F_IPV6 is
 * set. fd00::/64 is a locally assigned unique-local prefix: it is not a
 * routable claim and it is exactly what upstream libslirp defaults to. */
#define UN_FWD_MAX   16      /* matches FLOE_AE_MAX_NET_FORWARDS */

/* libslirp's own granularity. TIMEOUT_FAST is what the deferred-TX retry and
 * a truncated wait set clamp to, so a pending frame is retried at the same
 * cadence libslirp uses for a delayed ACK rather than spinning. */
#define UN_TIMEOUT_FAST_MS   2u
#define UN_TIMEOUT_SLOW_MS   499u
#define UN_TIMEOUT_IDLE_MS   1000u

/* ---- one host-forward rule (bounded registry owned by this adapter) ----
 * libslirp keeps its own rule list, but it has no capacity limit and reports a
 * bare -1 on failure. This registry preserves the previous stack's exact
 * contract: a 16-rule ceiling reported as -ENOBUFS (which the bridge maps to
 * FLOE_AE_UNSUPPORTED), a duplicate reported as -EADDRINUSE, and a missing
 * rule reported as -ENOENT. */
typedef struct UnHostFwd {
    bool     in_use;
    bool     is_udp;
    uint16_t host_port, guest_port;
} UnHostFwd;

/* ---- deferred guest-TX frame (bounded FIFO) ---- */
typedef struct UnTxFrame {
    uint8_t *buf;
    uint32_t len;
} UnTxFrame;

/* ---- one libslirp timer ---- */
typedef struct UnTimer {
    bool          in_use;
    bool          armed;
    int64_t       expire_ms;      /* absolute, un_now_ms() clock */
    SlirpTimerCb  cb;
    void         *cb_opaque;
} UnTimer;

#define UN_TIMER_MAX 8            /* upstream 4.9.7 uses exactly one (RA) */

/* ---- bounded UDP flow table, for the per-VM ceiling only ----
 * libslirp reuses one host datagram socket per guest 4-tuple and expires it
 * on its own idle timer, but it has no global count limit. This table lets
 * usernet_input() refuse a NEW UDP flow once the ceiling is reached, which is
 * the honest bound the whole-network scope requires. It never alters the data
 * path: an existing tuple always passes. */
typedef struct UnUdpFlowKey {
    uint32_t src_ip, dst_ip;
    uint16_t src_port, dst_port;
    uint8_t  family;              /* 4 or 6 */
    uint8_t  src_ip6[16], dst_ip6[16];
} UnUdpFlowKey;

typedef struct UnUdpFlow {
    bool          in_use;
    UnUdpFlowKey  key;
    int64_t       last_ms;
} UnUdpFlow;

#define UN_UDP_FLOW_TTL_MS 60000

/* ---- host descriptor type cache ----
 * Built from the descriptors libslirp asks us to poll, so the legacy
 * tcp_conns/udp_flows counters stay exact without walking libslirp's private
 * socket lists from an arbitrary thread. One getsockopt(SO_TYPE) per newly
 * seen descriptor; entries are swept when a fill no longer mentions them. */
typedef struct UnFdType {
    bool in_use;
    bool seen;
    int  fd;
    int  sock_type;               /* SOCK_STREAM / SOCK_DGRAM / SOCK_RAW */
    bool type_known;
    bool is_listener;             /* one of our forwarding listeners */
    bool listener_known;
} UnFdType;

/* The registry is the authoritative live-descriptor set. It is sized from the
 * configured ceiling and kept at a load factor of at most 1/2 so a probe never
 * degenerates; occupancy above the ceiling is recorded separately rather than
 * silently lost, so the gate can never under-count. */
#define UN_FDREG_MIN_SLOTS 64

struct UserNet {
    /* ---- immutable after create ---- */
    usernet_output_fn output;
    void   *opaque;
    uint8_t guest_mac[6];
    uint32_t flags;               /* USERNET_CFG_F_* */
    uint32_t dns_cfg4;            /* host-order IPv4 override, or 0 */
    char    *dns_cfg6;            /* strdup'd IPv6 override, or NULL */
    uint32_t if_mtu, if_mru;
    uint32_t socket_ceiling;
    uint32_t poll_capacity;
    /* The patched libslirp admit hook is authoritative at every allocation /
     * accept boundary. In that shipping profile listeners remain polled so an
     * excess client is accepted and closed immediately. The listener-withholding
     * fallback exists only for the separately qualified stock compatibility
     * profile; the test hook can explicitly toggle it for isolation tests. */
    bool listener_suppression;

    /* ---- libslirp instance ---- */
    Slirp   *slirp;
    bool     dead;                /* torn down or never usable */
    bool     init_completed;

    /* ---- deferred guest TX (bounded FIFO, coordinator thread only) ---- */
    UnTxFrame *txq;
    uint32_t   txq_cap;           /* frame slots */
    uint32_t   txq_head, txq_count;
    uint32_t   txq_bytes, txq_bytes_cap;

    /* ---- poll fill / dispatch pairing (coordinator thread only) ---- */
    struct pollfd *pfds;
    uint32_t       pfds_cap;
    uint32_t       npfds;         /* entries actually filled */
    uint32_t       wanted;        /* descriptors libslirp asked for */
    uint32_t       timeout_ms;    /* libslirp's requested max sleep */
    uint64_t       generation;
    uint64_t       gen_hash;
    bool           dispatch_pending;
    bool           notify_pending;

    /* ---- timers ---- */
    UnTimer timers[UN_TIMER_MAX];
    uint32_t timer_count;

    /* ---- live host descriptor registry (authoritative for the ceiling) ----
     * Populated by libslirp's register_poll_socket, pruned by
     * unregister_poll_socket AND reconciled at every fill against fcntl(), so a
     * descriptor libslirp closes on a path that does not unregister cannot make
     * the count drift upward and permanently wedge the backend. */
    UnFdType *fdreg;
    uint32_t  fdreg_slots;      /* power of two */
    uint32_t  fdreg_count;      /* == live_sockets */
    uint32_t  fdreg_overflow;   /* registrations the table could not hold */

    /* ---- bounded UDP flow table ---- */
    UnUdpFlow *udp_flows;
    uint32_t   udp_flow_cap;
    uint32_t   udp_flow_count;
    int64_t    udp_sweep_ms;

    /* ---- host forwarding rules (bounded registry, ours) ---- */
    UnHostFwd fwd[UN_FWD_MAX];
    uint32_t n_fwd;

    /* ---- per-instance DNS64/NAT64 mapping cache (coordinator thread) ---- */
    UnNat64Cache nat64;

    /* ---- resolver discovery snapshot (published atomically) ----
     * revision is odd while the coordinator refreshes the snapshot and even
     * when stable. Byte arrays are atomic too, so the arbitrary-thread getter
     * can retry a changed revision without a C data race or a torn address. */
    struct {
        _Atomic uint32_t revision;
        _Atomic uint32_t v4_valid;
        _Atomic uint32_t v4_addr;      /* host order */
        _Atomic uint32_t v4_port;      /* network order */
        _Atomic uint32_t v6_valid;
        _Atomic uint32_t v6_port;
        _Atomic uint32_t v6_scope;
        _Atomic uint32_t nat64_active;
        _Atomic uint32_t probed_ok;
        _Atomic uint8_t v6_addr[16];
        _Atomic uint8_t nat64_prefix[16];
        _Atomic uint32_t nat64_prefix_len;
        int64_t  probe_ms;
    } dns;

    /* ---- live counters ----
     * st_* are written only on the coordinator thread and published through
     * the _Atomic mirrors so usernet_get_stats() stays thread-safe without
     * ever touching libslirp state. */
    uint64_t in_frames, in_dropped_short, in_refused_ceiling;
    uint64_t out_ok, out_refused, out_deferred, out_dropped_queue;
    uint64_t icmp_errors_sent, polls, poll_syscalls;
    uint64_t wait_fills, wait_truncated, timer_expiries;
    uint64_t accept_suppressed;   /* listener polls withheld at the ceiling */
    uint64_t in_refused_guest;    /* guest-initiated new flows refused      */
    uint32_t live_sockets, max_live_sockets;
    uint32_t last_tcp_conns, last_udp_flows;

    _Atomic uint64_t pub_in_frames, pub_out_ok, pub_out_refused;
    _Atomic uint32_t pub_tcp_conns, pub_udp_flows;
    _Atomic uint32_t pub_dns_v4;

#ifdef SLIRP_FLOE_HOST_HOOKS
    /* Hook table storage. It must outlive the Slirp instance, and it does:
     * usernet_destroy() calls slirp_cleanup() before this struct is freed. */
    FloeSlirpHooks floe_hooks;
    uint64_t hook_admit_refused;
    uint64_t hook_nat64_mapped;
    uint64_t hook_dns_used;
#endif
};

/* ---- small shared helpers ---- */
int64_t un_now_ms(void);

/* usernet_poll.c */
void un_tx_init(struct UserNet *un, uint32_t frames, uint32_t bytes);
void un_tx_free(struct UserNet *un);
bool un_tx_defer(struct UserNet *un, const uint8_t *frame, size_t len);
void un_tx_flush(struct UserNet *un);
void un_timers_init(struct UserNet *un);
void un_timers_free(struct UserNet *un);
void un_timers_run(struct UserNet *un);
uint32_t un_timers_armed(const struct UserNet *un);
int64_t un_timers_deadline_ms(const struct UserNet *un);
void un_fdreg_init(struct UserNet *un);
void un_fdreg_free(struct UserNet *un);
void un_fdreg_reset(struct UserNet *un);
void un_fdreg_add(struct UserNet *un, int fd);
void un_fdreg_del(struct UserNet *un, int fd);
void un_publish_stats(struct UserNet *un);
/* Fill un->pfds (internal) or a caller array (wait ABI). Exactly one of
 * `req`/`out` is non-NULL. Returns 0 or -errno. */
int  un_fill(struct UserNet *un, const UserNetWaitRequest *req,
             UserNetWaitResult *out, bool dup_fds);
void un_dispatch(struct UserNet *un, int poll_error);
/* Ceiling gate for usernet_input(): true when the frame may proceed. */
bool un_admit_input(struct UserNet *un, const uint8_t *frame, size_t len);
/* Classify one Ethernet frame down to its upper-layer protocol, walking IPv6
 * extension-header chains and refusing to guess for non-first fragments.
 * Returns false when the frame cannot be classified. */
typedef struct UnL4Info {
    unsigned family;              /* 4 or 6                    */
    unsigned proto;               /* 6 TCP, 17 UDP, 1 ICMPv4, 58 ICMPv6 */
    uint32_t src_ip, dst_ip;      /* host order, family 4 only */
    uint16_t src_port, dst_port;  /* 0 when not a TCP/UDP header */
    uint16_t l4len;
    bool     first_fragment;      /* false => L4 header not present */
    bool     is_new_tcp_conn;     /* SYN without ACK             */
    bool     is_echo_request;     /* ICMPv4 type 8 / ICMPv6 128  */
} UnL4Info;
bool un_classify_l4(const uint8_t *frame, size_t len, UnL4Info *out);
/* True when `fd` is one of this backend's forwarding listeners. Cached. */
bool un_fd_is_listener(struct UserNet *un, int fd);
void un_send_ceiling_icmp(struct UserNet *un, const uint8_t *frame, size_t len);
void un_udp_flow_touch(struct UserNet *un, const uint8_t *frame, size_t len);
void un_udp_flow_forget_all(struct UserNet *un);
void un_udp_flows_free(struct UserNet *un);

/* usernet_host.c */
void un_host_dns_probe(struct UserNet *un);
void un_host_install_hooks(struct UserNet *un);
uint32_t un_host_dns4(const struct UserNet *un);

/* libslirp callback table (defined in usernet_core.c) */
extern const SlirpCb un_slirp_cb;

/* ---- wire parsing helpers, host byte order ---- */
static inline uint16_t un_rd16(const uint8_t *p) {
    return (uint16_t)((p[0] << 8) | p[1]);
}
static inline uint32_t un_rd32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] << 8) | p[3];
}
static inline void un_wr16(uint8_t *p, uint16_t v) {
    p[0] = (uint8_t)(v >> 8); p[1] = (uint8_t)v;
}
static inline void un_wr32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)(v >> 24); p[1] = (uint8_t)(v >> 16);
    p[2] = (uint8_t)(v >> 8);  p[3] = (uint8_t)v;
}
static inline uint32_t un_cksum_add(uint32_t sum, const uint8_t *p, size_t n) {
    while (n > 1) { sum += (uint32_t)((p[0] << 8) | p[1]); p += 2; n -= 2; }
    if (n) sum += (uint32_t)(p[0] << 8);
    return sum;
}
static inline uint16_t un_cksum_fin(uint32_t sum) {
    while (sum >> 16) sum = (sum & 0xffff) + (sum >> 16);
    return (uint16_t)(~sum & 0xffff);
}

#endif
