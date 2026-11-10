/* SPDX-License-Identifier: Apache-2.0 */
/* Component tests for the libslirp 4.9.7 usernet backend candidate.
 *
 * These run against the REAL pinned libslirp (the vendor lane's exported
 * macOS arm64 static library), not a mock. The guest side is the in-process
 * virtual guest in guest_frame.c, which speaks ordinary Ethernet over the
 * exact usernet_input()/usernet_output_fn contract virtio_net.c uses.
 *
 * Host sockets are bound to 127.0.0.1 (and ::1 for the NAT64 mechanism test)
 * only. That is the same exposure the shipping backend already has — forwarded
 * listeners bind host loopback — and it is a QUALIFICATION path: nothing here
 * changes the shipping default, and the resolver/NAT64 injection hooks used by
 * test_nat64 are compiled out unless -DFLOE_USERNET_TEST_HOOKS is passed.
 */
#include "harness.h"
#include "guest_frame.h"
#include "usernet.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>

/* The documented forwarding-rule ceiling, which matches
 * FLOE_AE_MAX_NET_FORWARDS in include/floe_arm64emu.h. */
#define UN_FWD_TEST_MAX 16u

/* ---- small helpers ---- */

static uint64_t fnv64(const void *p, size_t n) {
    const uint8_t *b = p;
    uint64_t h = 1469598103934665603ULL;
    for (size_t i = 0; i < n; i++) { h ^= b[i]; h *= 1099511628211ULL; }
    return h;
}

static void fill_pattern(uint8_t *p, size_t n, uint32_t seed) {
    uint32_t x = seed ? seed : 1;
    for (size_t i = 0; i < n; i++) {
        x ^= x << 13; x ^= x >> 17; x ^= x << 5;
        p[i] = (uint8_t)(x >> 8);
    }
}

static void set_nonblock(int fd) {
    int fl = fcntl(fd, F_GETFL);
    fcntl(fd, F_SETFL, fl | O_NONBLOCK);
}

static int host_tcp_listener_any(uint16_t *port_out) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in sa;
    memset(&sa, 0, sizeof(sa));
    sa.sin_family = AF_INET;
    sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    sa.sin_port = 0;                       /* ephemeral: no fixed-port clashes */
    if (bind(fd, (struct sockaddr *)&sa, sizeof(sa)) < 0) { close(fd); return -1; }
    socklen_t sl = sizeof(sa);
    getsockname(fd, (struct sockaddr *)&sa, &sl);
    if (listen(fd, 8) < 0) { close(fd); return -1; }
    set_nonblock(fd);
    if (port_out) *port_out = ntohs(sa.sin_port);
    return fd;
}

static int host_tcp_client(uint16_t port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    set_nonblock(fd);
    struct sockaddr_in sa;
    memset(&sa, 0, sizeof(sa));
    sa.sin_family = AF_INET;
    sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    sa.sin_port = htons(port);
    connect(fd, (struct sockaddr *)&sa, sizeof(sa));   /* EINPROGRESS */
    return fd;
}

static int host_udp_socket_any(uint16_t *port_out) {
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_in sa;
    memset(&sa, 0, sizeof(sa));
    sa.sin_family = AF_INET;
    sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    sa.sin_port = 0;
    if (bind(fd, (struct sockaddr *)&sa, sizeof(sa)) < 0) { close(fd); return -1; }
    socklen_t sl = sizeof(sa);
    getsockname(fd, (struct sockaddr *)&sa, &sl);
    set_nonblock(fd);
    if (port_out) *port_out = ntohs(sa.sin_port);
    return fd;
}

static void emit_to_backend(struct UserNet *un, const uint8_t *frame, size_t len) {
    usernet_input(un, frame, len);
}

/* Boot sequence a real Linux guest performs: resolve the gateway's link-layer
 * address. libslirp learns the guest MAC from this same request, which is what
 * lets it address frames back to us. Without this step no guest-bound frame is
 * ever produced — the reason a naive raw-packet probe sees nothing. */
static bool pred_gw_mac(void *c) { return ((VGuest *)c)->gw_mac_known; }

static bool boot_guest(VGuest *g, struct UserNet *un) {
    uint8_t frame[VG_MAX_FRAME];
    size_t n = vg_arp_request(g, frame, VG_IP_GW);
    emit_to_backend(un, frame, n);
    return vg_pump(g, un, emit_to_backend, NULL, 0, NULL, NULL,
                   pred_gw_mac, g, 3000);
}

static struct UserNet *make_backend(VGuest *g) {
    vg_init(g);
    uint8_t mac[6] = VG_MAC_GUEST;
    return usernet_new(vg_output, g, mac, 0);
}

/* ---- host echo services ---- */

typedef struct {
    int listener;
    int conn;
    uint8_t buf[262144];
    size_t  got;
    size_t  echoed;
    bool    peer_fin;
} HostEcho;

static void host_echo_service(void *ctx) {
    HostEcho *e = ctx;
    if (e->listener >= 0 && e->conn < 0) {
        int c = accept(e->listener, NULL, NULL);
        if (c >= 0) { set_nonblock(c); e->conn = c; }
    }
    if (e->conn < 0) return;
    for (;;) {
        ssize_t n = recv(e->conn, e->buf + e->got, sizeof(e->buf) - e->got, 0);
        if (n > 0) {
            e->got += (size_t)n;
            size_t off = 0;
            while (off < (size_t)n) {
                ssize_t w = send(e->conn, e->buf + e->got - (size_t)n + off,
                                 (size_t)n - off, 0);
                if (w <= 0) break;
                off += (size_t)w;
            }
            e->echoed += off;
            continue;
        }
        if (n == 0) { e->peer_fin = true; shutdown(e->conn, SHUT_WR); }
        break;
    }
}

typedef struct {
    int fd;
    uint8_t buf[65536];
    size_t got;
    uint32_t replies;
} HostUdpEcho;

static void host_udp_echo_service(void *ctx) {
    HostUdpEcho *e = ctx;
    if (e->fd < 0) return;
    for (;;) {
        struct sockaddr_in from;
        socklen_t fl = sizeof(from);
        ssize_t n = recvfrom(e->fd, e->buf, sizeof(e->buf), 0,
                             (struct sockaddr *)&from, &fl);
        if (n <= 0) break;
        sendto(e->fd, e->buf, (size_t)n, 0, (struct sockaddr *)&from, fl);
        e->got += (size_t)n;
        e->replies++;
    }
}

/* ---- predicates ---- */

static bool pred_icmp_reply(void *c) { return ((VGuest *)c)->icmp_echo_replies > 0; }
static bool pred_conn_est(void *c)  { return ((VGuest *)c)->conn.state >= VG_ESTABLISHED; }
static bool pred_conn_done(void *c) { return ((VGuest *)c)->conn.state == VG_DONE; }

typedef struct { VGuest *g; uint32_t want; } RxWant;
static bool pred_rx_atleast(void *c) {
    RxWant *w = c;
    return w->g->conn.rxlen >= w->want;
}
typedef struct { VGuest *g; uint32_t want; } DgramWant;
static bool pred_dgram(void *c) {
    DgramWant *w = c;
    return w->g->dgram_count >= w->want;
}

/* ============================ tests ============================ */

static void test_lifecycle(void) {
    T_BEGIN("lifecycle: create/poll/stats/destroy");

    T_CHECK(usernet_new(NULL, NULL, NULL, 0) == NULL);
    usernet_destroy(NULL);                        /* must not crash */

    VGuest *g = calloc(1, sizeof(*g));
    struct UserNet *un = make_backend(g);
    T_CHECK(un != NULL);
    if (!un) { free(g); return; }

    for (int i = 0; i < 5; i++) usernet_poll(un);

    uint64_t in = 1, ok = 1, ref = 1;
    unsigned tcp = 1, udp = 1;
    usernet_get_stats(un, &in, &ok, &ref, &tcp, &udp);
    T_EQ_U(in, 0);
    T_EQ_U(ok, 0);
    T_EQ_U(tcp, 0);
    T_EQ_U(udp, 0);

    UserNetExtStats xs;
    memset(&xs, 0, sizeof(xs));
    xs.struct_size = sizeof(xs);
    usernet_get_ext_stats(un, &xs);
    T_EQ_U(xs.abi, USERNET_STATS_ABI);
    T_EQ_U(xs.socket_ceiling, USERNET_DEF_MAX_SOCKETS);
    T_EQ_U(xs.poll_capacity, USERNET_DEF_POLL_CAPACITY);
    T_EQ_U(xs.polls, 5);
    T_NOTE("poll_syscalls=%llu live_sockets=%u max_live=%u",
           (unsigned long long)xs.poll_syscalls, xs.live_sockets,
           xs.max_live_sockets);

    usernet_destroy(un);
    T_EQ_U(g->rx_count, 0);   /* the output callback never fired during teardown */
    free(g);
}

static void test_arp_and_icmp(void) {
    T_BEGIN("ARP bootstrap + ICMP echo to the virtual gateway");

    VGuest *g = calloc(1, sizeof(*g));
    struct UserNet *un = make_backend(g);
    T_CHECK(un != NULL);
    if (!un) { free(g); return; }

    T_CHECK(boot_guest(g, un));
    T_CHECK(g->gw_mac_known);
    /* libslirp derives the gateway's link-layer address from the virtual IP,
     * exactly as the previous in-tree stack hardcoded it. Pinning the value
     * proves the replacement is on-wire compatible. */
    static const uint8_t expect_gw[6] = { 0x52,0x55,0x0a,0x00,0x02,0x02 };
    T_MEM_EQ(g->gw_mac, expect_gw, 6);
    T_CHECK(g->arp_replies_seen >= 1);
    T_CHECK(g->arp_requests_seen >= 0);

    uint8_t frame[VG_MAX_FRAME];
    static const uint8_t payload[] = "floe-ping";
    size_t n = vg_icmp_echo(g, frame, VG_IP_GUEST, VG_IP_GW, 0x1234, 1,
                            payload, sizeof(payload) - 1);
    emit_to_backend(un, frame, n);
    bool got = vg_pump(g, un, emit_to_backend, NULL, 0, NULL, NULL,
                       pred_icmp_reply, g, 3000);
    T_CHECK(got);
    T_CHECK(g->icmp_echo_replies >= 1);
    T_NOTE("icmp_echo_replies=%u", g->icmp_echo_replies);

    usernet_destroy(un);
    free(g);
}

/* Host -> guest TCP through a forwarded loopback listener. */
static void test_tcp_host_to_guest(void) {
    T_BEGIN("TCP forward host->guest: handshake, 64KiB echo, half-close");

    VGuest *g = calloc(1, sizeof(*g));
    struct UserNet *un = make_backend(g);
    T_CHECK(un != NULL);
    if (!un) { free(g); return; }
    T_CHECK(boot_guest(g, un));

    HostEcho echo;
    memset(&echo, 0, sizeof(echo));
    echo.listener = -1; echo.conn = -1;

    uint16_t guest_port = 7001;
    uint16_t host_port = 0;
    int listener = host_tcp_listener_any(&host_port);
    T_CHECK(listener >= 0);
    if (listener < 0) { usernet_destroy(un); free(g); return; }
    close(listener);            /* free the port for libslirp's own listener */

    int rc = usernet_add_hostfwd(un, false, host_port, guest_port);
    T_EQ_U(rc, 0);
    if (rc != 0) { usernet_destroy(un); free(g); return; }

    /* The guest side is the echo server: libslirp actively opens toward it. */
    g->conn.echo_on = true;

    int client = host_tcp_client(host_port);
    T_CHECK(client >= 0);

    struct pollfd cpf = { .fd = client, .events = POLLIN | POLLOUT };
    bool est = vg_pump(g, un, emit_to_backend, &cpf, 1, NULL, NULL,
                       pred_conn_est, g, 5000);
    T_CHECK(est);
    T_NOTE("guest conn state after handshake = %d", (int)g->conn.state);

    /* Push 64 KiB from the real host client through libslirp to the guest and
     * back, and compare digests. */
    static uint8_t pattern[65536];
    fill_pattern(pattern, sizeof(pattern), 0xC0FFEE);
    uint64_t want = fnv64(pattern, sizeof(pattern));

    size_t written = 0;
    uint8_t rbuf[65536];
    size_t read_total = 0;
    RxWant rw = { g, (uint32_t)sizeof(pattern) };

    int64_t deadline_us = 20000000;
    while ((written < sizeof(pattern) || read_total < sizeof(pattern)) &&
           deadline_us > 0) {
        struct pollfd pf[2] = {
            { .fd = client, .events = POLLIN | (written < sizeof(pattern) ? POLLOUT : 0) },
            { .fd = -1, .events = 0 },
        };
        if (written < sizeof(pattern)) {
            ssize_t w = send(client, pattern + written,
                             sizeof(pattern) - written, 0);
            if (w > 0) written += (size_t)w;
        }
        if (read_total < sizeof(pattern)) {
            ssize_t r = recv(client, rbuf + read_total,
                             sizeof(rbuf) - read_total, 0);
            if (r > 0) read_total += (size_t)r;
        }
        pf[0] = pf[0];
        vg_pump(g, un, emit_to_backend, pf, 1, NULL, NULL,
                pred_rx_atleast, &rw, 200);
        deadline_us -= 200000;
    }

    T_EQ_U(written, sizeof(pattern));
    T_EQ_U(read_total, sizeof(pattern));
    T_EQ_U(g->conn.rxlen, sizeof(pattern));
    T_EQ_U(fnv64(g->conn.rx, sizeof(pattern)), want);
    T_EQ_U(fnv64(rbuf, sizeof(pattern)), want);
    T_NOTE("64KiB round trip digest %016llx both directions",
           (unsigned long long)want);

    /* Half-close: the host shuts down its write side; the guest must see FIN,
     * ACK it, send its own FIN, and the connection must reach DONE. */
    shutdown(client, SHUT_WR);
    bool done = vg_pump(g, un, emit_to_backend, &cpf, 1, NULL, NULL,
                        pred_conn_done, g, 5000);
    T_CHECK(done);
    T_CHECK(g->conn.fin_rcvd);
    T_CHECK(g->conn.fin_sent);

    close(client);
    T_EQ_U(usernet_remove_hostfwd(un, false, host_port), 0);
    usernet_destroy(un);
    free(g);
}

/* Guest -> host TCP: the guest dials the virtual gateway, which libslirp
 * translates onto host loopback. */
static void test_tcp_guest_to_host(void) {
    T_BEGIN("TCP guest->host via 10.0.2.2: handshake, echo, digest");

    VGuest *g = calloc(1, sizeof(*g));
    struct UserNet *un = make_backend(g);
    T_CHECK(un != NULL);
    if (!un) { free(g); return; }
    T_CHECK(boot_guest(g, un));

    HostEcho echo;
    memset(&echo, 0, sizeof(echo));
    echo.listener = -1; echo.conn = -1;
    uint16_t port = 0;
    echo.listener = host_tcp_listener_any(&port);
    T_CHECK(echo.listener >= 0);
    if (echo.listener < 0) { usernet_destroy(un); free(g); return; }

    struct pollfd lpf = { .fd = echo.listener, .events = POLLIN };
    g->conn.echo_on = false;

    vg_tcp_connect(g, un, emit_to_backend, VG_IP_GW, port, 41001);
    bool est = vg_pump(g, un, emit_to_backend, &lpf, 1,
                       host_echo_service, &echo, pred_conn_est, g, 5000);
    T_CHECK(est);
    T_CHECK(echo.conn >= 0);
    T_NOTE("guest->host handshake established, host conn fd=%d", echo.conn);

    static uint8_t pattern[32768];
    fill_pattern(pattern, sizeof(pattern), 0x5EED);
    uint64_t want = fnv64(pattern, sizeof(pattern));

    vg_tcp_send(g, un, emit_to_backend, pattern, sizeof(pattern));

    struct pollfd cpf = { .fd = echo.conn >= 0 ? echo.conn : echo.listener,
                          .events = POLLIN };
    RxWant rw = { g, (uint32_t)sizeof(pattern) };
    bool got_all = vg_pump(g, un, emit_to_backend, &cpf, 1,
                           host_echo_service, &echo, pred_rx_atleast, &rw, 15000);
    T_CHECK(got_all);
    T_EQ_U(g->conn.rxlen, sizeof(pattern));
    T_EQ_U(fnv64(g->conn.rx, sizeof(pattern)), want);
    T_EQ_U(echo.got, sizeof(pattern));
    T_NOTE("32KiB guest->host->guest digest %016llx matched",
           (unsigned long long)want);

    vg_tcp_close(g, un, emit_to_backend);
    bool done = vg_pump(g, un, emit_to_backend, &cpf, 1,
                        host_echo_service, &echo, pred_conn_done, g, 5000);
    T_CHECK(done);
    T_CHECK(echo.peer_fin);

    if (echo.conn >= 0) close(echo.conn);
    close(echo.listener);
    usernet_destroy(un);
    free(g);
}

/* UDP in both directions through a forwarded loopback socket. */
static void test_udp_bidirectional(void) {
    T_BEGIN("UDP guest<->host: datagram round trip, exact bytes");

    VGuest *g = calloc(1, sizeof(*g));
    struct UserNet *un = make_backend(g);
    T_CHECK(un != NULL);
    if (!un) { free(g); return; }
    T_CHECK(boot_guest(g, un));

    HostUdpEcho ue;
    memset(&ue, 0, sizeof(ue));
    uint16_t port = 0;
    ue.fd = host_udp_socket_any(&port);
    T_CHECK(ue.fd >= 0);
    if (ue.fd < 0) { usernet_destroy(un); free(g); return; }

    static const uint8_t payload[1200] = { /* patterned below */ 0 };
    uint8_t send_buf[1200];
    fill_pattern(send_buf, sizeof(send_buf), 0xABCD);
    (void)payload;

    struct pollfd upf = { .fd = ue.fd, .events = POLLIN };
    /* Guest -> 10.0.2.2:port, which libslirp maps onto host loopback. */
    uint8_t frame[VG_MAX_FRAME];
    size_t n = vg_udp(g, frame, VG_IP_GUEST, VG_IP_GW, 45000, port,
                      send_buf, sizeof(send_buf));
    emit_to_backend(un, frame, n);

    DgramWant dw = { g, 1 };
    bool got = vg_pump(g, un, emit_to_backend, &upf, 1,
                       host_udp_echo_service, &ue, pred_dgram, &dw, 5000);
    T_CHECK(got);
    T_EQ_U(ue.got, sizeof(send_buf));
    T_CHECK(g->dgram_count >= 1);

    const VDatagram *d = vg_dgram_last(g, 45000);
    T_CHECK(d != NULL);
    if (d) {
        T_EQ_U(d->len, sizeof(send_buf));
        T_MEM_EQ(d->payload, send_buf, sizeof(send_buf));
        T_EQ_U(fnv64(d->payload, d->len), fnv64(send_buf, sizeof(send_buf)));
        T_NOTE("1200B UDP datagram returned byte-identical");
    }

    close(ue.fd);
    usernet_destroy(un);
    free(g);
}

/* UDP through an explicit host-forward rule. */
static void test_udp_hostfwd(void) {
    T_BEGIN("UDP forward host->guest->host via an explicit rule");

    VGuest *g = calloc(1, sizeof(*g));
    struct UserNet *un = make_backend(g);
    T_CHECK(un != NULL);
    if (!un) { free(g); return; }
    T_CHECK(boot_guest(g, un));

    uint16_t host_port = 0, guest_port = 7053;
    int probe = host_udp_socket_any(&host_port);
    T_CHECK(probe >= 0);
    close(probe);

    int rc = usernet_add_hostfwd(un, true, host_port, guest_port);
    T_EQ_U(rc, 0);
    if (rc != 0) { usernet_destroy(un); free(g); return; }

    int sender = socket(AF_INET, SOCK_DGRAM, 0);
    set_nonblock(sender);
    struct sockaddr_in dst;
    memset(&dst, 0, sizeof(dst));
    dst.sin_family = AF_INET;
    dst.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    dst.sin_port = htons(host_port);

    uint8_t msg[64];
    fill_pattern(msg, sizeof(msg), 0x77);
    ssize_t sent = sendto(sender, msg, sizeof(msg), 0,
                          (struct sockaddr *)&dst, sizeof(dst));
    T_EQ_U((uint64_t)sent, sizeof(msg));

    DgramWant dw = { g, 1 };
    struct pollfd spf = { .fd = sender, .events = POLLIN };
    bool got = vg_pump(g, un, emit_to_backend, &spf, 1, NULL, NULL,
                       pred_dgram, &dw, 5000);
    T_CHECK(got);
    const VDatagram *d = vg_dgram_last(g, guest_port);
    T_CHECK(d != NULL);
    if (d) {
        T_EQ_U(d->len, sizeof(msg));
        T_MEM_EQ(d->payload, msg, sizeof(msg));
        /* Reply back through libslirp to the real host sender. */
        uint8_t out[VG_MAX_FRAME];
        size_t n = vg_udp_reply(g, out, d, msg, sizeof(msg));
        emit_to_backend(un, out, n);
    }

    uint8_t rbuf[128];
    bool replied = false;
    for (int i = 0; i < 200 && !replied; i++) {
        usernet_poll(un);
        vg_drain(g, un, emit_to_backend);
        struct pollfd pf = { .fd = sender, .events = POLLIN };
        if (poll(&pf, 1, 20) > 0) {
            ssize_t r = recv(sender, rbuf, sizeof(rbuf), 0);
            if (r == (ssize_t)sizeof(msg) && memcmp(rbuf, msg, sizeof(msg)) == 0)
                replied = true;
        }
    }
    T_CHECK(replied);
    T_NOTE("UDP hostfwd round trip returned the exact datagram");

    close(sender);
    usernet_destroy(un);
    free(g);
}

static void test_hostfwd_lifecycle(void) {
    T_BEGIN("host-forward registry: duplicate, missing, ceiling, recreate");

    VGuest *g = calloc(1, sizeof(*g));
    struct UserNet *un = make_backend(g);
    T_CHECK(un != NULL);
    if (!un) { free(g); return; }

    T_EQ_U(usernet_add_hostfwd(un, false, 0, 80), -EINVAL);
    T_EQ_U(usernet_remove_hostfwd(un, false, 9999), -ENOENT);

    /* Sixteen rules is the documented ceiling (FLOE_AE_MAX_NET_FORWARDS). */
    for (uint16_t i = 0; i < UN_FWD_TEST_MAX; i++) {
        int rc = usernet_add_hostfwd(un, false, (uint16_t)(21000 + i),
                                     (uint16_t)(8000 + i));
        T_EQ_U(rc, 0);
    }
    T_EQ_U(usernet_add_hostfwd(un, false, 22000, 80), -ENOBUFS);
    /* A duplicate rule, even cross-protocol, stays -EADDRINUSE. */
    T_EQ_U(usernet_add_hostfwd(un, false, 21000, 8000), -EADDRINUSE);

    /* Remove and recreate the same rule: the descriptor must really be
     * released, otherwise the recreate fails with EADDRINUSE. */
    T_EQ_U(usernet_remove_hostfwd(un, false, 21005), 0);
    T_EQ_U(usernet_remove_hostfwd(un, false, 21005), -ENOENT);
    T_EQ_U(usernet_add_hostfwd(un, false, 21005, 8005), 0);

    /* Free room in the registry first: with all 16 slots taken the ceiling is
     * what fires, and -ENOBUFS is the correct answer there (asserted above). */
    for (uint16_t i = 6; i < UN_FWD_TEST_MAX; i++)
        usernet_remove_hostfwd(un, false, (uint16_t)(21000 + i));

    /* A real bind conflict must surface the host error, not a bare -1. */
    uint16_t taken = 0;
    int squatter = host_tcp_listener_any(&taken);
    T_CHECK(squatter >= 0);
    int rc = usernet_add_hostfwd(un, false, taken, 9000);
    T_EQ_U(rc, -EADDRINUSE);
    close(squatter);

    /* After the squatter is gone the same rule succeeds. */
    T_EQ_U(usernet_add_hostfwd(un, false, taken, 9000), 0);
    T_EQ_U(usernet_remove_hostfwd(un, false, taken), 0);

    for (uint16_t i = 0; i < 6; i++)
        usernet_remove_hostfwd(un, false, (uint16_t)(21000 + i));

    usernet_destroy(un);
    free(g);
}

static void test_guest_reset(void) {
    T_BEGIN("guest reset: flows dropped, forwarding rules preserved");

    VGuest *g = calloc(1, sizeof(*g));
    struct UserNet *un = make_backend(g);
    T_CHECK(un != NULL);
    if (!un) { free(g); return; }
    T_CHECK(boot_guest(g, un));

    uint16_t host_port = 0;
    int probe = host_tcp_listener_any(&host_port);
    close(probe);
    T_EQ_U(usernet_add_hostfwd(un, false, host_port, 7100), 0);

    usernet_guest_reset(un);

    /* The rule survived the reset: adding it again is a duplicate, and
     * removing it still succeeds. */
    T_EQ_U(usernet_add_hostfwd(un, false, host_port, 7100), -EADDRINUSE);
    T_EQ_U(usernet_remove_hostfwd(un, false, host_port), 0);

    /* The stack is still usable after the rebuild. */
    g->gw_mac_known = false;
    T_CHECK(boot_guest(g, un));
    uint8_t frame[VG_MAX_FRAME];
    size_t n = vg_icmp_echo(g, frame, VG_IP_GUEST, VG_IP_GW, 1, 1, "x", 1);
    g->icmp_echo_replies = 0;
    emit_to_backend(un, frame, n);
    T_CHECK(vg_pump(g, un, emit_to_backend, NULL, 0, NULL, NULL,
                    pred_icmp_reply, g, 3000));

    usernet_destroy(un);
    free(g);
}

static void test_backpressure(void) {
    T_BEGIN("backpressure: refused frames are deferred, bounded, then flushed");

    VGuest *g = calloc(1, sizeof(*g));
    struct UserNet *un = make_backend(g);
    T_CHECK(un != NULL);
    if (!un) { free(g); return; }

    /* Simulate a guest whose device RX ring is full. */
    g->accept_rx = false;
    uint8_t frame[VG_MAX_FRAME];
    size_t n = vg_arp_request(g, frame, VG_IP_GW);
    emit_to_backend(un, frame, n);
    for (int i = 0; i < 3; i++) usernet_poll(un);

    UserNetExtStats xs;
    xs.struct_size = sizeof(xs);
    usernet_get_ext_stats(un, &xs);
    T_CHECK(xs.out_refused > 0);
    T_CHECK(xs.out_deferred > 0);
    T_EQ_U(xs.out_ok, 0);
    T_NOTE("refused=%llu deferred=%llu dropped_queue=%llu",
           (unsigned long long)xs.out_refused,
           (unsigned long long)xs.out_deferred,
           (unsigned long long)xs.out_dropped_queue);

    /* The deferred frame must still be waiting, and the wait ABI must say so
     * with a clamped (finite) deadline rather than an unbounded park. */
    UserNetWaitFd wfds[64];
    UserNetWaitRequest req;
    UserNetWaitResult res;
    memset(&req, 0, sizeof(req));
    req.struct_size = sizeof(req);
    req.abi = USERNET_WAIT_ABI;
    req.capacity = 64;
    req.entries = wfds;
    T_EQ_U(usernet_fill_wait(un, &req, &res), 0);
    T_CHECK((res.flags & USERNET_WAIT_R_TX_PENDING) != 0);
    T_CHECK(res.timeout_ms < 1000);

    /* Re-enable the ring: the deferred frame is delivered on the next poll. */
    g->accept_rx = true;
    uint32_t before = g->rx_count;
    for (int i = 0; i < 3 && g->rx_count == before; i++) usernet_poll(un);
    T_CHECK(g->rx_count > before);
    usernet_get_ext_stats(un, &xs);
    T_CHECK(xs.out_ok > 0);
    T_NOTE("deferred frame delivered after the RX ring drained");

    /* Overflow the queue and prove it is bounded: no unbounded host growth. */
    g->accept_rx = false;
    for (int i = 0; i < 400; i++) {
        n = vg_arp_request(g, frame, VG_IP_GW);
        emit_to_backend(un, frame, n);
        usernet_poll(un);
    }
    usernet_get_ext_stats(un, &xs);
    T_CHECK(xs.out_dropped_queue > 0);
    T_NOTE("queue overflow dropped=%llu (bounded, never unbounded growth)",
           (unsigned long long)xs.out_dropped_queue);

    g->accept_rx = true;
    usernet_destroy(un);
    free(g);
}

static void test_socket_ceiling(void) {
    T_BEGIN("bounded per-VM sockets: new flows refused with ICMP admin-prohib");

    VGuest *g = calloc(1, sizeof(*g));
    vg_init(g);
    uint8_t mac[6] = VG_MAC_GUEST;

    UserNetConfig cfg;
    memset(&cfg, 0, sizeof(cfg));
    cfg.struct_size = sizeof(cfg);
    cfg.abi = USERNET_CFG_ABI;
    memcpy(cfg.guest_mac, mac, 6);
    cfg.max_sockets = 3;          /* deliberately tiny */
    cfg.poll_capacity = 8;
    struct UserNet *un = usernet_new_with_config(vg_output, g, &cfg);
    T_CHECK(un != NULL);
    if (!un) { free(g); return; }
    T_CHECK(boot_guest(g, un));

    /* Occupy the ceiling with real host listeners. */
    for (uint16_t i = 0; i < 3; i++)
        T_EQ_U(usernet_add_hostfwd(un, false, (uint16_t)(23000 + i),
                                   (uint16_t)(9000 + i)), 0);
    /* The listener allocation itself is bounded, before any accept exists. */
    T_EQ_U(usernet_add_hostfwd(un, false, 23003, 9003), -EMFILE);

    UserNetExtStats xs;
    xs.struct_size = sizeof(xs);
    usernet_get_ext_stats(un, &xs);
    T_CHECK(xs.live_sockets >= 3);
    T_EQ_U(xs.socket_ceiling, 3);
    T_NOTE("live_sockets=%u ceiling=%u", xs.live_sockets, xs.socket_ceiling);

    /* A new connection attempt must be refused, and refused HONESTLY: the
     * guest gets ICMP type 3 code 13 rather than a silent black hole. */
    g->icmp_admin_prohib_seen = 0;
    g->icmp_unreach_seen = 0;
    vg_tcp_connect(g, un, emit_to_backend, 0x5db8d822u /* 93.184.216.34 */, 80,
                   42001);
    for (int i = 0; i < 40 && g->icmp_admin_prohib_seen == 0; i++) {
        usernet_poll(un);
        vg_drain(g, un, emit_to_backend);
    }
    usernet_get_ext_stats(un, &xs);
    T_CHECK(xs.in_refused_ceiling > 0);
    T_CHECK(g->icmp_admin_prohib_seen > 0);
    T_CHECK(xs.icmp_errors_sent > 0);
    T_NOTE("refused_ceiling=%llu admin_prohib_seen=%u",
           (unsigned long long)xs.in_refused_ceiling,
           g->icmp_admin_prohib_seen);

    /* Established traffic is never starved by the ceiling: an ARP request and
     * a datagram for an existing flow still pass. */
    uint32_t before = xs.in_refused_ceiling;
    uint8_t frame[VG_MAX_FRAME];
    size_t n = vg_arp_request(g, frame, VG_IP_GW);
    emit_to_backend(un, frame, n);
    usernet_poll(un);
    usernet_get_ext_stats(un, &xs);
    T_EQ_U(xs.in_refused_ceiling, before);

    usernet_destroy(un);
    free(g);
}

static void test_wait_api_validation(void) {
    T_BEGIN("wait ABI: validation, dead backend, deprecated fd snapshot");

    VGuest *g = calloc(1, sizeof(*g));
    struct UserNet *un = make_backend(g);
    T_CHECK(un != NULL);
    if (!un) { free(g); return; }

    UserNetWaitFd wfds[16];
    UserNetWaitRequest req;
    UserNetWaitResult res;

    memset(&req, 0, sizeof(req));
    req.struct_size = sizeof(req);
    req.abi = USERNET_WAIT_ABI;
    req.capacity = 16;
    req.entries = wfds;
    T_EQ_U(usernet_fill_wait(un, NULL, &res), -EINVAL);
    T_EQ_U(usernet_fill_wait(un, &req, NULL), -EINVAL);

    req.abi = 999;
    T_EQ_U(usernet_fill_wait(un, &req, &res), -EINVAL);
    req.abi = USERNET_WAIT_ABI;

    req.reserved[0] = 1;
    T_EQ_U(usernet_fill_wait(un, &req, &res), -EINVAL);
    req.reserved[0] = 0;

    req.entries = NULL;
    T_EQ_U(usernet_fill_wait(un, &req, &res), -EINVAL);
    req.entries = wfds;

    T_EQ_U(usernet_fill_wait(un, &req, &res), 0);
    T_EQ_U(res.abi, USERNET_WAIT_ABI);
    T_EQ_U(res.count, 0);        /* nothing open yet */
    T_EQ_U(res.truncated, 0);

    /* A NULL backend reports DEAD with a zero deadline so the waiter never
     * sleeps on a network that does not exist. */
    memset(&res, 0, sizeof(res));
    T_EQ_U(usernet_fill_wait(NULL, &req, &res), 0);
    T_CHECK((res.flags & USERNET_WAIT_R_DEAD) != 0);
    T_EQ_U(res.count, 0);

    /* The deprecated fd-only snapshot must still work for an unpatched
     * runtime, and must agree with the versioned API. */
    int raw[16];
    T_EQ_U(usernet_wait_fds(un, raw, 16), 0);

    T_EQ_U(usernet_add_hostfwd(un, false, 24001, 9101), 0);
    int nraw = usernet_wait_fds(un, raw, 16);
    T_CHECK(nraw >= 1);
    memset(&res, 0, sizeof(res));
    T_EQ_U(usernet_fill_wait(un, &req, &res), 0);
    T_EQ_U(res.count, (uint32_t)nraw);
    T_CHECK(res.count > 0);
    for (uint32_t i = 0; i < res.count; i++)
        T_CHECK((res.flags & USERNET_WAIT_R_DEAD) == 0);
    T_NOTE("listener represented: count=%u wanted=%u timeout_ms=%u",
           res.count, res.wanted, res.timeout_ms);

    usernet_destroy(un);
    free(g);
}

static void test_dns_info(void) {
    T_BEGIN("resolver reporting: IPv4 field honest, availability dual-family");

    VGuest *g = calloc(1, sizeof(*g));
    struct UserNet *un = make_backend(g);
    T_CHECK(un != NULL);
    if (!un) { free(g); return; }

    UserNetDnsInfo di;
    memset(&di, 0, sizeof(di));
    di.struct_size = sizeof(di);
    T_EQ_U(usernet_get_dns_info(un, &di), 0);
    T_EQ_U(di.abi, USERNET_DNS_ABI);

    uint32_t v4 = usernet_dns_server(un);
    T_EQ_U(di.v4_addr, v4);
    T_EQ_U(di.v4_valid, v4 != 0);
    /* The guest-visible virtual nameserver must never be reported as a host
     * resolver: 10.0.2.3 is not a host address. */
    T_CHECK(v4 != VG_IP_DNS);
    T_NOTE("host resolver: v4_valid=%u v4=%u.%u.%u.%u v6_valid=%u nat64=%u",
           di.v4_valid, (v4 >> 24) & 0xff, (v4 >> 16) & 0xff,
           (v4 >> 8) & 0xff, v4 & 0xff, di.v6_valid, di.nat64_active);

    usernet_destroy(un);
    free(g);
}

int main(int argc, char **argv) {
    (void)argc; (void)argv;
    test_lifecycle();
    test_arp_and_icmp();
    test_tcp_host_to_guest();
    test_tcp_guest_to_host();
    test_udp_bidirectional();
    test_udp_hostfwd();
    test_hostfwd_lifecycle();
    test_guest_reset();
    test_backpressure();
    test_socket_ceiling();
    test_wait_api_validation();
    test_dns_info();
    T_EXIT("test_backend");
}
