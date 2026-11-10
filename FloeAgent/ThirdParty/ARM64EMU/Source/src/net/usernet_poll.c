/* SPDX-License-Identifier: Apache-2.0 */
/* Copyright 2026 Floe contributors */
/* usernet poll driver: the fill/dispatch pairing around libslirp's public
 * poll API, the bounded deferred guest-TX queue, the adapter-owned timers,
 * the descriptor type cache that backs the legacy counters, and the bounded
 * per-VM admission gate.
 *
 * Two invariants make this safe with the existing engine:
 *
 *  1. Every function in this file runs on the single machine coordinator
 *     thread. Guest MMIO to virtio-net reaches usernet_input() only through
 *     the RPC_BUS mailbox serviced by the coordinator
 *     (Bridge/parallel_runtime.c machine_bus_service), and usernet_poll()
 *     only runs from machine_tick. Hostfwd add/remove and destroy require the
 *     same quiescence the two wait sites already establish.
 *
 *  2. A fill is always superseded by the next fill before any dispatch.
 *     libslirp stores the index returned by our add_poll callback in
 *     so->pollfds_idx; slirp_pollfds_poll() then asks get_revents() for that
 *     index. We therefore never dispatch against a snapshot we did not just
 *     build, and a wait-site fill that is never dispatched cannot corrupt
 *     anything.
 */
#include "usernet_priv.h"
#include "usernet_host.h"

#include <fcntl.h>
#include <stdarg.h>

/* ---- event translation --------------------------------------------------- */

static int slirp_to_poll(int ev) {
    int r = 0;
    if (ev & SLIRP_POLL_IN)  r |= POLLIN;
    if (ev & SLIRP_POLL_OUT) r |= POLLOUT;
    if (ev & SLIRP_POLL_PRI) r |= POLLPRI;
    if (ev & SLIRP_POLL_ERR) r |= POLLERR;
    if (ev & SLIRP_POLL_HUP) r |= POLLHUP;
    return r;
}

static int poll_to_slirp(int ev) {
    int r = 0;
    if (ev & POLLIN)   r |= SLIRP_POLL_IN;
    if (ev & POLLOUT)  r |= SLIRP_POLL_OUT;
    if (ev & POLLPRI)  r |= SLIRP_POLL_PRI;
    if (ev & POLLERR)  r |= SLIRP_POLL_ERR;
    if (ev & POLLHUP)  r |= SLIRP_POLL_HUP;
    /* POLLNVAL means the descriptor is not open at all. Reporting it as an
     * error lets libslirp tear the socket down instead of spinning on it. */
    if (ev & POLLNVAL) r |= SLIRP_POLL_ERR;
    return r;
}

/* ---- bounded deferred guest-TX queue ------------------------------------ */

void un_tx_init(struct UserNet *un, uint32_t frames, uint32_t bytes) {
    if (!frames) frames = USERNET_DEF_TX_QUEUE_FRAMES;
    if (!bytes) bytes = USERNET_DEF_TX_QUEUE_BYTES;
    un->txq_cap = frames;
    un->txq_bytes_cap = bytes;
    un->txq = calloc(frames, sizeof(*un->txq));
    un->txq_head = un->txq_count = un->txq_bytes = 0;
}

void un_tx_free(struct UserNet *un) {
    if (!un->txq) return;
    for (uint32_t i = 0; i < un->txq_cap; i++) {
        free(un->txq[i].buf);
        un->txq[i].buf = NULL;
        un->txq[i].len = 0;
    }
    free(un->txq);
    un->txq = NULL;
    un->txq_cap = 0;
    un->txq_head = un->txq_count = un->txq_bytes = 0;
}

static void un_tx_drop_oldest(struct UserNet *un) {
    if (!un->txq_count) return;
    uint32_t i = un->txq_head;
    un->txq_bytes -= un->txq[i].len;
    free(un->txq[i].buf);
    un->txq[i].buf = NULL;
    un->txq[i].len = 0;
    un->txq_head = (un->txq_head + 1) % un->txq_cap;
    un->txq_count--;
    un->out_dropped_queue++;
}

bool un_tx_defer(struct UserNet *un, const uint8_t *frame, size_t len) {
    if (!un->txq || !un->txq_cap || !frame || !len) return false;
    if (len > (size_t)UN_MAX_FRAME) return false;   /* oversized: never queue */

    /* Fair backpressure: the queue is finite in BOTH frames and bytes, and
     * when it is full the oldest frame is dropped rather than refusing the
     * newest one. TCP recovers from any drop through libslirp's own
     * retransmission (unacknowledged bytes stay in so_snd), so dropping the
     * oldest is the choice that keeps the newest data freshest. */
    while (un->txq_count >= un->txq_cap ||
           un->txq_bytes + (uint32_t)len > un->txq_bytes_cap) {
        if (!un->txq_count) return false;           /* single frame too big */
        un_tx_drop_oldest(un);
    }
    uint8_t *copy = malloc(len);
    if (!copy) return false;
    memcpy(copy, frame, len);
    uint32_t tail = (un->txq_head + un->txq_count) % un->txq_cap;
    un->txq[tail].buf = copy;
    un->txq[tail].len = (uint32_t)len;
    un->txq_count++;
    un->txq_bytes += (uint32_t)len;
    return true;
}

void un_tx_flush(struct UserNet *un) {
    if (!un || un->dead || !un->output || !un->txq) return;
    /* Bounded per call so one flush can never monopolise the tick. Anything
     * left behind keeps USERNET_WAIT_R_TX_PENDING set, which clamps the next
     * wait to TIMEOUT_FAST rather than spinning here. */
    uint32_t budget = un->txq_count;
    if (budget > 32) budget = 32;
    while (budget-- && un->txq_count) {
        uint32_t i = un->txq_head;
        uint8_t *buf = un->txq[i].buf;
        uint32_t len = un->txq[i].len;
        if (!un->output(un->opaque, buf, len)) {
            un->out_refused++;      /* still full: leave it queued */
            return;
        }
        un->txq_bytes -= len;
        free(buf);
        un->txq[i].buf = NULL;
        un->txq[i].len = 0;
        un->txq_head = (un->txq_head + 1) % un->txq_cap;
        un->txq_count--;
        un->out_ok++;
    }
}

/* ---- timers ------------------------------------------------------------- */

void un_timers_init(struct UserNet *un) {
    memset(un->timers, 0, sizeof(un->timers));
    un->timer_count = 0;
}

void un_timers_free(struct UserNet *un) {
    un_timers_init(un);
}

uint32_t un_timers_armed(const struct UserNet *un) {
    uint32_t n = 0;
    for (uint32_t i = 0; i < un->timer_count; i++)
        if (un->timers[i].in_use && un->timers[i].armed) n++;
    return n;
}

int64_t un_timers_deadline_ms(const struct UserNet *un) {
    int64_t best = -1;
    int64_t now = un_now_ms();
    for (uint32_t i = 0; i < un->timer_count; i++) {
        const UnTimer *t = &un->timers[i];
        if (!t->in_use || !t->armed || !t->cb) continue;
        int64_t remain = t->expire_ms - now;
        if (remain < 0) remain = 0;
        if (best < 0 || remain < best) best = remain;
    }
    return best;
}

void un_timers_run(struct UserNet *un) {
    if (!un || un->dead) return;
    int64_t now = un_now_ms();
    /* Fire at most a bounded number per call: libslirp's only timer today is
     * the IPv6 RA, which re-arms itself, so a runaway loop is impossible, but
     * the bound keeps the tick latency predictable regardless. */
    for (uint32_t pass = 0; pass < 4; pass++) {
        bool fired = false;
        now = un_now_ms();
        for (uint32_t i = 0; i < un->timer_count; i++) {
            UnTimer *t = &un->timers[i];
            if (!t->in_use || !t->armed || !t->cb) continue;
            if (t->expire_ms > now) continue;
            t->armed = false;
            SlirpTimerCb cb = t->cb;
            void *cb_opaque = t->cb_opaque;
            cb(cb_opaque);
            un->timer_expiries++;
            fired = true;
            /* The callback may have freed or re-armed this slot; rescan. */
            break;
        }
        if (!fired) break;
    }
}

/* ---- live host descriptor registry ---------------------------------------
 *
 * This is the authoritative per-VM descriptor set. libslirp announces every
 * host socket it creates through register_poll_socket and most of its close
 * paths through unregister_poll_socket — but sofree() does NOT unregister, so a
 * register/unregister delta alone can only drift upward and would eventually
 * wedge the backend at its ceiling forever. The registry is therefore
 * reconciled on every fill: any entry libslirp did not ask us to poll is
 * checked with fcntl(F_GETFD) and dropped when the descriptor is gone. A reused
 * number stays valid and simply represents the new socket, so the count can
 * never be wrong by more than the instant between a close and the next fill.
 */

static uint32_t un_pow2_at_least(uint32_t n) {
    uint32_t p = UN_FDREG_MIN_SLOTS;
    while (p < n && p < (1u << 20)) p <<= 1;
    return p;
}

void un_fdreg_init(struct UserNet *un) {
    un_fdreg_free(un);
    /* Load factor <= 1/2 at the ceiling, with room for the transient sockets
     * libslirp holds between a close and the next reconciliation. */
    un->fdreg_slots = un_pow2_at_least(un->socket_ceiling * 2 + 16);
    un->fdreg = calloc(un->fdreg_slots, sizeof(*un->fdreg));
    un->fdreg_count = 0;
    un->fdreg_overflow = 0;
    if (!un->fdreg) un->fdreg_slots = 0;
}

void un_fdreg_free(struct UserNet *un) {
    free(un->fdreg);
    un->fdreg = NULL;
    un->fdreg_slots = 0;
    un->fdreg_count = 0;
}

void un_fdreg_reset(struct UserNet *un) {
    if (un->fdreg) memset(un->fdreg, 0, un->fdreg_slots * sizeof(*un->fdreg));
    un->fdreg_count = 0;
    un->fdreg_overflow = 0;
}

static UnFdType *un_fdreg_find(struct UserNet *un, int fd, bool insert) {
    if (!un->fdreg || !un->fdreg_slots) return NULL;
    uint32_t mask = un->fdreg_slots - 1;
    uint32_t h = ((uint32_t)fd * 2654435761u) & mask;
    UnFdType *spare = NULL;
    for (uint32_t probe = 0; probe < un->fdreg_slots; probe++) {
        UnFdType *e = &un->fdreg[(h + probe) & mask];
        if (!e->in_use) { if (!spare) spare = e; continue; }
        if (e->fd == fd) return e;
    }
    if (!insert || !spare) return NULL;
    /* Never exceed a half load factor: report the overflow instead of
     * degrading the probe, and let the caller treat the ceiling as reached. */
    if (un->fdreg_count * 2 >= un->fdreg_slots) {
        un->fdreg_overflow++;
        return NULL;
    }
    spare->in_use = true;
    spare->seen = false;
    spare->fd = fd;
    spare->sock_type = 0;
    spare->type_known = false;
    spare->is_listener = false;
    spare->listener_known = false;
    un->fdreg_count++;
    un->live_sockets = un->fdreg_count;
    if (un->live_sockets > un->max_live_sockets)
        un->max_live_sockets = un->live_sockets;
    return spare;
}

void un_fdreg_add(struct UserNet *un, int fd) {
    if (fd < 0) return;
    un_fdreg_find(un, fd, true);
}

void un_fdreg_del(struct UserNet *un, int fd) {
    if (fd < 0) return;
    UnFdType *e = un_fdreg_find(un, fd, false);
    if (!e) return;
    e->in_use = false;
    e->type_known = false;
    e->listener_known = false;
    if (un->fdreg_count) un->fdreg_count--;
    un->live_sockets = un->fdreg_count;
}

/* One getsockopt per newly seen descriptor, then cached for the life of the
 * descriptor (invalidated by unregister_poll_socket or reconciliation). */
static int un_fdtype_of(struct UserNet *un, int fd) {
    UnFdType *e = un_fdreg_find(un, fd, true);
    if (!e) return 0;
    e->seen = true;
    if (e->type_known) return e->sock_type;
    int type = 0;
    socklen_t tl = sizeof(type);
    if (getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &tl) != 0) type = 0;
    e->sock_type = type;
    e->type_known = true;
    return type;
}

/* Identify one of our own forwarding listeners.
 *
 * A forwarded listener is bound to 127.0.0.1:<host_port> for a rule in our
 * registry. An accepted TCP connection shares that local port, so the port
 * alone is not enough for TCP: a listener is not connected, while an accepted
 * socket has a peer. For UDP, libslirp's forwarded socket is bound to the rule
 * port whereas an outbound flow socket uses an ephemeral port, so the port
 * match is decisive there. Both tests use only public socket APIs and the
 * answer is cached for the life of the descriptor. */
bool un_fd_is_listener(struct UserNet *un, int fd) {
    UnFdType *e = un_fdreg_find(un, fd, true);
    if (e) e->seen = true;
    if (e && e->listener_known) return e->is_listener;

    bool result = false;
    int type = un_fdtype_of(un, fd);
    if (type == SOCK_STREAM || type == SOCK_DGRAM) {
        struct sockaddr_storage ss;
        socklen_t sl = sizeof(ss);
        if (getsockname(fd, (struct sockaddr *)&ss, &sl) == 0) {
            unsigned port = 0;
            if (ss.ss_family == AF_INET)
                port = ntohs(((struct sockaddr_in *)&ss)->sin_port);
            else if (ss.ss_family == AF_INET6)
                port = ntohs(((struct sockaddr_in6 *)&ss)->sin6_port);
            if (port) {
                bool want_udp = (type == SOCK_DGRAM);
                for (uint32_t i = 0; i < UN_FWD_MAX; i++) {
                    if (!un->fwd[i].in_use) continue;
                    if (un->fwd[i].is_udp != want_udp) continue;
                    if (un->fwd[i].host_port != (uint16_t)port) continue;
                    if (want_udp) { result = true; break; }
                    /* TCP: a listener has no peer; an accepted socket does. */
                    struct sockaddr_storage peer;
                    socklen_t pl = sizeof(peer);
                    if (getpeername(fd, (struct sockaddr *)&peer, &pl) != 0)
                        result = true;
                    break;
                }
            }
        }
    }
    if (e) { e->is_listener = result; e->listener_known = true; }
    return result;
}

/* Reconcile and recount. Entries libslirp did not ask us to poll this fill are
 * kept only while their descriptor is genuinely still open; this is what stops
 * the ceiling from being consumed forever by descriptors libslirp closed on a
 * path that does not call unregister_poll_socket (sofree() is such a path). */
static void un_fdreg_sweep_and_count(struct UserNet *un) {
    unsigned tcp = 0, udp = 0;
    for (uint32_t i = 0; i < un->fdreg_slots; i++) {
        UnFdType *e = &un->fdreg[i];
        if (!e->in_use) continue;
        if (!e->seen) {
            if (fcntl(e->fd, F_GETFD) < 0) {
                e->in_use = false;
                e->type_known = false;
                e->listener_known = false;
                if (un->fdreg_count) un->fdreg_count--;
                continue;
            }
        }
        e->seen = false;
        if (e->type_known && e->sock_type == SOCK_STREAM) tcp++;
        else if (e->type_known && e->sock_type == SOCK_DGRAM) udp++;
    }
    un->live_sockets = un->fdreg_count;
    un->last_tcp_conns = tcp;
    un->last_udp_flows = udp;
}

/* ---- bounded UDP flow table ---------------------------------------------
 *
 * libslirp keeps one host datagram socket per guest 4-tuple and expires it on
 * its own idle timer (SO_EXPIRE 240 s, SO_EXPIREFAST 10 s for port 53), but it
 * has no global limit. This table lets usernet_input() refuse only a NEW UDP
 * flow once the descriptor ceiling is reached. The TTLs are chosen just under
 * libslirp's own so a tuple we still hold can never be mistaken for new while
 * libslirp still owns a socket for it. */
#define UN_UDP_TTL_MS     235000
#define UN_UDP_DNS_TTL_MS  10000

void un_udp_flows_free(struct UserNet *un) {
    free(un->udp_flows);
    un->udp_flows = NULL;
    un->udp_flow_cap = 0;
    un->udp_flow_count = 0;
}

void un_udp_flow_forget_all(struct UserNet *un) {
    if (!un->udp_flows) return;
    memset(un->udp_flows, 0, un->udp_flow_cap * sizeof(*un->udp_flows));
    un->udp_flow_count = 0;
}

static uint32_t un_udp_hash(const UnUdpFlowKey *k) {
    uint32_t h = 2166136261u;
    const uint8_t *p = (const uint8_t *)k;
    for (size_t i = 0; i < sizeof(*k); i++) { h ^= p[i]; h *= 16777619u; }
    return h;
}

static bool un_udp_key_equal(const UnUdpFlowKey *a, const UnUdpFlowKey *b) {
    return memcmp(a, b, sizeof(*a)) == 0;
}

static UnUdpFlow *un_udp_find(struct UserNet *un, const UnUdpFlowKey *k,
                              bool insert) {
    if (!un->udp_flows || !un->udp_flow_cap) return NULL;
    uint32_t mask = un->udp_flow_cap - 1;
    /* Capacity is rounded to a power of two at allocation. */
    uint32_t h = un_udp_hash(k) & mask;
    UnUdpFlow *spare = NULL;
    for (uint32_t probe = 0; probe < un->udp_flow_cap; probe++) {
        UnUdpFlow *e = &un->udp_flows[(h + probe) & mask];
        if (!e->in_use) { if (!spare) spare = e; continue; }
        if (un_udp_key_equal(&e->key, k)) return e;
    }
    if (!insert) return NULL;
    return spare;
}

static void un_udp_sweep(struct UserNet *un, int64_t now) {
    if (now - un->udp_sweep_ms < 1000) return;
    un->udp_sweep_ms = now;
    for (uint32_t i = 0; i < un->udp_flow_cap; i++) {
        UnUdpFlow *e = &un->udp_flows[i];
        if (!e->in_use) continue;
        int64_t ttl = (e->key.src_port == 53 || e->key.dst_port == 53)
                          ? UN_UDP_DNS_TTL_MS : UN_UDP_TTL_MS;
        if (now - e->last_ms > ttl) {
            e->in_use = false;
            if (un->udp_flow_count) un->udp_flow_count--;
        }
    }
}

/* ---- upper-layer classification ------------------------------------------
 *
 * Both the ceiling gate and the UDP flow table need to know what a frame
 * actually carries. Reading a fixed IPv6 next-header byte is not enough: an
 * extension-header chain (Hop-by-Hop 0, Routing 43, Fragment 44, Destination
 * 60, AH 51, Mobility 135, HIP 139, Shim6 140) hides the upper layer, and a
 * non-first fragment does not contain an L4 header at all. ICMPv6 is protocol
 * 58, NOT the ICMPv4 value 1, so the two must never be conflated. Anything
 * this function cannot classify is reported as such rather than guessed. */
#define UN_IPV6_EXT_MAX 8

bool un_classify_l4(const uint8_t *frame, size_t len, UnL4Info *out) {
    memset(out, 0, sizeof(*out));
    if (!frame || len < 14) return false;
    uint16_t eth = un_rd16(frame + 12);
    const uint8_t *ip = frame + 14;
    size_t avail = len - 14;
    size_t ihl;
    unsigned proto;

    if (eth == UN_ETH_IP) {
        if (avail < 20 || (ip[0] >> 4) != 4) return false;
        ihl = (size_t)(ip[0] & 0xf) * 4;
        if (ihl < 20 || avail < ihl) return false;
        uint16_t tot = un_rd16(ip + 2);
        if (tot < ihl || tot > avail) tot = (uint16_t)avail;
        out->family = 4;
        out->src_ip = un_rd32(ip + 12);
        out->dst_ip = un_rd32(ip + 16);
        proto = ip[9];
        /* A non-first IPv4 fragment carries no L4 header. */
        out->first_fragment = (un_rd16(ip + 6) & 0x1fff) == 0;
        avail = tot - ihl;
        ip += ihl;
    } else if (eth == UN_ETH_IPV6) {
        if (avail < 40 || (ip[0] >> 4) != 6) return false;
        out->family = 6;
        uint16_t payload = un_rd16(ip + 4);
        proto = ip[6];
        const uint8_t *cur = ip + 40;
        size_t cur_avail = (payload + 40 <= avail) ? payload : (avail - 40);
        out->first_fragment = true;
        /* Walk the extension-header chain, bounded so a hostile guest cannot
         * make this loop long. */
        for (int hops = 0; hops < UN_IPV6_EXT_MAX; hops++) {
            size_t ext_len;
            switch (proto) {
            case 0: case 43: case 60: case 51: case 135: case 139: case 140:
                if (cur_avail < 8) return false;
                ext_len = ((size_t)cur[1] + 1) * 8;
                break;
            case 44:                       /* Fragment */
                if (cur_avail < 8) return false;
                /* Offset is the top 13 bits of the 16-bit field at +2. */
                out->first_fragment = (un_rd16(cur + 2) & 0xfff8) == 0;
                ext_len = 8;
                break;
            default:
                goto upper;
            }
            if (ext_len > cur_avail) return false;
            {
                unsigned next = cur[0];
                cur += ext_len;
                cur_avail -= ext_len;
                proto = next;
            }
        }
        return false;                       /* chain too long: refuse to guess */
    upper:
        ip = cur;
        avail = cur_avail;
    } else {
        return false;                       /* ARP and anything else: not L3 */
    }

    out->proto = proto;
    out->l4len = (uint16_t)(avail > 0xffff ? 0xffff : avail);

    if (!out->first_fragment) return true;  /* classified, but no L4 header */

    if (proto == 6 && avail >= 14) {        /* TCP */
        out->src_port = un_rd16(ip);
        out->dst_port = un_rd16(ip + 2);
        uint8_t flags = ip[13];
        out->is_new_tcp_conn = (flags & 0x02) && !(flags & 0x10);
    } else if (proto == 17 && avail >= 8) { /* UDP */
        out->src_port = un_rd16(ip);
        out->dst_port = un_rd16(ip + 2);
    } else if (proto == 1 && avail >= 8 && out->family == 4) {
        out->is_echo_request = (ip[0] == 8 && ip[1] == 0);
    } else if (proto == 58 && avail >= 8 && out->family == 6) {
        out->is_echo_request = (ip[0] == 128 && ip[1] == 0);
    }
    return true;
}

static bool un_parse_udp(const uint8_t *frame, size_t len, UnUdpFlowKey *k) {
    UnL4Info info;
    memset(k, 0, sizeof(*k));
    if (!un_classify_l4(frame, len, &info)) return false;
    if (info.proto != 17 || !info.first_fragment) return false;
    k->family = (uint8_t)info.family;
    if (info.family == 4) {
        k->src_ip = info.src_ip;
        k->dst_ip = info.dst_ip;
    } else {
        const uint8_t *ip6 = frame + 14;
        memcpy(k->src_ip6, ip6 + 8, 16);
        memcpy(k->dst_ip6, ip6 + 24, 16);
    }
    k->src_port = info.src_port;
    k->dst_port = info.dst_port;
    return true;
}

static bool un_udp_flow_known(struct UserNet *un, const UnUdpFlowKey *k) {
    return un_udp_find(un, k, false) != NULL;
}

void un_udp_flow_touch(struct UserNet *un, const uint8_t *frame, size_t len) {
    UnUdpFlowKey k;
    if (!un_parse_udp(frame, len, &k)) return;
    int64_t now = un_now_ms();
    un_udp_sweep(un, now);
    UnUdpFlow *e = un_udp_find(un, &k, true);
    if (!e) return;                       /* table full: admission already gated */
    if (!e->in_use) {
        e->in_use = true;
        e->key = k;
        un->udp_flow_count++;
    }
    e->last_ms = now;
}

/* ---- bounded admission --------------------------------------------------- */

bool un_admit_input(struct UserNet *un, const uint8_t *frame, size_t len) {
    if (un->live_sockets < un->socket_ceiling && un->fdreg_overflow == 0)
        return true;

    if (len < 14) return true;
    uint16_t eth = un_rd16(frame + 12);
    /* ARP and NDP must always pass: they are tiny, they are how libslirp
     * learns the guest's link-layer address, and refusing them would wedge an
     * already-established guest. */
    if (eth == UN_ETH_ARP) return true;

    UnL4Info info;
    if (!un_classify_l4(frame, len, &info)) return true;   /* unclassifiable:
                                                            * let libslirp judge */
    if (!info.first_fragment) return true;                 /* part of an
                                                            * existing datagram */
    switch (info.proto) {
    case 6:   /* TCP: refuse only a NEW connection attempt. Anything belonging
               * to an established connection — data, ACK, FIN, RST — always
               * passes, so an in-flight transfer can never be starved by a
               * flood of new connection attempts. */
        return !info.is_new_tcp_conn;
    case 17: { /* UDP: refuse only a flow this backend has not seen. */
        UnUdpFlowKey k;
        if (!un_parse_udp(frame, len, &k)) return true;
        return un_udp_flow_known(un, &k);
    }
    case 1:   /* ICMPv4 */
    case 58:  /* ICMPv6 — protocol 58, never the ICMPv4 value 1 */
        return !info.is_echo_request;   /* a new ping needs a new host socket */
    default:
        return true;
    }
}

/* Honest refusal instead of a silent drop: tell the guest the connection was
 * administratively prohibited so it fails fast rather than hanging on a
 * retransmit ladder. Quoting follows RFC 792/4443 (as much of the original
 * datagram as fits). */
void un_send_ceiling_icmp(struct UserNet *un, const uint8_t *frame, size_t len) {
    if (!un || un->dead || !un->output) return;
    uint16_t eth = un_rd16(frame + 12);
    if (eth != UN_ETH_IP && eth != UN_ETH_IPV6) return;
    if (len < 14 + 20) return;

    uint8_t out[UN_MAX_FRAME + 64];
    size_t quote_max;
    size_t hdr;

    memcpy(out, frame + 6, 6);           /* dst = original src (the guest) */
    memcpy(out + 6, frame, 6);           /* src = whatever it addressed    */

    if (eth == UN_ETH_IP) {
        const uint8_t *oip = frame + 14;
        size_t oilen = un_rd16(oip + 2);
        if (oilen < 20 || 14 + oilen > len) oilen = len - 14;
        quote_max = sizeof(out) - 14 - 20 - 8;
        if (quote_max > 508) quote_max = 508;
        size_t quote = oilen < quote_max ? oilen : quote_max;

        un_wr16(out + 12, UN_ETH_IP);
        uint8_t *ip = out + 14;
        ip[0] = 0x45; ip[1] = 0;
        un_wr16(ip + 2, (uint16_t)(20 + 8 + quote));
        un_wr16(ip + 4, 0);
        un_wr16(ip + 6, 0);
        ip[8] = 64; ip[9] = UN_IPP_ICMP;
        un_wr16(ip + 10, 0);
        memcpy(ip + 12, oip + 16, 4);    /* from the original destination */
        memcpy(ip + 16, oip + 12, 4);    /* to the original source       */
        uint8_t *ic = ip + 20;
        ic[0] = 3;                        /* destination unreachable      */
        ic[1] = 13;                       /* communication admin prohibited */
        un_wr16(ic + 2, 0);
        un_wr32(ic + 4, 0);
        memcpy(ic + 8, oip, quote);
        un_wr16(ip + 10, un_cksum_fin(un_cksum_add(0, ip, 20)));
        un_wr16(ic + 2, un_cksum_fin(un_cksum_add(0, ic, 8 + quote)));
        hdr = 14 + 20 + 8 + quote;
    } else {
        const uint8_t *oip = frame + 14;
        size_t payload = un_rd16(oip + 4);
        if (14 + 40 + payload > len) payload = len - 14 - 40;
        size_t oilen = 40 + payload;
        quote_max = sizeof(out) - 14 - 40 - 8;
        if (quote_max > 1232) quote_max = 1232;   /* IPv6 minimum MTU bound */
        size_t quote = oilen < quote_max ? oilen : quote_max;

        un_wr16(out + 12, UN_ETH_IPV6);
        uint8_t *ip6 = out + 14;
        ip6[0] = 0x60;
        un_wr16(ip6 + 2, 0);
        un_wr32(ip6 + 4, (uint32_t)(8 + quote));
        ip6[6] = 58;                       /* ICMPv6 */
        ip6[7] = 64;
        memcpy(ip6 + 8,  oip + 24, 16);    /* src = original dst */
        memcpy(ip6 + 24, oip + 8,  16);    /* dst = original src */
        uint8_t *ic = ip6 + 40;
        ic[0] = 1;                         /* destination unreachable */
        ic[1] = 1;                         /* administratively prohibited */
        un_wr16(ic + 2, 0);
        un_wr32(ic + 4, 0);
        memcpy(ic + 8, oip, quote);
        hdr = 14 + 40 + 8 + quote;
        /* The ICMPv6 checksum needs the v6 pseudo-header. */
        uint32_t sum = 0;
        sum = un_cksum_add(sum, ip6 + 8, 32);
        uint8_t ph[4] = { 0, 0, 0, 0 };
        un_wr32(ph, (uint32_t)(8 + quote));
        sum = un_cksum_add(sum, ph, 4);
        uint8_t np[4] = { 0, 0, 0, 58 };
        sum = un_cksum_add(sum, np, 4);
        sum = un_cksum_add(sum, ic, 8 + quote);
        un_wr16(ic + 2, un_cksum_fin(sum));
    }

    if (un->output(un->opaque, out, hdr)) un->out_ok++;
    else un->out_refused++;
    un->icmp_errors_sent++;
}

/* ---- fill / dispatch ----------------------------------------------------- */

typedef struct UnFillCtx {
    struct UserNet *un;
    struct pollfd  *pfds;       /* internal mode */
    UserNetWaitFd  *wfds;       /* wait mode     */
    uint32_t        cap;
    uint32_t        count;
    uint32_t        wanted;
    bool            dup_fds;
    bool            note_types;
    bool            enforce_ceiling;
    bool            count_suppressions;
    int             error;
} UnFillCtx;

static int fill_add_poll(slirp_os_socket sock, int events, void *opaque) {
    UnFillCtx *c = opaque;
    uint32_t idx = c->count;
    c->wanted++;

    int fd = (int)sock;
    if ((slirp_os_socket)fd != sock) {
        /* slirp_os_socket is int on every Apple platform, so this cannot
         * happen; if it ever does, refuse rather than poll a wrong number. */
        c->error = -EOVERFLOW;
        return -1;
    }
    if (fd < 0) return -1;

    if (idx >= c->cap) {
        /* Truncated. Returning -1 tells libslirp this descriptor is not
         * polled, so no dispatch is ever attempted for it and the caller sees
         * USERNET_WAIT_R_TRUNCATED with a clamped deadline. Never silent. */
        return -1;
    }

    int target = fd;
    if (c->dup_fds) {
        target = dup(fd);
        if (target < 0) {
            /* Out of descriptors. Report the honest error and stop growing;
             * the entries already duplicated stay owned by the caller, which
             * is documented for the DUP flag. */
            c->error = -errno;
            return -1;
        }
    }

    /* Per-VM ceiling enforcement at the resource-creation boundary.
     *
     * A forwarding listener we do not hand to poll(2) can never be reported
     * readable, so libslirp never reaches accept() and no new socket is
     * created. libslirp's listeners use listen(fd, 1), so once we stop
     * accepting the kernel refuses further host clients promptly instead of
     * hanging them: this is real backpressure at the accept boundary, not
     * bookkeeping. Existing connections are never touched — only descriptors
     * identified as one of our own forwarding listeners are withheld, and
     * only while the ceiling is actually reached. */
    if (c->enforce_ceiling && c->un->listener_suppression &&
        (c->un->live_sockets >= c->un->socket_ceiling ||
         c->un->fdreg_overflow != 0)) {
        if (un_fd_is_listener(c->un, fd)) {
            /* A just-duplicated wait entry was never published to the caller;
             * close that owned reference before rejecting the poll entry. */
            if (c->dup_fds && target >= 0 && target != fd) close(target);
            if (c->count_suppressions) c->un->accept_suppressed++;
            return -1;
        }
    }

    int pev = slirp_to_poll(events);
    if (c->pfds) {
        c->pfds[idx].fd = target;
        c->pfds[idx].events = (short)pev;
        c->pfds[idx].revents = 0;
    } else {
        c->wfds[idx].fd = target;
        c->wfds[idx].events = pev;
    }
    c->count++;

    if (c->note_types) un_fdtype_of(c->un, fd);
    return (int)idx;
}

static int fill_get_revents(int idx, void *opaque) {
    UnFillCtx *c = opaque;
    if (!c->pfds) return 0;
    if (idx < 0 || (uint32_t)idx >= c->count) return 0;
    return poll_to_slirp(c->pfds[idx].revents);
}

/* Shared body: run one libslirp fill into either destination. */
static int un_fill_common(struct UserNet *un, struct pollfd *pfds, uint32_t pcap,
                          UserNetWaitFd *wfds, uint32_t wcap, bool dup_fds,
                          uint32_t *out_count, uint32_t *out_wanted,
                          uint32_t *out_timeout, bool *out_truncated) {
    UnFillCtx ctx;
    memset(&ctx, 0, sizeof(ctx));
    ctx.un = un;
    ctx.pfds = pfds;
    ctx.wfds = wfds;
    ctx.cap = pfds ? pcap : wcap;
    ctx.dup_fds = dup_fds;
    ctx.note_types = (pfds != NULL);
    ctx.enforce_ceiling = true;
    ctx.count_suppressions = (pfds != NULL);

    /* For the type cache, clear the "seen this fill" marks first. */
    if (ctx.note_types && un->fdreg) {
        for (uint32_t i = 0; i < un->fdreg_slots; i++) un->fdreg[i].seen = false;
    }

    uint32_t timeout = UINT32_MAX;
    slirp_pollfds_fill_socket(un->slirp, &timeout, fill_add_poll, &ctx);

    *out_count = ctx.count;
    *out_wanted = ctx.wanted;
    *out_truncated = (ctx.wanted > ctx.count) || (ctx.error != 0);

    /* ---- deadline composition -------------------------------------------
     * libslirp's slirp_update_timeout() always clamps to at most 1000 ms, and
     * returns exactly 1000 when it has nothing pending (no fasttimo, no
     * slowtimo). Honouring that blanket value would add a pointless 1 Hz wake
     * to a parked machine, so treat >= 1000 ms as "no network deadline" and
     * rely on the descriptor set itself for wakeups. Every value libslirp
     * actually tightened (2 ms delayed-ACK, 499 ms slowtimo/socket expiry) is
     * honoured verbatim. */
    uint32_t t = UINT32_MAX;
    if (timeout < UN_TIMEOUT_IDLE_MS && timeout < t) t = timeout;

    int64_t td = un_timers_deadline_ms(un);
    if (td >= 0) {
        uint32_t tv = (td > (int64_t)UINT32_MAX) ? UINT32_MAX : (uint32_t)td;
        if (tv < t) t = tv;
    }
    if (un->txq_count && UN_TIMEOUT_FAST_MS < t) t = UN_TIMEOUT_FAST_MS;
    if (*out_truncated && UN_TIMEOUT_FAST_MS < t) t = UN_TIMEOUT_FAST_MS;
    if (un->notify_pending) t = 0;

    *out_timeout = t;

    if (ctx.note_types) un_fdreg_sweep_and_count(un);
    return ctx.error;
}

int usernet_fill_wait(UserNet *un, const UserNetWaitRequest *req,
                      UserNetWaitResult *out) {
    if (!req || !out) return -EINVAL;
    /* Zero first, on every path, so a caller that gets an error back still
     * sees count == 0 and never closes a descriptor it does not own. */
    memset(out, 0, sizeof(*out));
    out->struct_size = sizeof(*out);
    out->abi = USERNET_WAIT_ABI;
    if (req->struct_size < sizeof(*req)) return -EINVAL;
    if (req->abi != USERNET_WAIT_ABI) return -EINVAL;
    if (!req->entries && req->capacity) return -EINVAL;
    for (unsigned i = 0; i < 4; i++) if (req->reserved[i]) return -EINVAL;

    if (!un) { out->flags = USERNET_WAIT_R_DEAD; return 0; }
    un->wait_fills++;

    if (un->dead || !un->slirp) {
        /* Nothing can wake the network. Report a dead set and a zero deadline
         * so the waiter parks on its own CPU/RTC deadline only. */
        out->flags = USERNET_WAIT_R_DEAD;
        out->generation = un->generation;
        return 0;
    }

    /* poll_capacity is this backend's configured representation budget: it
     * bounds the internal driver array and any wait fill alike, so a small
     * configured ceiling degrades identically on both paths and truncation is
     * always reported rather than silently losing descriptors. */
    uint32_t cap = req->capacity;
    if (un->poll_capacity && cap > un->poll_capacity) cap = un->poll_capacity;

    uint32_t count = 0, wanted = 0, timeout = 0;
    bool truncated = false;
    int err = un_fill_common(un, NULL, 0, req->entries, cap,
                             (req->flags & USERNET_WAIT_F_DUP) != 0,
                             &count, &wanted, &timeout, &truncated);
    if (err != 0) {
        /* A dup() failure leaves the already-duplicated descriptors owned by
         * the caller, exactly as documented for USERNET_WAIT_F_DUP. Report
         * what was filled so nothing leaks. */
        out->count = count;
        out->wanted = wanted;
        out->truncated = 1;
        out->timeout_ms = 0;
        out->generation = un->generation;
        out->flags = USERNET_WAIT_R_TRUNCATED;
        return err;
    }

    out->count = count;
    out->wanted = wanted;
    out->truncated = truncated ? 1u : 0u;
    out->timeout_ms = timeout;
    out->generation = un->generation;
    out->flags = 0;
    if (timeout != UINT32_MAX) out->flags |= USERNET_WAIT_R_TIMER_ARMED;
    if (truncated) {
        out->flags |= USERNET_WAIT_R_TRUNCATED;
        un->wait_truncated++;
    }
    if (un->notify_pending) out->flags |= USERNET_WAIT_R_NOTIFY;
    if (un->txq_count) out->flags |= USERNET_WAIT_R_TX_PENDING;

    /* A wait fill supersedes any earlier undispatched fill: libslirp's
     * so->pollfds_idx now refers to THIS array, and the driver re-fills
     * before it ever dispatches. */
    un->dispatch_pending = false;
    return 0;
}

void usernet_poll(UserNet *un) {
    if (!un || un->dead || !un->slirp) return;
    un->polls++;

    /* 1. Deliver anything the device RX ring refused last time, before
     *    producing more. */
    un_tx_flush(un);

    /* 2. Adapter-owned timers (IPv6 RA). */
    un_timers_run(un);

    /* 3. One fill: exact descriptors, exact interests, libslirp's deadline. */
    uint32_t count = 0, wanted = 0, timeout = 0;
    bool truncated = false;
    int err = un_fill_common(un, un->pfds, un->pfds_cap, NULL, 0, false,
                             &count, &wanted, &timeout, &truncated);
    un->npfds = count;
    un->wanted = wanted;
    un->timeout_ms = timeout;
    if (truncated) un->wait_truncated++;
    un->dispatch_pending = true;

    /* 4. Learn actual readiness without blocking. The driver is called from
     *    machine_tick on the host-IO cadence and from the wait sites' wake
     *    path, so a zero timeout is correct: blocking here would nest a
     *    second sleep inside the runtime's own. */
    int ready = 0;
    if (count > 0 || err == 0) {
        ready = poll(un->pfds, (nfds_t)count, 0);
        un->poll_syscalls++;
    }

    /* 5. Dispatch. This is also where libslirp runs tcp_fasttimo /
     *    ip_slowtimo / tcp_slowtimo, so it must happen even when nothing was
     *    ready — otherwise TCP timers never advance. */
    un_dispatch(un, ready < 0);

    /* 6. Frames libslirp just produced may have been deferred. */
    un_tx_flush(un);

    /* 7. Keep the resolver snapshot fresh for the thread-safe getters. */
    un_host_dns_probe(un);

    /* 8. Publish counters. */
    un_publish_stats(un);
}

void un_dispatch(struct UserNet *un, int poll_error) {
    if (!un || un->dead || !un->slirp) { un->dispatch_pending = false; return; }
    UnFillCtx ctx;
    memset(&ctx, 0, sizeof(ctx));
    ctx.un = un;
    ctx.pfds = un->pfds;
    ctx.count = un->npfds;
    slirp_pollfds_poll(un->slirp, poll_error ? 1 : 0, fill_get_revents, &ctx);
    un->dispatch_pending = false;
    un->notify_pending = false;
}

void un_publish_stats(struct UserNet *un) {
    atomic_store(&un->pub_in_frames, un->in_frames);
    atomic_store(&un->pub_out_ok, un->out_ok);
    atomic_store(&un->pub_out_refused, un->out_refused);
    atomic_store(&un->pub_tcp_conns, un->last_tcp_conns);
    atomic_store(&un->pub_udp_flows, un->last_udp_flows);
    atomic_store(&un->pub_dns_v4, un_host_dns4(un));
}
