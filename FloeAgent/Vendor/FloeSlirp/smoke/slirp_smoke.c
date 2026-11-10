/* SPDX-License-Identifier: BSD-3-Clause
 *
 * Floe libslirp vendor-candidate smoke test (self-written, small).
 * Modeled on libslirp's own test/pingtest.c (BSD-3-Clause).
 *
 * Proves on the actual built library:
 *   1. slirp_new() with SlirpConfig v6 succeeds (tftp_path NULL => TFTP host
 *      directory service disabled; enable_emu=false).
 *   2. Guest->vhost (10.0.2.2) TCP SYN is translated by libslirp to a real
 *      host loopback connect (sotranslate_out4): an in-process listener on
 *      127.0.0.1 accepts, and libslirp relays the SYN+ACK back to the guest
 *      as an Ethernet frame through the send_packet callback.
 *   3. The poll/timer callback contract works: slirp_pollfds_fill_socket,
 *      poll(), slirp_pollfds_poll, slirp_handle_timer all drive the session.
 *   4. In this hardened build slirp_add_exec() must FAIL (host process
 *      execution is compiled out) — returning 0 here would be a test error.
 *   5. slirp_cleanup() completes.
 *
 * Exit 0 = all checks passed. No VM, no TAP/VPN, no device.
 */
#include <assert.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <arpa/inet.h>
#include <netinet/in.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>

#include <slirp/libslirp.h>

#define TICK 100 /* ms of virtual time per idle poll */
static int max_ticks = 600; /* override via SLIRP_SMOKE_TICKS for diagnosis */
#define GUEST_IP 0x0a00020e /* 10.0.2.14 */
#define VHOST_IP 0x0a000202 /* 10.0.2.2  */

static Slirp *slirp;
static int done_synack;
static int64_t mytime_ns;

/* Reply to slirp's ARP requests from the guest side (like libslirp's pingtest).
 * Request layout (frame offsets): 22-27 sender mac, 28-31 sender ip,
 * 32-37 target mac, 38-41 target ip. */
static void handle_arp_request(const uint8_t *data, size_t len)
{
    if (len < 42)
        return;
    if (!(data[20] == 0x00 && data[21] == 0x01)) /* ARP request */
        return;
    uint8_t reply[42];
    memset(reply, 0, sizeof(reply));
    memcpy(&reply[0], &data[6], 6);     /* dst = slirp mac (request sender) */
    memcpy(&reply[6], "\x52\x55\x0a\x00\x02\x0e", 6); /* src = guest mac */
    reply[12] = 0x08; reply[13] = 0x06;
    reply[14] = 0x00; reply[15] = 0x01; /* htype ethernet */
    reply[16] = 0x08; reply[17] = 0x00; /* ptype IPv4 */
    reply[18] = 0x06; reply[19] = 0x04;
    reply[20] = 0x00; reply[21] = 0x02; /* ARP reply */
    memcpy(&reply[22], "\x52\x55\x0a\x00\x02\x0e", 6); /* sender mac = guest */
    memcpy(&reply[28], &data[38], 4);   /* sender ip = request target ip */
    memcpy(&reply[32], &data[6], 6);    /* target mac = slirp mac */
    memcpy(&reply[38], &data[28], 4);   /* target ip = request sender ip */
    slirp_input(slirp, reply, sizeof(reply));
    printf("event: answered slirp ARP request\n");
}

static slirp_ssize_t send_packet(const void *buf, size_t len, void *opaque)
{
    const uint8_t *data = buf;
    (void)opaque;

    if (len >= 14 && data[12] == 0x08 && data[13] == 0x06) {
        handle_arp_request(data, len);
        return len;
    }
    if (len < 14 || data[12] != 0x08 || data[13] != 0x00)
        return len; /* ignore non-IPv4 */
    if (len < 14 + 20 + 20)
        return len;
    if (data[23] != 0x06) /* proto != TCP */
        return len;

    /* IPv4 header check: version/ihl */
    if (data[14] != 0x45)
        return len;

    const uint8_t *th = data + 14 + 20;
    uint8_t flags = th[13];
    if ((flags & 0x12) == 0x12) { /* SYN|ACK */
        uint32_t src = (data[26] << 24) | (data[27] << 16) | (data[28] << 8) | data[29];
        printf("event: guest received TCP SYN+ACK from %u.%u.%u.%u\n",
               (src >> 24) & 0xff, (src >> 16) & 0xff, (src >> 8) & 0xff, src & 0xff);
        if (src == VHOST_IP)
            done_synack = 1;
    }
    return len;
}

static void guest_error(const char *msg, void *opaque)
{
    (void)opaque;
    printf("event: guest_error: %s\n", msg);
}

static int64_t clock_get_ns(void *opaque)
{
    (void)opaque;
    return mytime_ns;
}

struct timer {
    SlirpTimerId id;
    void *cb_opaque;
    int64_t expire_ns;
    struct timer *next;
};
static struct timer *timer_queue;

static void *timer_new_opaque(SlirpTimerId id, void *cb_opaque, void *opaque)
{
    (void)opaque;
    struct timer *t = calloc(1, sizeof(*t));
    t->id = id;
    t->cb_opaque = cb_opaque;
    return t;
}

static void timer_free(void *_timer, void *opaque)
{
    (void)opaque;
    struct timer *timer = _timer, **tp;
    for (tp = &timer_queue; *tp; tp = &(*tp)->next) {
        if (*tp == timer) {
            *tp = timer->next;
            break;
        }
    }
    free(timer);
}

static void timer_mod(void *_timer, int64_t expire_ms, void *opaque)
{
    (void)opaque;
    struct timer *timer = _timer, **tp;
    timer->expire_ns = expire_ms * 1000000LL;
    /* unlink and reinsert sorted */
    for (tp = &timer_queue; *tp; tp = &(*tp)->next) {
        if (*tp == timer) {
            *tp = timer->next;
            break;
        }
    }
    for (tp = &timer_queue; *tp; tp = &(*tp)->next) {
        if (timer->expire_ns <= (*tp)->expire_ns)
            break;
    }
    timer->next = *tp;
    *tp = timer;
}

static void timer_check(void)
{
    while (timer_queue && timer_queue->expire_ns <= mytime_ns) {
        struct timer *t = timer_queue;
        timer_queue = t->next;
        slirp_handle_timer(slirp, t->id, t->cb_opaque);
        free(t);
    }
}

static uint32_t timer_timeout(void)
{
    if (timer_queue) {
        uint64_t delta = timer_queue->expire_ns - mytime_ns;
        uint32_t ms = (uint32_t)(delta / 1000000ULL);
        if (ms < TICK)
            return ms;
    }
    return TICK;
}

static int npoll_sockets; /* observed for callback-contract coverage */
static void register_poll_socket(slirp_os_socket s, void *opaque)
{
    (void)s; (void)opaque;
    npoll_sockets++;
}
static void unregister_poll_socket(slirp_os_socket s, void *opaque)
{
    (void)s; (void)opaque;
    npoll_sockets--;
}
static void notify_cb(void *opaque)
{
    (void)opaque;
}

/* Dynamic poll set: never trust the register/unregister delta to size the
 * array, grow on demand (libslirp may re-register within one fill pass). */
static struct pollfd *pfds;
static int cur_poll, pfds_cap;

static int add_poll_cb(slirp_os_socket s, int events, void *opaque)
{
    (void)opaque;
    short ev = 0;
    if (events & SLIRP_POLL_IN) ev |= POLLIN;
    if (events & SLIRP_POLL_OUT) ev |= POLLOUT;
    if (events & SLIRP_POLL_PRI) ev |= POLLPRI;
    if (cur_poll == pfds_cap) {
        pfds_cap = pfds_cap ? pfds_cap * 2 : 16;
        pfds = realloc(pfds, pfds_cap * sizeof(*pfds));
    }
    pfds[cur_poll].fd = s;
    pfds[cur_poll].events = ev;
    return cur_poll++;
}

static int get_revents_cb(int idx, void *opaque)
{
    (void)opaque;
    /* libslirp masks differ from POSIX: POLLOUT is 4 while
     * SLIRP_POLL_OUT is 2; POLLPRI is 2 while SLIRP_POLL_PRI is 4. */
    if (idx < 0 || idx >= cur_poll) return SLIRP_POLL_ERR;
    short events = pfds[idx].revents;
    int result = 0;
    if (events & POLLIN) result |= SLIRP_POLL_IN;
    if (events & POLLOUT) result |= SLIRP_POLL_OUT;
    if (events & POLLPRI) result |= SLIRP_POLL_PRI;
    if (events & (POLLERR | POLLNVAL)) result |= SLIRP_POLL_ERR;
    if (events & POLLHUP) result |= SLIRP_POLL_HUP;
    return result;
}

static void dopoll(uint32_t timeout)
{
    int err, i;
    static int verbose, vrounds;
    if (!vrounds) { verbose = getenv("SLIRP_SMOKE_VERBOSE") ? 1 : 0; vrounds = 1; }
    cur_poll = 0;
    slirp_pollfds_fill_socket(slirp, &timeout, add_poll_cb, NULL);
    for (i = 0; i < cur_poll; i++)
        pfds[i].revents = 0;
    if (verbose) {
        fprintf(stderr, "[verbose] fill npfds=%d timeout=%u\n", cur_poll, timeout);
        for (i = 0; i < cur_poll; i++)
            fprintf(stderr, "[verbose]   fd=%d events=0x%x\n", pfds[i].fd, pfds[i].events);
    }
    err = poll(pfds, cur_poll, (int)timeout);
    if (verbose) {
        fprintf(stderr, "[verbose] poll ret=%d", err);
        for (i = 0; i < cur_poll; i++)
            fprintf(stderr, " [fd=%d revents=0x%x]", pfds[i].fd, pfds[i].revents);
        fprintf(stderr, "\n");
    }
    slirp_pollfds_poll(slirp, err < 0, get_revents_cb, NULL);
}

static SlirpCb callbacks = {
    .send_packet = send_packet,
    .guest_error = guest_error,
    .clock_get_ns = clock_get_ns,
    .timer_new_opaque = timer_new_opaque,
    .timer_free = timer_free,
    .timer_mod = timer_mod,
    .register_poll_socket = register_poll_socket,
    .unregister_poll_socket = unregister_poll_socket,
    .notify = notify_cb,
};

/* classical 16-bit ones-complement sum */
static uint32_t csum_add(const uint8_t *data, size_t size, uint32_t sum)
{
    size_t i;
    for (i = 0; i + 1 < size; i += 2)
        sum += (((uint16_t)data[i]) << 8) + data[i + 1];
    if (i < size)
        sum += ((uint16_t)data[i]) << 8;
    return sum;
}

static uint16_t csum_finish(uint32_t sum)
{
    sum = (sum & 0xffff) + (sum >> 16);
    sum = (sum & 0xffff) + (sum >> 16);
    return (uint16_t)~sum;
}

/*
 * Build Ethernet+IPv4+TCP SYN from guest -> vhost:port.
 */
static size_t build_syn(uint8_t *f, uint16_t dst_port)
{
    size_t ip_len = 20, tcp_len = 20, total = 14 + ip_len + tcp_len;
    memset(f, 0, total);

    /* Ethernet: dst = slirp host mac, src = guest mac */
    f[0] = 0x52; f[1] = 0x55; f[2] = 0x0a; f[3] = 0x00; f[4] = 0x02; f[5] = 0x02;
    f[6] = 0x52; f[7] = 0x55; f[8] = 0x0a; f[9] = 0x00; f[10] = 0x02; f[11] = 0x0e;
    f[12] = 0x08; f[13] = 0x00; /* IPv4 */

    /* IPv4 */
    f[14] = 0x45;
    f[15] = 0x00;
    uint16_t tl = htons(ip_len + tcp_len);
    memcpy(&f[16], &tl, 2);
    f[18] = 0x68; f[19] = 0xd7; /* id */
    f[20] = 0x40; f[21] = 0x00; /* DF */
    f[22] = 64;                 /* ttl */
    f[23] = 6;                  /* TCP */
    uint32_t ga = htonl(GUEST_IP), vh = htonl(VHOST_IP);
    memcpy(&f[26], &ga, 4);
    memcpy(&f[30], &vh, 4);
    uint16_t ipck = csum_finish(csum_add(f + 14, ip_len, 0));
    ipck = htons(ipck);
    memcpy(&f[24], &ipck, 2);

    /* TCP: SYN — header starts at 34; doff/flags at +12, win at +14, cksum at +16 */
    uint16_t sp = htons(50000);
    uint16_t dp = htons(dst_port);
    memcpy(&f[34], &sp, 2);
    memcpy(&f[36], &dp, 2);
    uint32_t seq = htonl(1);
    memcpy(&f[38], &seq, 4);
    f[46] = (5 << 4);       /* dataofs */
    f[47] = 0x02;           /* SYN */
    uint16_t win = htons(2048);
    memcpy(&f[48], &win, 2);

    /* TCP checksum with IPv4 pseudo-header */
    uint8_t pseudo[12];
    memcpy(&pseudo[0], &f[26], 4);
    memcpy(&pseudo[4], &f[30], 4);
    pseudo[8] = 0;
    pseudo[9] = 6;
    uint16_t ptcl = htons((uint16_t)tcp_len);
    memcpy(&pseudo[10], &ptcl, 2);
    uint32_t sum = csum_add(pseudo, sizeof(pseudo), 0);
    sum = csum_add(f + 34, tcp_len, sum);
    uint16_t tck = htons(csum_finish(sum));
    memcpy(&f[50], &tck, 2); /* TCP checksum at +16 */

    return total;
}

int main(void)
{
    printf("libslirp vendor smoke — libslirp %s\n", slirp_version_string());
    { const char *t = getenv("SLIRP_SMOKE_TICKS"); if (t) max_ticks = atoi(t); }

    /* 1. host loopback listener */
    int lfd = socket(AF_INET, SOCK_STREAM, 0);
    if (lfd < 0) { perror("socket"); return 2; }
    struct sockaddr_in la = {
        .sin_family = AF_INET,
        .sin_port = 0,
        .sin_addr.s_addr = htonl(INADDR_LOOPBACK),
    };
    socklen_t alen = sizeof(la);
    if (bind(lfd, (struct sockaddr *)&la, alen) < 0) { perror("bind"); return 2; }
    if (getsockname(lfd, (struct sockaddr *)&la, &alen) < 0) { perror("getsockname"); return 2; }
    if (listen(lfd, 1) < 0) { perror("listen"); return 2; }
    uint16_t port = ntohs(la.sin_port);
    printf("event: listener on 127.0.0.1:%u\n", port);

    /* 2. slirp_new */
    SlirpConfig cfg = {
        .version = 6,
        .in_enabled = true,
        .vnetwork.s_addr = htonl(0x0a000200),
        .vnetmask.s_addr = htonl(0xffffff00),
        .vhost.s_addr = htonl(VHOST_IP),
        .vdhcp_start.s_addr = htonl(0x0a00020f),
        .vnameserver.s_addr = htonl(0x0a000203),
        .tftp_path = NULL,          /* host TFTP directory service OFF */
        .enable_emu = false,        /* emulation/exec paths OFF */
        .disable_host_loopback = false,
        .disable_dns = true,        /* smoke does not need host DNS */
        .disable_dhcp = true,
    };
    slirp = slirp_new(&cfg, &callbacks, NULL);
    if (!slirp) { fprintf(stderr, "FAIL: slirp_new returned NULL\n"); return 1; }
    printf("event: slirp_new OK (config v6)\n");

    /* 3. hardened build must reject host execution registration */
    struct in_addr any = { .s_addr = htonl(0x0a000210) };
    if (slirp_add_exec(slirp, "/bin/echo", &any, 5555) == 0) {
        fprintf(stderr, "FAIL: slirp_add_exec succeeded — host exec not compiled out\n");
        return 1;
    }
    printf("event: slirp_add_exec correctly rejected (hardened build)\n");
    printf("PHASE-A PASS: slirp_new (config v6) + exec rejection\n");

    /* 4. hostfwd API lifecycle on a reserved free loopback port */
    int fail = 0;
    {
        struct sockaddr_in hf = {
            .sin_family = AF_INET,
            .sin_port = 0,
            .sin_addr.s_addr = htonl(INADDR_LOOPBACK),
        };
        socklen_t hl = sizeof(hf);
        int probe = socket(AF_INET, SOCK_STREAM, 0);
        if (probe < 0 || bind(probe, (struct sockaddr *)&hf, hl) < 0 ||
            getsockname(probe, (struct sockaddr *)&hf, &hl) < 0) {
            perror("FAIL: hostfwd probe bind");
            return 1;
        }
        close(probe); /* slirp_add_hostfwd will bind this port itself */
        struct in_addr host_loop = { .s_addr = htonl(INADDR_LOOPBACK) };
        struct in_addr guest_a = { .s_addr = htonl(0x0a00020a) }; /* 10.0.2.10 */
        int hfport = ntohs(hf.sin_port);
        int r_add = slirp_add_hostfwd(slirp, /*is_udp=*/0, host_loop, hfport,
                                      guest_a, 8080);
        int r_rem = slirp_remove_hostfwd(slirp, 0, host_loop, hfport);
        printf("event: hostfwd add=%d remove=%d (port %u)\n", r_add, r_rem, hfport);
        if (r_add != 0 || r_rem != 0) {
            printf("PHASE-B FAIL: hostfwd lifecycle add/remove\n");
            fail = 1;
        } else {
            printf("PHASE-B PASS: slirp_add_hostfwd/slirp_remove_hostfwd lifecycle (host bind on 127.0.0.1)\n");
        }
    }

    /* 5. guest TCP SYN -> vhost:port (raw-packet relay path) */
    uint8_t frame[64];
    size_t flen = build_syn(frame, port);
    slirp_input(slirp, frame, flen);

    /* 6. drive the loop until SYN+ACK lands in the guest or timeout */
    int ticks = 0;
    while (!done_synack && ticks < max_ticks) {
        timer_check();
        uint32_t timeout = timer_timeout();
        dopoll(timeout);
        mytime_ns += (int64_t)timeout * 1000000LL;
        ticks++;
    }
    if (!done_synack) {
        printf("PHASE-C FAIL (open): raw guest SYN -> vhost loopback connect -> "
               "SYN/ACK relay not observed after %d ticks; preserved as evidence, "
               "handed to backend/network-qualification stage\n", ticks);
        fail = 1;
    } else {
        printf("event: poll/timer callbacks drove %d loop iterations\n", ticks);
        /* 7. the host listener must have a pending accepted connection */
        int cfd = accept(lfd, NULL, NULL);
        if (cfd < 0) {
            perror("PHASE-C FAIL: accept of libslirp's host-loopback connection");
            fail = 1;
        } else {
            printf("event: host accepted libslirp loopback connection fd=%d\n", cfd);
            close(cfd);
            printf("PHASE-C PASS: vhost->loopback TCP connect + SYN/ACK relay + poll/timer callbacks\n");
        }
    }

    close(lfd);
    slirp_cleanup(slirp);
    if (!fail)
        printf("SMOKE-PASS: slirp_new, exec rejection, hostfwd lifecycle, relay, "
               "poll+timer callbacks, slirp_cleanup all OK\n");
    else
        printf("SMOKE-RESULT: core lifecycle checked; see PHASE FAIL lines above\n");
    return fail;
}
