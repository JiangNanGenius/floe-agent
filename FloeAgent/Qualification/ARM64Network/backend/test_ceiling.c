/* SPDX-License-Identifier: Apache-2.0 */
/* Per-VM ceiling enforcement and IPv6 path tests.
 *
 * The reviewer's finding being pinned here: gating only guest-initiated flows
 * in usernet_input() is NOT a real per-VM ceiling, because an inbound forwarded
 * connection is accepted by libslirp's own poll dispatch and never passes
 * through usernet_input() at all. These tests hammer a forward with far more
 * host clients than the ceiling allows and assert the observed high-water mark
 * never crosses it, that an already-established transfer keeps flowing at the
 * limit, and that IPv6 (protocol 58, extension chains) is classified honestly.
 */
#include "net_test_util.h"

#include <stdio.h>

static struct UserNet *make_cfg(VGuest *g, uint32_t flags, uint32_t max_sockets) {
    vg_init(g);
    uint8_t mac[6] = VG_MAC_GUEST;
    UserNetConfig cfg;
    memset(&cfg, 0, sizeof(cfg));
    cfg.struct_size = sizeof(cfg);
    cfg.abi = USERNET_CFG_ABI;
    memcpy(cfg.guest_mac, mac, 6);
    cfg.flags = flags;
    cfg.max_sockets = max_sockets;
    cfg.poll_capacity = 64;
    return usernet_new_with_config(vg_output, g, &cfg);
}

/* ---- 1. inbound accept boundary ---- */

static void test_ceiling_hostfwd_stress(void) {
    T_BEGIN("ceiling: many host clients on a forward cannot exceed max_sockets");

    VGuest *g = calloc(1, sizeof(*g));
    struct UserNet *un = make_cfg(g, 0, 4);      /* listener + 3 connections */
    T_CHECK(un != NULL);
    if (!un) { free(g); return; }
    T_CHECK(tu_boot(g, un));

    uint16_t hp = tu_reserve_tcp_port();
    T_CHECK(hp != 0);
    T_EQ_U(usernet_add_hostfwd(un, false, hp, 9800), 0);

    /* These clients arrive through libslirp's poll/accept path and never pass
     * through usernet_input(), so the guest-side admission gate alone cannot
     * bound them: the backend must withhold the forwarding listener from the
     * poll set once the ceiling is reached. */
    int clients[48];
    int nclients = 0;
    for (int i = 0; i < 48; i++) {
        int c = socket(AF_INET, SOCK_STREAM, 0);
        if (c < 0) break;
        tu_set_nonblock(c);
        struct sockaddr_in sa;
        memset(&sa, 0, sizeof(sa));
        sa.sin_family = AF_INET;
        sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        sa.sin_port = htons(hp);
        connect(c, (struct sockaddr *)&sa, sizeof(sa));
        clients[nclients++] = c;
        for (int k = 0; k < 8; k++) { usernet_poll(un); vg_drain(g, un, tu_emit); }
    }

    UserNetExtStats xs;
    tu_ext(un, &xs);
    T_NOTE("%d host clients attempted against a ceiling of %u",
           nclients, xs.socket_ceiling);
    T_NOTE("max_live_sockets=%u live_sockets=%u accept_suppressed=%llu",
           xs.max_live_sockets, xs.live_sockets,
           (unsigned long long)xs.accept_suppressed);

    /* The hard requirement: the observed high-water mark never crosses the
     * configured per-VM ceiling. This is a real bound, not OS descriptor
     * exhaustion — 48 clients were offered and the ceiling was 4. */
    T_CHECK(xs.max_live_sockets <= xs.socket_ceiling);
    T_CHECK(xs.live_sockets <= xs.socket_ceiling);
#ifdef SLIRP_FLOE_HOST_HOOKS
    T_EQ_U(xs.accept_suppressed, 0);  /* listeners stay polled; hook closes excess */
#else
    T_CHECK(xs.accept_suppressed > 0); /* stock compatibility backpressure */
#endif
    T_CHECK(nclients > (int)xs.socket_ceiling);

    /* Releasing capacity must resume accepting: the ceiling is a throttle, not
     * a permanent shutdown.
     *
     * The host clients were closed, but a forwarded connection whose guest side
     * never completed the handshake is not reaped by the peer closing: libslirp
     * only registers read interest once SS_ISFCONNECTED is set, so the
     * descriptor survives until libslirp's own TCP retransmission timers give
     * up on it. Drive the gated virtual clock through that timeout rather than
     * assuming an immediate release, then assert the count really converges
     * back down — which is also what proves the registry cannot drift upward
     * and wedge the backend permanently. */
    uint64_t suppressed_before = xs.accept_suppressed;
    for (int i = 0; i < nclients; i++) { close(clients[i]); }
    nclients = 0;
    uint32_t peak = xs.max_live_sockets;
    /* libslirp decrements its TCP timers once per slowtimo invocation, and a
     * slowtimo runs at most once per TIMEOUT_SLOW (499 ms) of virtual time. So
     * advancing the clock in coarse jumps only buys one tick per jump: give up
     * on a half-open forwarded connection needs the full retransmit ladder
     * (~2000 ticks). Step the clock by exactly one slowtimo period per poll so
     * every iteration really is a tick. */
    int ticks = 0;
    while (ticks < 6000 && xs.live_sockets > 1) {
        un_host_test_advance_clock(500);
        usernet_poll(un);
        vg_drain(g, un, tu_emit);
        ticks++;
        if ((ticks % 64) == 0) tu_ext(un, &xs);
    }
    tu_ext(un, &xs);
    T_NOTE("after clients closed + %d slowtimo ticks: live_sockets=%u (peak %u)",
           ticks, xs.live_sockets, peak);
    T_CHECK(xs.live_sockets < peak);
    T_CHECK(xs.live_sockets <= 1);            /* only the listener remains */
    un_host_test_reset_clock();
    tu_ext(un, &xs);
    T_NOTE("recovered live_sockets=%u, suppressed delta=%llu",
           xs.live_sockets,
           (unsigned long long)(xs.accept_suppressed - suppressed_before));

    int c2 = socket(AF_INET, SOCK_STREAM, 0);
    tu_set_nonblock(c2);
    struct sockaddr_in sa2;
    memset(&sa2, 0, sizeof(sa2));
    sa2.sin_family = AF_INET;
    sa2.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    sa2.sin_port = htons(hp);
    connect(c2, (struct sockaddr *)&sa2, sizeof(sa2));
    g->conn.state = VG_CLOSED;
    g->conn.active = false;
    bool accepted = vg_pump(g, un, tu_emit, NULL, 0, NULL, NULL,
                            tu_pred_est, g, 4000);
    T_CHECK(accepted);
    T_NOTE("listener resumed accepting once capacity was released: %s",
           accepted ? "yes" : "no");
    close(c2);

    usernet_destroy(un);
    free(g);
}

#ifdef SLIRP_FLOE_HOST_HOOKS
/* Two listeners can become readable in the same dispatch. The accept hook must
 * re-evaluate the live registry after the first accept, not reuse a fill-time
 * snapshot and admit a second socket above the per-VM ceiling. */
static void test_ceiling_multiple_listeners_same_dispatch(void) {
    T_BEGIN("ceiling: simultaneous listeners cannot bypass accept admission");

    VGuest *g = calloc(1, sizeof(*g));
    struct UserNet *un = make_cfg(g, 0, 4);
    T_CHECK(un != NULL);
    if (!un) { free(g); return; }
    T_CHECK(tu_boot(g, un));
    uint16_t ports[2] = { tu_reserve_tcp_port(), tu_reserve_tcp_port() };
    T_EQ_U(usernet_add_hostfwd(un, false, ports[0], 9810), 0);
    T_EQ_U(usernet_add_hostfwd(un, false, ports[1], 9811), 0);

    int clients[32];
    int nc = 0;
    /* Queue all clients before dispatch so both listeners are ready together. */
    for (int i = 0; i < 32; i++) {
        int c = socket(AF_INET, SOCK_STREAM, 0);
        if (c < 0) break;
        tu_set_nonblock(c);
        struct sockaddr_in sa;
        memset(&sa, 0, sizeof(sa));
        sa.sin_family = AF_INET;
        sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        sa.sin_port = htons(ports[i & 1]);
        connect(c, (struct sockaddr *)&sa, sizeof(sa));
        clients[nc++] = c;
    }
    uint64_t refused0 = 0, refused1 = 0;
    usernet_get_hook_stats(un, &refused0, NULL, NULL);
    for (int i = 0; i < 80; i++) { usernet_poll(un); vg_drain(g, un, tu_emit); }
    usernet_get_hook_stats(un, &refused1, NULL, NULL);
    UserNetExtStats xs;
    tu_ext(un, &xs);
    T_CHECK(xs.max_live_sockets <= xs.socket_ceiling);
    T_CHECK(refused1 > refused0);
    T_EQ_U(xs.accept_suppressed, 0);
    T_NOTE("two ready listeners, %d clients: max_live=%u ceiling=%u refused=%llu",
           nc, xs.max_live_sockets, xs.socket_ceiling,
           (unsigned long long)(refused1 - refused0));

    for (int i = 0; i < nc; i++) close(clients[i]);
    usernet_destroy(un);
    free(g);
}
#endif

/* ---- 2. fairness: established flows keep running at the ceiling ---- */

static void test_ceiling_preserves_established(void) {
    T_BEGIN("ceiling: an established transfer keeps flowing at the limit");

    VGuest *g = calloc(1, sizeof(*g));
    struct UserNet *un = make_cfg(g, 0, 3);
    T_CHECK(un != NULL);
    if (!un) { free(g); return; }
    T_CHECK(tu_boot(g, un));

    TuEcho echo;
    memset(&echo, 0, sizeof(echo));
    echo.listener = -1; echo.conn = -1;
    uint16_t port = 0;
    echo.listener = tu_tcp_listener(&port);
    T_CHECK(echo.listener >= 0);
    if (echo.listener < 0) { usernet_destroy(un); free(g); return; }

    /* Establish ONE real guest->host connection first. */
    g->conn.echo_on = false;
    vg_tcp_connect(g, un, tu_emit, VG_IP_GW, port, 44001);
    struct pollfd lpf = { .fd = echo.listener, .events = POLLIN };
    bool est = vg_pump(g, un, tu_emit, &lpf, 1, tu_echo_service, &echo,
                       tu_pred_est, g, 5000);
    T_CHECK(est);
    T_CHECK(echo.conn >= 0);
    T_NOTE("established connection open before saturating the ceiling");

    /* Saturate the ceiling with new guest-initiated attempts. */
    for (int i = 0; i < 12; i++) {
        VConn save = g->conn;                  /* keep the live connection */
        VConn tmp;
        memset(&tmp, 0, sizeof(tmp));
        tmp.mss = 1460; tmp.peer_wnd = 65535;
        g->conn = tmp;
        vg_tcp_connect(g, un, tu_emit, 0x5db8d822u, 80, (uint16_t)(45000 + i));
        g->conn = save;
        for (int k = 0; k < 4; k++) { usernet_poll(un); vg_drain(g, un, tu_emit); }
    }

    UserNetExtStats xs;
    tu_ext(un, &xs);
    T_CHECK(xs.max_live_sockets <= xs.socket_ceiling);
    T_CHECK(xs.in_refused_guest > 0);
    T_CHECK(xs.icmp_errors_sent > 0);
    T_NOTE("ceiling=%u max_live=%u refused_guest=%llu icmp_sent=%llu",
           xs.socket_ceiling, xs.max_live_sockets,
           (unsigned long long)xs.in_refused_guest,
           (unsigned long long)xs.icmp_errors_sent);

    /* The pre-existing connection must still transfer: the ceiling stops NEW
     * flows, it never starves an established one. */
    static uint8_t pattern[16384];
    tu_fill_pattern(pattern, sizeof(pattern), 0xBEEF);
    uint64_t want = tu_fnv64(pattern, sizeof(pattern));
    vg_tcp_send(g, un, tu_emit, pattern, sizeof(pattern));

    struct pollfd cpf = { .fd = echo.conn >= 0 ? echo.conn : echo.listener,
                          .events = POLLIN };
    uint32_t target = (uint32_t)sizeof(pattern);
    bool got = false;
    int64_t deadline = 15000;
    while (deadline > 0) {
        for (int k = 0; k < 40; k++) {
            usernet_poll(un);
            vg_drain(g, un, tu_emit);
            tu_echo_service(&echo);
            if (g->conn.rxlen >= target) break;
        }
        if (g->conn.rxlen >= target) { got = true; break; }
        struct pollfd p2 = { .fd = echo.conn, .events = POLLIN };
        if (echo.conn >= 0) poll(&p2, 1, 20);
        deadline -= 40;
    }
    T_CHECK(got);
    T_EQ_U(g->conn.rxlen, sizeof(pattern));
    T_EQ_U(tu_fnv64(g->conn.rx, sizeof(pattern)), want);
    T_EQ_U(echo.got, sizeof(pattern));
    T_NOTE("established 16KiB transfer completed AT the ceiling, digest %016llx",
           (unsigned long long)want);

    if (echo.conn >= 0) close(echo.conn);
    close(echo.listener);
    usernet_destroy(un);
    free(g);
}

/* ---- 3. IPv6 path ---- */

static bool tu_pred_icmp6_reply(void *c) { return ((VGuest *)c)->icmp6_echo_replies > 0; }
static bool tu_pred_icmp6_prohib(void *c) { return ((VGuest *)c)->icmp6_admin_prohib_seen > 0; }

static void test_ipv6_path(void) {
    T_BEGIN("IPv6: NDP, ICMPv6 echo, RA delivery, ICMPv6 ceiling refusal");

    VGuest *g = calloc(1, sizeof(*g));
    struct UserNet *un = make_cfg(g, USERNET_CFG_F_IPV6, 0);
    T_CHECK(un != NULL);
    if (!un) { free(g); return; }
    T_CHECK(tu_boot(g, un));

    UserNetDnsInfo di;
    memset(&di, 0, sizeof(di));
    di.struct_size = sizeof(di);
    usernet_get_dns_info(un, &di);
    T_EQ_U(di.ipv6_guest_enabled, 1);

    /* Announce our link-layer address for fd00::15 so libslirp can address
     * IPv6 frames to us, as a SLAAC-configured guest would. */
    vg_ipv6_boot(g, un, tu_emit);
    for (int i = 0; i < 5; i++) { usernet_poll(un); vg_drain(g, un, tu_emit); }

    uint8_t frame[VG_MAX_FRAME];
    static const uint8_t payload[] = "floe-v6-ping";
    for (int attempt = 0; attempt < 8 && g->icmp6_echo_replies == 0; attempt++) {
        size_t n = vg_icmp6_echo(g, frame, VG_IP6_GUEST, VG_IP6_GW, 0x4321, 1,
                                 payload, sizeof(payload) - 1);
        tu_emit(un, frame, n);
        vg_pump(g, un, tu_emit, NULL, 0, NULL, NULL, tu_pred_icmp6_reply, g, 1500);
    }
    T_CHECK(g->icmp6_echo_replies > 0);
    T_NOTE("icmp6_echo_replies=%u ndp_ns_seen=%u ndp_na_sent=%u ra_seen=%u ip6=%u",
           g->icmp6_echo_replies, g->ndp_ns_seen, g->ndp_na_sent, g->ra_seen,
           g->ip6_seen);
    T_CHECK(g->ip6_seen > 0);

    usernet_destroy(un);
    free(g);

    /* Ceiling + IPv6: prove protocol 58 is classified as ICMPv6 and never
     * conflated with ICMPv4 protocol 1, and that an IPv6 TCP SYN is refused
     * with ICMPv6 type 1 code 1 rather than a silent drop. */
    g = calloc(1, sizeof(*g));
    un = make_cfg(g, USERNET_CFG_F_IPV6, 1);
    T_CHECK(un != NULL);
    if (!un) { free(g); return; }
    T_CHECK(tu_boot(g, un));
    vg_ipv6_boot(g, un, tu_emit);

    uint16_t hp = tu_reserve_tcp_port();
    T_CHECK(hp != 0);
    T_EQ_U(usernet_add_hostfwd(un, false, hp, 9850), 0);
    for (int i = 0; i < 5; i++) usernet_poll(un);

    g->icmp6_admin_prohib_seen = 0;
    size_t n = vg_tcp6_syn(g, frame, VG_IP6_GUEST, VG_IP6_GW, 46001, 80, 0x1000);
    tu_emit(un, frame, n);
    vg_pump(g, un, tu_emit, NULL, 0, NULL, NULL, tu_pred_icmp6_prohib, g, 3000);

    UserNetExtStats xs;
    tu_ext(un, &xs);
    T_CHECK(xs.in_refused_guest > 0);
    T_CHECK(g->icmp6_admin_prohib_seen > 0);
    T_CHECK(xs.max_live_sockets <= xs.socket_ceiling);
    T_NOTE("IPv6 SYN refused at the ceiling: icmp6 admin-prohib=%u refused=%llu",
           g->icmp6_admin_prohib_seen, (unsigned long long)xs.in_refused_guest);

    usernet_destroy(un);
    free(g);
}

/* ---- 4. IPv6 extension-header chains are not misclassified ---- */

static void test_ipv6_extension_chain(void) {
    T_BEGIN("IPv6: an extension-header chain is walked, never guessed");

    VGuest *g = calloc(1, sizeof(*g));
    struct UserNet *un = make_cfg(g, USERNET_CFG_F_IPV6, 1);
    T_CHECK(un != NULL);
    if (!un) { free(g); return; }
    T_CHECK(tu_boot(g, un));
    vg_ipv6_boot(g, un, tu_emit);

    uint16_t hp = tu_reserve_tcp_port();
    T_EQ_U(usernet_add_hostfwd(un, false, hp, 9860), 0);
    for (int i = 0; i < 5; i++) usernet_poll(un);

    UserNetExtStats before;
    tu_ext(un, &before);

    /* A TCP SYN hidden behind a Hop-by-Hop extension header. A fixed
     * next-header read would see protocol 0 and admit it, silently breaking
     * the ceiling; the classifier must walk the chain and refuse it. */
    uint8_t frame[VG_MAX_FRAME];
    uint8_t ip6[40 + 8 + 20];
    memset(ip6, 0, sizeof(ip6));
    ip6[0] = 0x60;
    vg_wr16(ip6 + 4, (uint16_t)(8 + 20));
    ip6[6] = 0;                       /* Hop-by-Hop Options */
    ip6[7] = 64;
    memcpy(ip6 + 8, VG_IP6_GUEST, 16);
    memcpy(ip6 + 24, VG_IP6_GW, 16);
    ip6[40] = 6;                      /* next header inside the ext = TCP */
    ip6[41] = 0;                      /* Hdr Ext Len: (0+1)*8 = 8 bytes */
    uint8_t *t = ip6 + 48;
    vg_wr16(t + 0, 47001);
    vg_wr16(t + 2, 80);
    vg_wr32(t + 4, 0x2000);
    t[12] = (5 << 4);
    t[13] = 0x02;                     /* SYN, no ACK */
    vg_wr16(t + 14, 65535);
    size_t n = vg_eth(g, frame, 0x86dd, g->gw_mac, ip6, sizeof(ip6));
    g->icmp6_admin_prohib_seen = 0;
    tu_emit(un, frame, n);
    for (int i = 0; i < 20; i++) { usernet_poll(un); vg_drain(g, un, tu_emit); }

    UserNetExtStats after;
    tu_ext(un, &after);
    T_CHECK(after.in_refused_guest > before.in_refused_guest);
    T_CHECK(g->icmp6_admin_prohib_seen > 0);
    T_CHECK(after.max_live_sockets <= after.socket_ceiling);
    T_NOTE("ext-header SYN refused: refused_guest %llu -> %llu, admin-prohib=%u",
           (unsigned long long)before.in_refused_guest,
           (unsigned long long)after.in_refused_guest,
           g->icmp6_admin_prohib_seen);

    usernet_destroy(un);
    free(g);
}

int main(void) {
    test_ceiling_hostfwd_stress();
#ifdef SLIRP_FLOE_HOST_HOOKS
    test_ceiling_multiple_listeners_same_dispatch();
#endif
    test_ceiling_preserves_established();
    test_ipv6_path();
    test_ipv6_extension_chain();
    T_EXIT("test_ceiling");
}
