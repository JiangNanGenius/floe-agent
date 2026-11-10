/* SPDX-License-Identifier: Apache-2.0 */
/* Copyright 2026 Sylirre */
/* Modified by Floe contributors, 2026-11-10: mature network backend,
 * bounded event integration and virtual-NIC scheduling/offloads. */
/* usernet core: public API entry points, the libslirp 4.9.7 callback table,
 * Ethernet frame intake, host-forward registry, resolver reporting and full
 * teardown. The poll driver, timers, deferred TX and bounded ceilings live in
 * usernet_poll.c; Apple resolver discovery and DNS64/NAT64 mapping live in
 * usernet_host.c.
 *
 * libslirp is BSD-3-Clause, (c) the libslirp authors; see
 * FloeAgent/Vendor/FloeSlirp carries the pinned source and license/relink
 * records. This file only calls its public API
 * (libslirp.h) and never reaches into its private headers.
 *
 * Floe embedded constraints honoured here: no process exit, no atexit, no
 * environment variables, no fork/exec, no dlopen, no TAP/TUN, no privileges,
 * no global signal handlers. Diagnostics go to stderr through a rate limiter.
 */
#include "usernet_priv.h"
#include "usernet_host.h"

#include <stdarg.h>
#include <time.h>

/* ---- monotonic clock, shared with libslirp's virtual clock ---- */

#ifdef FLOE_USERNET_TEST_HOOKS
void usernet_test_set_listener_suppression(struct UserNet *un, bool on) {
    if (un) un->listener_suppression = on;
}
#endif

#ifdef FLOE_USERNET_TEST_HOOKS
/* QUALIFICATION ONLY. libslirp randomizes its router-advertisement interval
 * over hundreds of seconds (NDP_Interval draws from
 * [NDP_MinRtrAdvInterval, NDP_MaxRtrAdvInterval]), so a real timer-expiry test
 * would otherwise have to wait minutes. This offset lets a test advance the
 * single monotonic clock that feeds BOTH un_now_ms() and libslirp's
 * clock_get_ns(), keeping the two consistent. A shipping build has no such
 * symbol: the offset does not exist and the clock is always CLOCK_MONOTONIC. */
static int64_t g_clock_offset_ms;
void un_host_test_advance_clock(int64_t ms) { g_clock_offset_ms += ms; }
void un_host_test_reset_clock(void) { g_clock_offset_ms = 0; }
int64_t un_host_test_clock_offset_ms(void) { return g_clock_offset_ms; }
#define UN_CLOCK_OFFSET_MS g_clock_offset_ms
#else
#define UN_CLOCK_OFFSET_MS 0
#endif

int64_t un_now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000 + UN_CLOCK_OFFSET_MS;
}

static int64_t un_now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ((int64_t)ts.tv_sec * 1000000000 + ts.tv_nsec) +
           (int64_t)UN_CLOCK_OFFSET_MS * 1000000;
}

/* ---- bounded diagnostics -------------------------------------------------
 * libslirp reports guest misbehaviour through guest_error. A misbehaving or
 * probing guest could otherwise make the host emit an unbounded log stream,
 * which on iOS is both a performance and a privacy concern. Rate limit hard. */
static int64_t  g_note_window_ms;
static unsigned g_note_count;
#define UN_NOTE_PER_WINDOW 8
#define UN_NOTE_WINDOW_MS  5000

static void un_note(const char *fmt, ...) {
    int64_t now = un_now_ms();
    if (now - g_note_window_ms > UN_NOTE_WINDOW_MS) {
        g_note_window_ms = now;
        g_note_count = 0;
    }
    if (g_note_count >= UN_NOTE_PER_WINDOW) return;
    g_note_count++;
    va_list ap;
    va_start(ap, fmt);
    fprintf(stderr, "[usernet] ");
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
    va_end(ap);
}

/* ---- libslirp callbacks -------------------------------------------------- */

static slirp_ssize_t cb_send_packet(const void *buf, size_t len, void *opaque) {
    struct UserNet *un = opaque;
    if (!un || un->dead || !un->output) return -1;

    if (un->output(un->opaque, buf, len)) {
        un->out_ok++;
        return (slirp_ssize_t)len;
    }
    /* The device RX ring is full. libslirp does NOT retry a failed
     * send_packet — slirp_send_packet_all() only logs — so dropping here would
     * silently lose UDP/ICMP/DHCP frames and force a TCP retransmit round
     * trip. Defer into a bounded FIFO instead and report success; the FIFO is
     * flushed at the top of the next usernet_poll(), which virtio_net_poll()
     * calls immediately before net_flush_rx(). TCP stays correct either way
     * because libslirp keeps unacknowledged bytes in so_snd. */
    un->out_refused++;
    if (un_tx_defer(un, buf, len)) {
        un->out_deferred++;
        return (slirp_ssize_t)len;
    }
    un->out_dropped_queue++;
    return (slirp_ssize_t)len;   /* honest counters above; never a spurious IO error */
}

static void cb_guest_error(const char *msg, void *opaque) {
    (void)opaque;
    un_note("guest error: %s", msg ? msg : "(null)");
}

static int64_t cb_clock_get_ns(void *opaque) {
    (void)opaque;
    /* Host monotonic time. libslirp only ever computes deltas from this and
     * truncates to a 32-bit millisecond `curtime`, whose unsigned arithmetic
     * is wrap-safe. Using host time (rather than guest virtual time) is
     * deliberate: TCP retransmission and socket expiry must track the real
     * network, and the machine is idle between slices. */
    return un_now_ns();
}

static void *cb_timer_new(SlirpTimerCb cb, void *cb_opaque, void *opaque) {
    struct UserNet *un = opaque;
    for (uint32_t i = 0; i < UN_TIMER_MAX; i++) {
        UnTimer *t = &un->timers[i];
        if (t->in_use) continue;
        t->in_use = true;
        t->armed = false;
        t->expire_ms = 0;
        t->cb = cb;
        t->cb_opaque = cb_opaque;
        if (i + 1 > un->timer_count) un->timer_count = i + 1;
        return t;
    }
    /* Upstream 4.9.7 creates exactly one timer (SLIRP_TIMER_RA). Refuse
     * honestly rather than aliasing: a NULL return makes slirp_new fail. */
    un_note("timer table exhausted (%u)", UN_TIMER_MAX);
    return NULL;
}

static void cb_timer_free(void *timer, void *opaque) {
    struct UserNet *un = opaque;
    UnTimer *t = timer;
    if (!t) return;
    for (uint32_t i = 0; i < UN_TIMER_MAX; i++) {
        if (&un->timers[i] != t) continue;
        t->in_use = false;
        t->armed = false;
        t->cb = NULL;
        t->cb_opaque = NULL;
        while (un->timer_count > 0 && !un->timers[un->timer_count - 1].in_use)
            un->timer_count--;
        return;
    }
}

static void cb_timer_mod(void *timer, int64_t expire_time, void *opaque) {
    (void)opaque;
    UnTimer *t = timer;
    if (!t || !t->in_use) return;
    /* libslirp passes an absolute deadline on the clock_get_ms scale. */
    t->expire_ms = expire_time;
    t->armed = true;
}

static void cb_notify(void *opaque) {
    struct UserNet *un = opaque;
    if (!un) return;
    /* A send buffer drained below its half-full mark: libslirp can accept
     * more guest data. Surface it so both wait sites re-enter promptly
     * instead of sleeping to their own deadline. */
    un->notify_pending = true;
}

static void cb_init_completed(Slirp *slirp, void *opaque) {
    struct UserNet *un = opaque;
    if (!un) return;
    un->slirp = slirp;
    un->init_completed = true;
}

static void cb_register_poll_socket(slirp_os_socket socket, void *opaque) {
    struct UserNet *un = opaque;
    if (!un) return;
    int fd = (int)socket;
    if ((slirp_os_socket)fd != socket) {
        /* Cannot happen on Apple platforms (slirp_os_socket is int) but the
         * truncation must never be silent. */
        un_note("descriptor truncated in register_poll_socket");
        return;
    }
    if (fd < 0) return;
    /* The registry is the authoritative live set and maintains live_sockets
     * and the high-water mark itself. */
    un_fdreg_add(un, fd);
    un->generation++;
}

static void cb_unregister_poll_socket(slirp_os_socket socket, void *opaque) {
    struct UserNet *un = opaque;
    if (!un) return;
    int fd = (int)socket;
    if ((slirp_os_socket)fd != socket || fd < 0) return;
    /* Drop the cached type and listener verdict too: the number is about to
     * become reusable and a stale verdict would corrupt the counters. */
    un_fdreg_del(un, fd);
    un->generation++;
}

const SlirpCb un_slirp_cb = {
    .send_packet           = cb_send_packet,
    .guest_error           = cb_guest_error,
    .clock_get_ns          = cb_clock_get_ns,
    .timer_new             = cb_timer_new,
    .timer_free            = cb_timer_free,
    .timer_mod             = cb_timer_mod,
    /* The deprecated register_poll_fd / unregister_poll_fd members are left
     * unset by the designated initialiser: with SlirpConfig version 6 libslirp
     * uses the typed socket pair below and never touches them. Naming them
     * here would trip -Wdeprecated-declarations for no benefit. */
    .notify                = cb_notify,
    .init_completed        = cb_init_completed,
    .timer_new_opaque      = NULL,   /* use the direct-callback timer path */
    .register_poll_socket  = cb_register_poll_socket,
    .unregister_poll_socket= cb_unregister_poll_socket,
};

/* ---- construction -------------------------------------------------------- */

static void un_fill_slirp_config(struct UserNet *un, SlirpConfig *cfg) {
    memset(cfg, 0, sizeof(*cfg));
    cfg->version = SLIRP_CONFIG_VERSION_MAX;   /* 6: typed poll socket hooks */

    cfg->restricted   = (un->flags & USERNET_CFG_F_RESTRICTED) ? 1 : 0;
    cfg->in_enabled   = true;                  /* IPv4 guest: preserved */
    cfg->vnetwork.s_addr   = htonl(UN_NET);
    cfg->vnetmask.s_addr   = htonl(UN_NETMASK);
    cfg->vhost.s_addr      = htonl(UN_IP_HOST);
    cfg->vdhcp_start.s_addr= htonl(UN_IP_GUEST);
    cfg->vnameserver.s_addr= htonl(UN_IP_DNS);

    /* Guest IPv6 is opt-in: the shipped guest image is IPv4 configured and
     * turning this on starts RA/NDP traffic the guest has not asked for. */
    cfg->in6_enabled = (un->flags & USERNET_CFG_F_IPV6) ? true : false;
    if (cfg->in6_enabled) {
        /* fd00::/64, host fd00::2, nameserver fd00::3 — upstream defaults. */
        cfg->vprefix_addr6.s6_addr[0] = 0xfd;
        cfg->vprefix_len = 64;
        cfg->vhost6.s6_addr[0] = 0xfd;
        cfg->vhost6.s6_addr[15] = 0x02;
        cfg->vnameserver6.s6_addr[0] = 0xfd;
        cfg->vnameserver6.s6_addr[15] = 0x03;
    }

    cfg->vhostname   = "floe";
    /* tftp_path NULL means the TFTP service is disabled: no host directory is
     * ever exposed to the guest. No bootfile, no DNS search list, no domain. */
    cfg->tftp_server_name = NULL;
    cfg->tftp_path        = NULL;
    cfg->bootfile         = NULL;
    cfg->vdnssearch       = NULL;
    cfg->vdomainname      = NULL;

    cfg->if_mtu = un->if_mtu;
    cfg->if_mru = un->if_mru;

    /* Preserved default: 10.0.2.2 reaches host loopback services, which is how
     * the current port-page flow works. Never widened by this candidate. */
    cfg->disable_host_loopback = (un->flags & USERNET_CFG_F_NO_LOOPBACK) ? true : false;
    /* enable_emu is documented by upstream as unsafe; it stays off. */
    cfg->enable_emu = false;
    cfg->outbound_addr  = NULL;
    cfg->outbound_addr6 = NULL;
    cfg->disable_dns  = false;
    cfg->disable_dhcp = false;
    cfg->mfr_id = 0;
    memset(cfg->oob_eth_addr, 0, sizeof(cfg->oob_eth_addr));
}

static struct UserNet *un_alloc_common(usernet_output_fn output, void *opaque) {
    if (!output) return NULL;
    struct UserNet *un = calloc(1, sizeof(*un));
    if (!un) return NULL;
    un->output = output;
    un->opaque = opaque;
    un->slirp = NULL;
    un->dead = true;              /* only cleared once slirp_new succeeds */
    un->if_mtu = UN_MTU_DEFAULT;
    un->if_mru = UN_MTU_DEFAULT;
    un->socket_ceiling = USERNET_DEF_MAX_SOCKETS;
    un->poll_capacity = USERNET_DEF_POLL_CAPACITY;
#ifdef SLIRP_FLOE_HOST_HOOKS
    /* With the authoritative allocation/accept hook, listeners stay polled.
     * At the ceiling libslirp accepts and immediately closes excess clients,
     * so a queued host client fails fast instead of waiting behind a withheld
     * listener. The bounded backlog still absorbs normal parallel bursts. */
    un->listener_suppression = false;
#else
    /* Stock compatibility profile only: without an accept hook, withholding
     * the listener is the available backpressure fallback. */
    un->listener_suppression = true;
#endif
    un->timeout_ms = UINT32_MAX;
    un->generation = 1;
    return un;
}

UserNet *usernet_new(usernet_output_fn output, void *opaque,
                     const uint8_t guest_mac[6], uint32_t dns_server) {
    struct UserNet *un = un_alloc_common(output, opaque);
    if (!un) return NULL;
    if (guest_mac) memcpy(un->guest_mac, guest_mac, 6);
    un->dns_cfg4 = dns_server;
    un->txq_cap = USERNET_DEF_TX_QUEUE_FRAMES;
    un->txq_bytes_cap = USERNET_DEF_TX_QUEUE_BYTES;
    un->udp_flow_cap = USERNET_DEF_MAX_SOCKETS;

    un_tx_init(un, un->txq_cap, un->txq_bytes_cap);
    un_timers_init(un);

    SlirpConfig cfg;
    un_fill_slirp_config(un, &cfg);
    un->slirp = slirp_new(&cfg, &un_slirp_cb, un);
    if (!un->slirp) {
        un_note("slirp_new failed");
        usernet_destroy(un);
        return NULL;
    }
    un->dead = false;
    un_host_install_hooks(un);

    un->pfds_cap = un->poll_capacity;
    un->pfds = calloc(un->pfds_cap, sizeof(*un->pfds));
    if (!un->pfds) { usernet_destroy(un); return NULL; }

    un->udp_flows = calloc(un->udp_flow_cap, sizeof(*un->udp_flows));
    if (!un->udp_flows) { usernet_destroy(un); return NULL; }
    un_fdreg_init(un);
    if (!un->fdreg) { usernet_destroy(un); return NULL; }

    /* Discover the host resolver once, up front, so the first guest DNS
     * query is not the thing that pays for res_ninit(). */
    un_host_dns_probe(un);
    atomic_store(&un->pub_dns_v4, un_host_dns4(un));
    return un;
}

UserNet *usernet_new_with_config(usernet_output_fn output, void *opaque,
                                 const UserNetConfig *cfg) {
    if (!cfg) return NULL;
    if (cfg->struct_size < sizeof(*cfg)) return NULL;
    if (cfg->abi != USERNET_CFG_ABI) return NULL;
    for (unsigned i = 0; i < 4; i++) if (cfg->reserved[i]) return NULL;

    struct UserNet *un = un_alloc_common(output, opaque);
    if (!un) return NULL;
    memcpy(un->guest_mac, cfg->guest_mac, 6);
    un->flags = cfg->flags;
    un->if_mtu = cfg->if_mtu ? cfg->if_mtu : UN_MTU_DEFAULT;
    un->if_mru = cfg->if_mru ? cfg->if_mru : UN_MTU_DEFAULT;
    if (un->if_mtu > UN_MTU_DEFAULT) un->if_mtu = UN_MTU_DEFAULT;
    if (un->if_mru > UN_MTU_DEFAULT) un->if_mru = UN_MTU_DEFAULT;

    un->socket_ceiling = cfg->max_sockets ? cfg->max_sockets
                                          : USERNET_DEF_MAX_SOCKETS;
    if (un->socket_ceiling > USERNET_MAX_SOCKETS)
        un->socket_ceiling = USERNET_MAX_SOCKETS;
    un->poll_capacity = cfg->poll_capacity ? cfg->poll_capacity
                                           : USERNET_DEF_POLL_CAPACITY;
    if (un->poll_capacity > USERNET_MAX_POLL_CAPACITY)
        un->poll_capacity = USERNET_MAX_POLL_CAPACITY;
    un->txq_cap = cfg->tx_queue_frames ? cfg->tx_queue_frames
                                       : USERNET_DEF_TX_QUEUE_FRAMES;
    un->txq_bytes_cap = cfg->tx_queue_bytes ? cfg->tx_queue_bytes
                                            : USERNET_DEF_TX_QUEUE_BYTES;
    /* The UDP ceiling table is sized from the same budget so a flow can never
     * be refused before the descriptor ceiling that actually matters. Its hash
     * mask requires a power-of-two capacity, including tiny non-power-of-two
     * qualification ceilings such as 3. */
    un->udp_flow_cap = 1;
    while (un->udp_flow_cap < un->socket_ceiling)
        un->udp_flow_cap <<= 1;

    if (cfg->dns_server) {
        struct in_addr a;
        if (inet_pton(AF_INET, cfg->dns_server, &a) != 1) {
            un_note("ignoring unparsable dns_server '%s'", cfg->dns_server);
        } else {
            un->dns_cfg4 = ntohl(a.s_addr);
        }
    } else if (cfg->dns_server_v4) {
        /* The numeric form used by the existing virtio-net plumbing. */
        un->dns_cfg4 = cfg->dns_server_v4;
    }
    if (cfg->dns_server6) {
        un->dns_cfg6 = strdup(cfg->dns_server6);
        if (!un->dns_cfg6) { usernet_destroy(un); return NULL; }
    }

    un_tx_init(un, un->txq_cap, un->txq_bytes_cap);
    un_timers_init(un);

    SlirpConfig scfg;
    un_fill_slirp_config(un, &scfg);
    un->slirp = slirp_new(&scfg, &un_slirp_cb, un);
    if (!un->slirp) {
        un_note("slirp_new failed");
        usernet_destroy(un);
        return NULL;
    }
    un->dead = false;
    un_host_install_hooks(un);

    un->pfds_cap = un->poll_capacity;
    un->pfds = calloc(un->pfds_cap, sizeof(*un->pfds));
    if (!un->pfds) { usernet_destroy(un); return NULL; }

    un->udp_flows = calloc(un->udp_flow_cap, sizeof(*un->udp_flows));
    if (!un->udp_flows) { usernet_destroy(un); return NULL; }
    un_fdreg_init(un);
    if (!un->fdreg) { usernet_destroy(un); return NULL; }

    un_host_apply_overrides(un);
    un_host_dns_probe(un);
    atomic_store(&un->pub_dns_v4, un_host_dns4(un));
    return un;
}

/* ---- teardown ------------------------------------------------------------ */

void usernet_destroy(UserNet *un) {
    if (!un) return;

    /* Mark dead FIRST: slirp_cleanup() can still reach send_packet through a
     * closing socket, and the contract is that the output callback is never
     * invoked from or after teardown. */
    un->dead = true;

    if (un->slirp) {
        slirp_cleanup(un->slirp);
        un->slirp = NULL;
    }
    un->init_completed = false;
    un->live_sockets = 0;

    un_timers_free(un);
    un_tx_free(un);
    un_udp_flows_free(un);
    un_fdreg_free(un);

    free(un->pfds);
    un->pfds = NULL;
    un->pfds_cap = 0;
    un->npfds = 0;

    free(un->dns_cfg6);
    un->dns_cfg6 = NULL;
    un_host_free(un);

    un->output = NULL;
    un->opaque = NULL;
    free(un);
}

void usernet_guest_reset(UserNet *un) {
    if (!un || un->dead || !un->slirp) return;
    /* A warm reboot must drop guest flows but keep the host-side forwarding
     * rules, exactly as before. libslirp has no per-flow reset entry point, so
     * the honest equivalent is a full stack rebuild: the rules live in our own
     * registry and are replayed. The output callback is not touched. */
    UnHostFwd saved[UN_FWD_MAX];
    memcpy(saved, un->fwd, sizeof(saved));

    bool was_dead = un->dead;
    un->dead = true;                 /* suppress output during teardown */
    if (un->slirp) { slirp_cleanup(un->slirp); un->slirp = NULL; }
    /* Mappings learned under the old guest/network lifetime must not leak into
     * the rebuilt stack, and flushing this instance cannot affect another VM. */
    un_host_nat64_flush(un);
    atomic_store(&un->dns.nat64_active, 0);
    atomic_store(&un->dns.nat64_prefix_len, 0);
    for (unsigned i = 0; i < 16; i++) atomic_store(&un->dns.nat64_prefix[i], 0);
    un_timers_free(un);
    un_timers_init(un);
    un_tx_free(un);
    un_tx_init(un, un->txq_cap, un->txq_bytes_cap);
    un_fdreg_reset(un);
    un->live_sockets = 0;
    un->generation++;

    SlirpConfig cfg;
    un_fill_slirp_config(un, &cfg);
    un_fdreg_init(un);
    un->slirp = slirp_new(&cfg, &un_slirp_cb, un);
    un->dead = was_dead;
    if (un->slirp) un_host_install_hooks(un);
    if (!un->slirp) {
        un->dead = true;
        un_note("guest reset could not rebuild the stack");
        return;
    }
    /* Replay the forwarding rules on the fresh instance. */
    for (uint32_t i = 0; i < UN_FWD_MAX; i++) {
        if (!saved[i].in_use) continue;
        struct in_addr host, guest;
        host.s_addr = htonl(INADDR_LOOPBACK);
        guest.s_addr = htonl(UN_IP_GUEST);
        if (slirp_add_hostfwd(un->slirp, saved[i].is_udp ? 1 : 0, host,
                              saved[i].host_port, guest,
                              saved[i].guest_port) < 0) {
            un_note("guest reset could not restore forward %s %u",
                    saved[i].is_udp ? "udp" : "tcp", saved[i].host_port);
        }
    }
    /* A fresh stack has no ARP entry for the guest yet; it will re-learn it
     * from the guest's own ARP request, exactly as at boot. */
    un_udp_flow_forget_all(un);
}

/* ---- frame intake -------------------------------------------------------- */

void usernet_input(UserNet *un, const uint8_t *frame, size_t len) {
    if (!un || un->dead || !un->slirp || !frame) return;
    if (len < 14) { un->in_dropped_short++; return; }
    if (len > (size_t)UN_MAX_FRAME + 4) { un->in_dropped_short++; return; }

    un->in_frames++;

    /* Track the guest MAC for diagnostics. libslirp learns the link-layer
     * address itself through ARP/NDP, which is strictly more robust than
     * trusting the advertised config-space MAC. */
    if (memcmp(un->guest_mac, frame + 6, 6) != 0)
        memcpy(un->guest_mac, frame + 6, 6);

    /* Bounded per-VM admission. Refuses only work that would create a NEW
     * flow once the descriptor ceiling is reached; established traffic always
     * passes, so an in-flight transfer can never be starved by a flood of new
     * connection attempts. */
    if (!un_admit_input(un, frame, len)) {
        un->in_refused_ceiling++;
        un->in_refused_guest++;
        /* Answer honestly rather than black-holing: un_send_ceiling_icmp
         * re-derives the quoting itself and no-ops for anything it cannot
         * build (non-IP, runt, or an unclassifiable extension chain). */
        un_send_ceiling_icmp(un, frame, len);
        return;
    }
    un_udp_flow_touch(un, frame, len);

    slirp_input(un->slirp, frame, (int)len);
}

/* ---- host forwarding ---------------------------------------------------- */

int usernet_add_hostfwd(UserNet *un, bool is_udp,
                        uint16_t host_port, uint16_t guest_port) {
    if (!un || un->dead || !un->slirp) return -ESHUTDOWN;
    if (!host_port || !guest_port) return -EINVAL;

    uint32_t n = 0, free_slot = UN_FWD_MAX;
    for (uint32_t i = 0; i < UN_FWD_MAX; i++) {
        if (!un->fwd[i].in_use) { if (free_slot == UN_FWD_MAX) free_slot = i; continue; }
        n++;
        /* Duplicate rule, even cross-protocol: same honest -EADDRINUSE the
         * previous stack returned, so the bridge mapping is unchanged. */
        if (un->fwd[i].is_udp == is_udp && un->fwd[i].host_port == host_port)
            return -EADDRINUSE;
    }
    if (n >= UN_FWD_MAX || free_slot == UN_FWD_MAX) return -ENOBUFS;
    /* A forwarding listener is itself one of this VM's bounded host sockets.
     * Gate before libslirp allocates it, rather than limiting only later accept
     * or guest flows. Reset replay starts with an empty registry and therefore
     * cannot exceed the same configured budget. */
    if (un->live_sockets >= un->socket_ceiling || un->fdreg_overflow)
        return -EMFILE;

    struct in_addr host_addr, guest_addr;
    /* Listeners bind host loopback only: the guest NAT is not a
     * network-exposed service surface. Preserved exactly. */
    host_addr.s_addr  = htonl(INADDR_LOOPBACK);
    guest_addr.s_addr = htonl(UN_IP_GUEST);

    errno = 0;
    int r = slirp_add_hostfwd(un->slirp, is_udp ? 1 : 0, host_addr, host_port,
                              guest_addr, guest_port);
    if (r < 0) {
        int e = errno;
        /* libslirp reports -1 without always setting errno (e.g. a duplicate
         * it detected internally). Never return a bare 0. */
        return e ? -e : -EADDRINUSE;
    }

    un->fwd[free_slot].in_use     = true;
    un->fwd[free_slot].is_udp     = is_udp;
    un->fwd[free_slot].host_port  = host_port;
    un->fwd[free_slot].guest_port = guest_port;
    un->n_fwd = n + 1;
    un->generation++;
    return 0;
}

int usernet_remove_hostfwd(UserNet *un, bool is_udp, uint16_t host_port) {
    if (!un || un->dead || !un->slirp) return -ESHUTDOWN;
    for (uint32_t i = 0; i < UN_FWD_MAX; i++) {
        if (!un->fwd[i].in_use) continue;
        if (un->fwd[i].is_udp != is_udp || un->fwd[i].host_port != host_port)
            continue;
        struct in_addr host_addr;
        host_addr.s_addr = htonl(INADDR_LOOPBACK);
        errno = 0;
        int r = slirp_remove_hostfwd(un->slirp, is_udp ? 1 : 0, host_addr,
                                     host_port);
        un->fwd[i].in_use = false;
        if (un->n_fwd) un->n_fwd--;
        un->generation++;
        if (r < 0) {
            int e = errno;
            /* The rule was ours and is now gone; report the host error only if
             * there really was one. */
            return e ? -e : 0;
        }
        return 0;
    }
    return -ENOENT;
}

/* ---- reporting ---------------------------------------------------------- */

uint32_t usernet_dns_server(UserNet *un) {
    if (!un) return 0;
    return atomic_load(&un->pub_dns_v4);
}

void usernet_get_stats(UserNet *un,
                       uint64_t *in_frames, uint64_t *out_ok,
                       uint64_t *out_refused,
                       unsigned *tcp_conns, unsigned *udp_flows) {
    if (!un) return;
    if (in_frames)   *in_frames   = atomic_load(&un->pub_in_frames);
    if (out_ok)      *out_ok      = atomic_load(&un->pub_out_ok);
    if (out_refused) *out_refused = atomic_load(&un->pub_out_refused);
    if (tcp_conns)   *tcp_conns   = atomic_load(&un->pub_tcp_conns);
    if (udp_flows)   *udp_flows   = atomic_load(&un->pub_udp_flows);
}

void usernet_get_ext_stats(UserNet *un, UserNetExtStats *out) {
    if (!out) return;
    memset(out, 0, sizeof(*out));
    out->struct_size = sizeof(*out);
    out->abi = USERNET_STATS_ABI;
    if (!un) return;
    out->in_frames          = atomic_load(&un->pub_in_frames);
    out->out_ok             = atomic_load(&un->pub_out_ok);
    out->out_refused        = atomic_load(&un->pub_out_refused);
    out->in_dropped_short   = un->in_dropped_short;
    out->in_refused_ceiling = un->in_refused_ceiling;
    out->out_deferred       = un->out_deferred;
    out->out_dropped_queue  = un->out_dropped_queue;
    out->icmp_errors_sent   = un->icmp_errors_sent;
    out->accept_suppressed  = un->accept_suppressed;
    out->in_refused_guest   = un->in_refused_guest;
    out->polls              = un->polls;
    out->poll_syscalls      = un->poll_syscalls;
    out->wait_fills         = un->wait_fills;
    out->wait_truncated     = un->wait_truncated;
    out->timers_armed       = un_timers_armed(un);
    out->timer_expiries     = un->timer_expiries;
    out->live_sockets       = un->live_sockets;
    out->max_live_sockets   = un->max_live_sockets;
    out->socket_ceiling     = un->socket_ceiling;
    out->poll_capacity      = un->poll_capacity;
}

int usernet_get_dns_info(UserNet *un, UserNetDnsInfo *out) {
    if (!out) return -EINVAL;
    memset(out, 0, sizeof(*out));
    out->struct_size = sizeof(*out);
    out->abi = USERNET_DNS_ABI;
    if (!un) return -EINVAL;

    for (;;) {
        uint32_t begin = atomic_load_explicit(&un->dns.revision,
                                               memory_order_acquire);
        if (begin & 1u) continue;       /* a probe is publishing: retry */
        UserNetDnsInfo tmp;
        memset(&tmp, 0, sizeof(tmp));
        tmp.struct_size = sizeof(tmp);
        tmp.abi = USERNET_DNS_ABI;
        tmp.v4_valid = atomic_load(&un->dns.v4_valid);
        tmp.v4_addr  = atomic_load(&un->dns.v4_addr);
        tmp.v4_port  = atomic_load(&un->dns.v4_port);
        tmp.v6_valid = atomic_load(&un->dns.v6_valid);
        tmp.v6_port  = atomic_load(&un->dns.v6_port);
        tmp.v6_scope_id = atomic_load(&un->dns.v6_scope);
        for (unsigned i = 0; i < 16; i++)
            tmp.v6_addr[i] = atomic_load(&un->dns.v6_addr[i]);
        tmp.nat64_active = atomic_load(&un->dns.nat64_active);
        for (unsigned i = 0; i < 16; i++)
            tmp.nat64_prefix[i] = atomic_load(&un->dns.nat64_prefix[i]);
        tmp.nat64_prefix_len = atomic_load(&un->dns.nat64_prefix_len);
        tmp.ipv6_guest_enabled = (un->flags & USERNET_CFG_F_IPV6) ? 1u : 0u;
        uint32_t end = atomic_load_explicit(&un->dns.revision,
                                             memory_order_acquire);
        if (begin == end) {
            *out = tmp;
            return 0;
        }
    }
}

/* ---- deprecated fd-only snapshot ---------------------------------------- */

int usernet_wait_fds(UserNet *un, int *fds, int max) {
    if (!un || !fds || max <= 0) return 0;
    if (un->dead || !un->slirp) return 0;

    UserNetWaitFd stack[128];
    UserNetWaitFd *entries = stack;
    uint32_t cap = (uint32_t)(max < 128 ? max : 128);
    UserNetWaitRequest req = {
        .struct_size = sizeof(req), .abi = USERNET_WAIT_ABI,
        .capacity = cap, .flags = 0, .entries = entries,
    };
    UserNetWaitResult res;
    if (usernet_fill_wait(un, &req, &res) != 0) return 0;
    int n = 0;
    for (uint32_t i = 0; i < res.count && n < max; i++) fds[n++] = entries[i].fd;
    return n;
}
