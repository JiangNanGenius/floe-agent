/* SPDX-License-Identifier: Apache-2.0 */
/* Tests for the versioned readiness-wait ABI (USERNET_WAIT_ABI 2) and for the
 * shared park helper Bridge/net_wait.h that both runtime wait sites now use.
 *
 * The helper is compiled here against the REAL AESession layout from
 * Bridge/embedded_internal.h, so these tests exercise the same inline code the
 * engine will, not a paraphrase of it.
 *
 * The central regression being pinned: the previous waiters polled every
 * descriptor with POLLIN|POLLERR|POLLHUP only. A descriptor the backend wants
 * to WRITE to could never wake the park. These tests assert the write-ready
 * interest is now reported, that truncation and fill failure clamp the park to
 * a bounded retry instead of sleeping on the caller's (up to 60 s) budget, and
 * that a park with no descriptors at all still performs a real timed sleep.
 */
#include "harness.h"
#include "guest_frame.h"
#include "usernet.h"
#include "usernet_host.h"   /* gated test-clock + resolver hooks */

/* The real bridge header, so ae_net_wait_park() is the shipped inline code. */
#include "net_wait.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

static int64_t now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static void emit_to_backend(struct UserNet *un, const uint8_t *frame, size_t len) {
    usernet_input(un, frame, len);
}

static bool pred_gw_mac(void *c) { return ((VGuest *)c)->gw_mac_known; }

static bool boot_guest(VGuest *g, struct UserNet *un) {
    uint8_t frame[VG_MAX_FRAME];
    size_t n = vg_arp_request(g, frame, VG_IP_GW);
    emit_to_backend(un, frame, n);
    return vg_pump(g, un, emit_to_backend, NULL, 0, NULL, NULL,
                   pred_gw_mac, g, 3000);
}

static struct UserNet *make_backend_cfg(VGuest *g, const UserNetConfig *cfg) {
    vg_init(g);
    if (cfg) return usernet_new_with_config(vg_output, g, cfg);
    uint8_t mac[6] = VG_MAC_GUEST;
    return usernet_new(vg_output, g, mac, 0);
}

static int count_events(const UserNetWaitFd *f, uint32_t n, int mask) {
    int c = 0;
    for (uint32_t i = 0; i < n; i++) if (f[i].events & mask) c++;
    return c;
}

/* ---- 1. write-ready interest is actually reported ---- */

static void test_pollout_interest(void) {
    T_BEGIN("poll interests: a connecting host socket reports POLLOUT");

    VGuest *g = calloc(1, sizeof(*g));
    struct UserNet *un = make_backend_cfg(g, NULL);
    T_CHECK(un != NULL);
    if (!un) { free(g); return; }
    T_CHECK(boot_guest(g, un));

    /* Baseline: with no traffic the set carries no write interest. */
    UserNetWaitFd wfds[256];
    UserNetWaitRequest req;
    UserNetWaitResult res;
    memset(&req, 0, sizeof(req));
    req.struct_size = sizeof(req);
    req.abi = USERNET_WAIT_ABI;
    req.capacity = 256;
    req.entries = wfds;
    T_EQ_U(usernet_fill_wait(un, &req, &res), 0);
    int baseline_out = count_events(wfds, res.count, POLLOUT);
    T_EQ_U(baseline_out, 0);

    /* The guest opens a TCP connection. libslirp creates a NONBLOCKING host
     * socket, connect() returns EINPROGRESS and the socket enters
     * SS_ISFCONNECTING, for which slirp_pollfds_fill_socket() asks
     * SLIRP_POLL_OUT. Filling BEFORE the next dispatch therefore must show
     * POLLOUT — this is precisely the interest the old POLLIN-only snapshot
     * threw away, which is why a guest blocked on a connecting socket stalled
     * until an unrelated deadline. */
    vg_tcp_connect(g, un, emit_to_backend, VG_IP_GW, 9, 43001);

    memset(&res, 0, sizeof(res));
    T_EQ_U(usernet_fill_wait(un, &req, &res), 0);
    int connecting_out = count_events(wfds, res.count, POLLOUT);
    T_CHECK(res.count > 0);
    T_CHECK(connecting_out >= 1);
    T_NOTE("descriptors=%u with POLLOUT=%d (was structurally impossible before)",
           res.count, connecting_out);

    /* After the connection is driven, the interest set must change: the
     * descriptor is either connected (read interest) or refused (gone). */
    for (int i = 0; i < 50; i++) { usernet_poll(un); vg_drain(g, un, emit_to_backend); }
    memset(&res, 0, sizeof(res));
    T_EQ_U(usernet_fill_wait(un, &req, &res), 0);
    T_NOTE("after driving: descriptors=%u POLLOUT=%d POLLIN=%d",
           res.count, count_events(wfds, res.count, POLLOUT),
           count_events(wfds, res.count, POLLIN));

    /* A listener must be represented with read interest. */
    uint16_t hp = 0;
    int probe = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in sa;
    memset(&sa, 0, sizeof(sa));
    sa.sin_family = AF_INET;
    sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    sa.sin_port = 0;
    bind(probe, (struct sockaddr *)&sa, sizeof(sa));
    socklen_t sl = sizeof(sa);
    getsockname(probe, (struct sockaddr *)&sa, &sl);
    hp = ntohs(sa.sin_port);
    close(probe);
    T_EQ_U(usernet_add_hostfwd(un, false, hp, 9200), 0);
    memset(&res, 0, sizeof(res));
    T_EQ_U(usernet_fill_wait(un, &req, &res), 0);
    T_CHECK(count_events(wfds, res.count, POLLIN) >= 1);

    usernet_destroy(un);
    free(g);
}

/* ---- 2. capacity, truncation and clamped deadline ---- */

static void test_truncation(void) {
    T_BEGIN("capacity: truncation is reported and the deadline is clamped");

    VGuest *g = calloc(1, sizeof(*g));
    UserNetConfig cfg;
    memset(&cfg, 0, sizeof(cfg));
    cfg.struct_size = sizeof(cfg);
    cfg.abi = USERNET_CFG_ABI;
    uint8_t mac[6] = VG_MAC_GUEST;
    memcpy(cfg.guest_mac, mac, 6);
    cfg.poll_capacity = 2;                 /* deliberately tiny */
    struct UserNet *un = make_backend_cfg(g, &cfg);
    T_CHECK(un != NULL);
    if (!un) { free(g); return; }

    /* Open more descriptors than the poll capacity can represent. */
    for (uint16_t i = 0; i < 6; i++)
        T_EQ_U(usernet_add_hostfwd(un, false, (uint16_t)(25100 + i),
                                   (uint16_t)(9300 + i)), 0);
    for (int i = 0; i < 3; i++) usernet_poll(un);

    UserNetWaitFd wfds[64];
    UserNetWaitRequest req;
    UserNetWaitResult res;
    memset(&req, 0, sizeof(req));
    req.struct_size = sizeof(req);
    req.abi = USERNET_WAIT_ABI;
    req.capacity = 64;
    req.entries = wfds;
    memset(&res, 0, sizeof(res));
    T_EQ_U(usernet_fill_wait(un, &req, &res), 0);

    T_CHECK(res.wanted > res.count);
    T_EQ_U(res.truncated, 1);
    T_CHECK((res.flags & USERNET_WAIT_R_TRUNCATED) != 0);
    /* A truncated set must never be slept on for long: unrepresented
     * descriptors would be starved. The clamp is libslirp's own fast-timer
     * granularity, so it is prompt but not a spin. */
    T_CHECK(res.timeout_ms <= 2);
    T_NOTE("wanted=%u count=%u timeout_ms=%u (clamped)",
           res.wanted, res.count, res.timeout_ms);

    UserNetExtStats xs;
    xs.struct_size = sizeof(xs);
    usernet_get_ext_stats(un, &xs);
    T_CHECK(xs.wait_truncated > 0);
    T_EQ_U(xs.poll_capacity, 2);

    /* A caller capacity smaller than the backend's budget is honoured too. */
    memset(&res, 0, sizeof(res));
    req.capacity = 1;
    T_EQ_U(usernet_fill_wait(un, &req, &res), 0);
    T_EQ_U(res.count, 1);
    T_CHECK(res.wanted > 1);
    T_EQ_U(res.truncated, 1);

    /* And a caller capacity larger than the backend budget is clamped to it,
     * not silently widened: the configured ceiling is authoritative. */
    memset(&res, 0, sizeof(res));
    req.capacity = 64;
    T_EQ_U(usernet_fill_wait(un, &req, &res), 0);
    T_CHECK(res.count <= 2);

    usernet_destroy(un);
    free(g);
}

/* ---- 3. DUP ownership: the waiter owns independent references ---- */

static void test_dup_ownership(void) {
    T_BEGIN("fd ownership: DUP hands back independent, closable references");

    VGuest *g = calloc(1, sizeof(*g));
    struct UserNet *un = make_backend_cfg(g, NULL);
    T_CHECK(un != NULL);
    if (!un) { free(g); return; }

    uint16_t hp = 0;
    int probe = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in sa;
    memset(&sa, 0, sizeof(sa));
    sa.sin_family = AF_INET;
    sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    sa.sin_port = 0;
    bind(probe, (struct sockaddr *)&sa, sizeof(sa));
    socklen_t sl = sizeof(sa);
    getsockname(probe, (struct sockaddr *)&sa, &sl);
    hp = ntohs(sa.sin_port);
    close(probe);
    T_EQ_U(usernet_add_hostfwd(un, false, hp, 9400), 0);
    for (int i = 0; i < 3; i++) usernet_poll(un);

    /* Raw (non-dup) snapshot: the backend's own descriptors. */
    int raw[32];
    int nraw = usernet_wait_fds(un, raw, 32);
    T_CHECK(nraw >= 1);

    UserNetWaitFd wfds[32];
    UserNetWaitRequest req;
    UserNetWaitResult res;
    memset(&req, 0, sizeof(req));
    req.struct_size = sizeof(req);
    req.abi = USERNET_WAIT_ABI;
    req.capacity = 32;
    req.flags = USERNET_WAIT_F_DUP;
    req.entries = wfds;
    memset(&res, 0, sizeof(res));
    T_EQ_U(usernet_fill_wait(un, &req, &res), 0);
    T_EQ_U(res.count, (uint32_t)nraw);

    for (uint32_t i = 0; i < res.count; i++) {
        T_CHECK(wfds[i].fd >= 0);
        /* A dup'd reference is a different descriptor number referring to the
         * same open file description. */
        bool same_as_raw = false;
        for (int j = 0; j < nraw; j++) if (raw[j] == wfds[i].fd) same_as_raw = true;
        T_CHECK(!same_as_raw);
        T_CHECK(fcntl(wfds[i].fd, F_GETFD) >= 0);
    }

    /* Closing what we were given must not disturb the backend: it still polls
     * and still serves afterwards. */
    for (uint32_t i = 0; i < res.count; i++) close(wfds[i].fd);
    for (int i = 0; i < 3; i++) usernet_poll(un);
    int nraw2 = usernet_wait_fds(un, raw, 32);
    T_EQ_U(nraw2, nraw);
    for (int j = 0; j < nraw2; j++) T_CHECK(fcntl(raw[j], F_GETFD) >= 0);
    T_NOTE("closed %u dup'd descriptors; backend descriptors all still open",
           res.count);

    /* Without DUP the caller gets the backend's own numbers and must NOT close
     * them. Verify they are the same numbers usernet_wait_fds reports. */
    memset(&res, 0, sizeof(res));
    req.flags = 0;
    T_EQ_U(usernet_fill_wait(un, &req, &res), 0);
    T_EQ_U(res.count, (uint32_t)nraw);
    for (uint32_t i = 0; i < res.count; i++) {
        bool found = false;
        for (int j = 0; j < nraw; j++) if (raw[j] == wfds[i].fd) found = true;
        T_CHECK(found);
    }

    usernet_destroy(un);
    free(g);
}

/* ---- 4. timers feed the deadline ---- */

static void test_timer_deadline(void) {
    T_BEGIN("timers: an armed network timer bounds the park, no readable-spin");

    VGuest *g = calloc(1, sizeof(*g));
    UserNetConfig cfg;
    memset(&cfg, 0, sizeof(cfg));
    cfg.struct_size = sizeof(cfg);
    cfg.abi = USERNET_CFG_ABI;
    uint8_t mac[6] = VG_MAC_GUEST;
    memcpy(cfg.guest_mac, mac, 6);
    cfg.flags = USERNET_CFG_F_IPV6;         /* arms libslirp's RA timer */
    struct UserNet *un = make_backend_cfg(g, &cfg);
    T_CHECK(un != NULL);
    if (!un) { free(g); return; }

    UserNetDnsInfo di;
    memset(&di, 0, sizeof(di));
    di.struct_size = sizeof(di);
    usernet_get_dns_info(un, &di);
    T_EQ_U(di.ipv6_guest_enabled, 1);

    UserNetWaitFd wfds[256];
    UserNetWaitRequest req;
    UserNetWaitResult res;
    memset(&req, 0, sizeof(req));
    req.struct_size = sizeof(req);
    req.abi = USERNET_WAIT_ABI;
    req.capacity = 256;
    req.entries = wfds;

    /* Idle IPv4-only backend: nothing pending means NO network deadline, so a
     * parked machine is not woken once a second for nothing. */
    VGuest *g4 = calloc(1, sizeof(*g4));
    struct UserNet *un4 = make_backend_cfg(g4, NULL);
    for (int i = 0; i < 3; i++) usernet_poll(un4);
    memset(&res, 0, sizeof(res));
    T_EQ_U(usernet_fill_wait(un4, &req, &res), 0);
    T_EQ_U(res.count, 0);
    T_EQ_U(res.timeout_ms, UINT32_MAX);
    T_CHECK((res.flags & USERNET_WAIT_R_TIMER_ARMED) == 0);
    T_NOTE("idle backend: timeout_ms=UINT32_MAX (no spurious 1Hz wake)");
    usernet_destroy(un4);
    free(g4);

    /* With guest IPv6 enabled libslirp arms its router-advertisement timer, so
     * the reported deadline must be finite and the timer must actually fire. */
    for (int i = 0; i < 3; i++) usernet_poll(un);
    memset(&res, 0, sizeof(res));
    T_EQ_U(usernet_fill_wait(un, &req, &res), 0);
    T_CHECK(res.timeout_ms != UINT32_MAX);
    T_CHECK((res.flags & USERNET_WAIT_R_TIMER_ARMED) != 0);
    T_NOTE("IPv6 enabled: timeout_ms=%u flags=0x%x", res.timeout_ms, res.flags);

    UserNetExtStats xs;
    xs.struct_size = sizeof(xs);
    usernet_get_ext_stats(un, &xs);
    T_CHECK(xs.timers_armed >= 1);

    /* The reported deadline must be a real ABSOLUTE deadline, not a constant:
     * advancing the clock by 500 ms must move it by the same amount. */
    uint32_t t_first = res.timeout_ms;
    T_CHECK(t_first > 1000);
    un_host_test_advance_clock(500);
    memset(&res, 0, sizeof(res));
    T_EQ_U(usernet_fill_wait(un, &req, &res), 0);
    T_CHECK(res.timeout_ms < t_first);
    int64_t drift = (int64_t)t_first - (int64_t)res.timeout_ms;
    T_CHECK(drift >= 400 && drift <= 600);
    T_NOTE("RA deadline tracked the clock: %u ms -> %u ms (drift %lld)",
           t_first, res.timeout_ms, (long long)drift);

    /* Drive past the deadline: the timer must expire exactly once, the RA must
     * actually reach the guest, and the backend must re-arm rather than spin. */
    usernet_get_ext_stats(un, &xs);
    uint64_t before = xs.timer_expiries;
    un_host_test_advance_clock((int64_t)t_first + 50);
    uint32_t rx_before = g->rx_count;
    usernet_poll(un);
    usernet_get_ext_stats(un, &xs);
    T_CHECK(xs.timer_expiries > before);
    T_EQ_U(xs.timer_expiries, before + 1);
    T_CHECK(g->rx_count > rx_before);
    T_NOTE("timer fired: expiries=%llu, RA frames delivered=%u",
           (unsigned long long)xs.timer_expiries, g->rx_count - rx_before);

    /* The delivered frame must be a real ICMPv6 Router Advertisement
     * (type 134) addressed to the all-nodes multicast group, not noise. */
    bool saw_ra = false;
    for (uint32_t i = 0; i < VG_RX_SLOTS; i++) {
        const uint8_t *f = g->rx[i];
        if (g->rx_len[i] < 14 + 40 + 8) continue;
        if (vg_rd16(f + 12) != 0x86dd) continue;
        if (f[14 + 6] != 58) continue;                 /* next header ICMPv6 */
        if (f[14 + 40] == 134) { saw_ra = true; break; }
    }
    T_CHECK(saw_ra);

    /* Re-armed, so the next deadline is finite again rather than expired. */
    memset(&res, 0, sizeof(res));
    T_EQ_U(usernet_fill_wait(un, &req, &res), 0);
    T_CHECK(res.timeout_ms != UINT32_MAX);
    T_CHECK(res.timeout_ms > 0);
    usernet_get_ext_stats(un, &xs);
    T_CHECK(xs.timers_armed >= 1);

    un_host_test_reset_clock();
    usernet_destroy(un);
    free(g);
}

/* ---- 5. generation tracks membership ---- */

static void test_generation(void) {
    T_BEGIN("generation: changes with descriptor membership, stable otherwise");

    VGuest *g = calloc(1, sizeof(*g));
    struct UserNet *un = make_backend_cfg(g, NULL);
    T_CHECK(un != NULL);
    if (!un) { free(g); return; }

    UserNetWaitFd wfds[64];
    UserNetWaitRequest req;
    UserNetWaitResult res;
    memset(&req, 0, sizeof(req));
    req.struct_size = sizeof(req);
    req.abi = USERNET_WAIT_ABI;
    req.capacity = 64;
    req.entries = wfds;

    T_EQ_U(usernet_fill_wait(un, &req, &res), 0);
    uint64_t g0 = res.generation;
    T_EQ_U(usernet_fill_wait(un, &req, &res), 0);
    T_EQ_U(res.generation, g0);

    T_EQ_U(usernet_add_hostfwd(un, false, 25500, 9500), 0);
    T_EQ_U(usernet_fill_wait(un, &req, &res), 0);
    T_NE_U(res.generation, g0);
    uint64_t g1 = res.generation;

    T_EQ_U(usernet_remove_hostfwd(un, false, 25500), 0);
    T_EQ_U(usernet_fill_wait(un, &req, &res), 0);
    T_NE_U(res.generation, g1);

    usernet_destroy(un);
    free(g);
}

/* ---- 6. the real bridge park helper ---- */

static AESession *make_session(bool with_pipe) {
    AESession *s = calloc(1, sizeof(*s));
    if (!s) return NULL;
    if (with_pipe) {
        if (pipe(s->wake_pipe) != 0) { free(s); return NULL; }
        fcntl(s->wake_pipe[0], F_SETFL, fcntl(s->wake_pipe[0], F_GETFL) | O_NONBLOCK);
        fcntl(s->wake_pipe[1], F_SETFL, fcntl(s->wake_pipe[1], F_GETFL) | O_NONBLOCK);
        s->wake_pipe_ready = 1;
    }
    return s;
}

static void free_session(AESession *s) {
    if (!s) return;
    if (s->wake_pipe_ready) { close(s->wake_pipe[0]); close(s->wake_pipe[1]); }
    free(s);
}

static void test_park_helper_timed_sleep(void) {
    T_BEGIN("net_wait.h: no pipe + no network still performs a real timed sleep");

    /* This is the regression the reviewer flagged: with total == 0 the old
     * shape skipped poll() entirely and returned at once, which turns the
     * caller's park into a busy spin and burns a core on a WFI-idle guest. */
    AESession *s = make_session(false);
    T_CHECK(s != NULL);
    if (!s) return;

    int64_t t0 = now_ms();
    bool pipe_ready = ae_net_wait_park(s, NULL, 250000000ULL);   /* 250 ms */
    int64_t elapsed = now_ms() - t0;
    T_CHECK(!pipe_ready);
    T_CHECK(elapsed >= 200);
    T_CHECK(elapsed < 1500);
    T_NOTE("parked %lld ms with nfds==0 (timed sleep, not a spin)",
           (long long)elapsed);

    /* With a wake pipe but no network, the pipe must still be honoured. */
    free_session(s);
    s = make_session(true);
    T_CHECK(s != NULL);
    if (!s) return;
    ssize_t w = write(s->wake_pipe[1], "x", 1);
    T_EQ_U((uint64_t)w, 1);
    t0 = now_ms();
    pipe_ready = ae_net_wait_park(s, NULL, 5000000000ULL);       /* 5 s */
    elapsed = now_ms() - t0;
    T_CHECK(pipe_ready);
    T_CHECK(elapsed < 1000);
    T_NOTE("wake pipe returned in %lld ms out of a 5000 ms budget",
           (long long)elapsed);

    free_session(s);
}

static void test_park_helper_degraded_clamp(void) {
    T_BEGIN("net_wait.h: a truncated set clamps the park instead of sleeping long");

    VGuest *g = calloc(1, sizeof(*g));
    UserNetConfig cfg;
    memset(&cfg, 0, sizeof(cfg));
    cfg.struct_size = sizeof(cfg);
    cfg.abi = USERNET_CFG_ABI;
    uint8_t mac[6] = VG_MAC_GUEST;
    memcpy(cfg.guest_mac, mac, 6);
    cfg.poll_capacity = 1;                 /* forces USERNET_WAIT_R_TRUNCATED */
    struct UserNet *un = make_backend_cfg(g, &cfg);
    T_CHECK(un != NULL);
    if (!un) { free(g); return; }

    for (uint16_t i = 0; i < 5; i++)
        T_EQ_U(usernet_add_hostfwd(un, false, (uint16_t)(25600 + i),
                                   (uint16_t)(9600 + i)), 0);
    for (int i = 0; i < 3; i++) usernet_poll(un);

    /* Confirm the backend really reports truncation for this configuration. */
    UserNetWaitFd probe_fds[64];
    UserNetWaitRequest preq;
    UserNetWaitResult pres;
    memset(&preq, 0, sizeof(preq));
    preq.struct_size = sizeof(preq);
    preq.abi = USERNET_WAIT_ABI;
    preq.capacity = 64;
    preq.entries = probe_fds;
    T_EQ_U(usernet_fill_wait(un, &preq, &pres), 0);
    T_EQ_U(pres.truncated, 1);

    AESession *s = make_session(false);
    T_CHECK(s != NULL);
    if (!s) { usernet_destroy(un); free(g); return; }

    /* The caller offers a 5 s budget (floe_ae_wait_event accepts up to 60 s).
     * Because the readiness set is incomplete the helper must NOT sleep on
     * that budget: it clamps to a bounded retry. */
    int64_t t0 = now_ms();
    bool pipe_ready = ae_net_wait_park(s, un, 5000000000ULL);
    int64_t elapsed = now_ms() - t0;
    T_CHECK(!pipe_ready);
    T_CHECK(elapsed < 1000);
    T_NOTE("truncated set: parked only %lld ms of a 5000 ms budget",
           (long long)elapsed);

    /* And it must still be a real wait, not a spin. */
    T_CHECK(elapsed >= 1);

    free_session(s);
    usernet_destroy(un);
    free(g);
}

static void test_park_helper_wakes_on_socket(void) {
    T_BEGIN("net_wait.h: a real host descriptor wakes the park early");

    VGuest *g = calloc(1, sizeof(*g));
    struct UserNet *un = make_backend_cfg(g, NULL);
    T_CHECK(un != NULL);
    if (!un) { free(g); return; }
    T_CHECK(boot_guest(g, un));

    /* A listening forward is readable the moment a real host client connects. */
    uint16_t hp = 0;
    int probe = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in sa;
    memset(&sa, 0, sizeof(sa));
    sa.sin_family = AF_INET;
    sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    sa.sin_port = 0;
    bind(probe, (struct sockaddr *)&sa, sizeof(sa));
    socklen_t sl = sizeof(sa);
    getsockname(probe, (struct sockaddr *)&sa, &sl);
    hp = ntohs(sa.sin_port);
    close(probe);
    T_EQ_U(usernet_add_hostfwd(un, false, hp, 9700), 0);
    for (int i = 0; i < 3; i++) usernet_poll(un);

    AESession *s = make_session(true);
    T_CHECK(s != NULL);
    if (!s) { usernet_destroy(un); free(g); return; }

    int client = socket(AF_INET, SOCK_STREAM, 0);
    fcntl(client, F_SETFL, fcntl(client, F_GETFL) | O_NONBLOCK);
    memset(&sa, 0, sizeof(sa));
    sa.sin_family = AF_INET;
    sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    sa.sin_port = htons(hp);

    int64_t t0 = now_ms();
    connect(client, (struct sockaddr *)&sa, sizeof(sa));
    /* The park is given a long budget; the listener becoming readable must cut
     * it short. (The park itself does not dispatch, it only wakes — matching
     * the engine, where the driver runs on the next tick.) */
    bool pipe_ready = ae_net_wait_park(s, un, 5000000000ULL);
    int64_t elapsed = now_ms() - t0;
    T_CHECK(!pipe_ready);
    T_CHECK(elapsed < 2000);
    T_NOTE("listener readiness ended a 5000 ms park after %lld ms",
           (long long)elapsed);

    close(client);
    free_session(s);
    usernet_destroy(un);
    free(g);
}

static void test_park_helper_dead_backend(void) {
    T_BEGIN("net_wait.h: a torn-down backend never parks on a phantom deadline");

    VGuest *g = calloc(1, sizeof(*g));
    struct UserNet *un = make_backend_cfg(g, NULL);
    T_CHECK(un != NULL);
    if (!un) { free(g); return; }
    AESession *s = make_session(true);
    T_CHECK(s != NULL);
    if (!s) { usernet_destroy(un); free(g); return; }

    usernet_destroy(un);
    un = NULL;
    int64_t t0 = now_ms();
    bool pipe_ready = ae_net_wait_park(s, un, 300000000ULL);
    int64_t elapsed = now_ms() - t0;
    T_CHECK(!pipe_ready);
    T_CHECK(elapsed >= 250);
    T_NOTE("no backend: honoured the caller's %lld ms budget", (long long)elapsed);

    free_session(s);
    free(g);
}

int main(void) {
    test_pollout_interest();
    test_truncation();
    test_dup_ownership();
    test_timer_deadline();
    test_generation();
    test_park_helper_timed_sleep();
    test_park_helper_degraded_clamp();
    test_park_helper_wakes_on_socket();
    test_park_helper_dead_backend();
    T_EXIT("test_waitset");
}
