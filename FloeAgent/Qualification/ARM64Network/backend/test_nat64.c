/* SPDX-License-Identifier: Apache-2.0 */
/* Apple resolver / DNS64-NAT64 adaptation tests.
 *
 * Three layers, each honest about what it proves:
 *
 *  A. Real host resolver discovery (IPv4 and IPv6) with no injection. This is
 *     an ordinary host-network check and runs against the actual machine.
 *
 *  B. The NAT64 mapping DECISION LOGIC, driven through the qualification-only
 *     injection hook (compiled in solely under -DFLOE_USERNET_TEST_HOOKS):
 *     exclusions, cache and TTL, prefix reporting, and the default
 *     family-neutral getaddrinfo() path. The default path is asserted to report
 *     "no mapping" on this network, because this host is NOT behind DNS64/NAT64
 *     — that is remaining gate G3, not a pass.
 *
 *  C. When linked against the PATCHED libslirp
 *     (patches/0002-floe-host-hooks.patch), an end-to-end mechanism proof: a
 *     guest IPv4 TCP connection to a public IPv4 literal is carried over a real
 *     AF_INET6 host socket to a real [::1] listener, with the hook invocation
 *     counters read back. This proves the patch is compiled AND called. It does
 *     NOT prove Apple's getaddrinfo synthesizes a prefix on a real IPv6-only
 *     network; that stays gate G3.
 *
 *     Layer C is compiled out against stock libslirp, and the test then says so
 *     explicitly rather than reporting a silent pass.
 */
#include "net_test_util.h"

#include <arpa/inet.h>
#include <stdio.h>

#ifdef FLOE_USERNET_TEST_HOOKS
/* ---- injected resolver / mapping ---- */

static struct in_addr  g_inj_v4;
static struct in6_addr g_inj_v6;
static int             g_inj_have_v4, g_inj_have_v6;
static int             g_inj_calls;
static uint16_t        g_inj_v6_port = 53;

static int inj_probe(UnResolver *out, void *ctx) {
    (void)ctx;
    g_inj_calls++;
    memset(out, 0, sizeof(*out));
    if (g_inj_have_v4) {
        out->have_v4 = true;
        out->v4 = g_inj_v4;
        out->v4_port = htons(53);
    }
    if (g_inj_have_v6) {
        out->have_v6 = true;
        out->v6 = g_inj_v6;
        out->v6_port = htons(g_inj_v6_port);
    }
    out->from_probe = (g_inj_have_v4 || g_inj_have_v6);
    if (!out->from_probe) { out->probe_failed = true; return -ENOENT; }
    return 0;
}

static struct in6_addr g_map_to;
static int             g_map_result;      /* 1 mapped, 0 not, <0 error */
static int             g_map_calls;
static uint32_t        g_map_last_v4;

static int inj_map(const struct in_addr *v4, struct in6_addr *out, void *ctx) {
    (void)ctx;
    g_map_calls++;
    g_map_last_v4 = ntohl(v4->s_addr);
    if (g_map_result == 1) *out = g_map_to;
    return g_map_result;
}

static void set_inj_resolver(const char *v4, const char *v6) {
    g_inj_have_v4 = v4 && inet_pton(AF_INET, v4, &g_inj_v4) == 1;
    g_inj_have_v6 = v6 && inet_pton(AF_INET6, v6, &g_inj_v6) == 1;
    g_inj_v6_port = 53;
}
#endif /* FLOE_USERNET_TEST_HOOKS */

/* ================= layer A: real host resolver ================= */

static void test_real_resolver_discovery(void) {
    T_BEGIN("A: real host resolver discovery (no injection)");

    UnResolver r;
    int rc = un_host_discover(&r);
    T_NOTE("un_host_discover rc=%d have_v4=%d have_v6=%d from_probe=%d",
           rc, r.have_v4, r.have_v6, r.from_probe);
    if (rc == 0) {
        T_CHECK(r.have_v4 || r.have_v6);
        if (r.have_v4) {
            char buf[INET_ADDRSTRLEN];
            inet_ntop(AF_INET, &r.v4, buf, sizeof(buf));
            T_NOTE("  IPv4 resolver %s port %u", buf, ntohs(r.v4_port));
            /* A discovered resolver must never be loopback or unspecified:
             * those would make guest DNS a silent black hole. */
            T_CHECK(r.v4.s_addr != htonl(INADDR_LOOPBACK));
            T_CHECK(r.v4.s_addr != htonl(INADDR_ANY));
        }
        if (r.have_v6) {
            char buf[INET6_ADDRSTRLEN];
            inet_ntop(AF_INET6, &r.v6, buf, sizeof(buf));
            T_NOTE("  IPv6 resolver %s port %u scope %u", buf,
                   ntohs(r.v6_port), r.v6_scope);
            T_CHECK(!IN6_IS_ADDR_LOOPBACK(&r.v6));
        }
    } else {
        /* No resolver on this host. That is an honest environment fact, not a
         * test failure of the backend: the contract is that guest DNS is then
         * refused rather than answered from a fabricated public resolver. */
        T_NOTE("  no resolver discoverable on this host (rc=%d)", rc);
        T_CHECK(r.probe_failed);
    }

    /* The backend must report the same thing through its public getters. */
    VGuest *g = calloc(1, sizeof(*g));
    vg_init(g);
    uint8_t mac[6] = VG_MAC_GUEST;
    struct UserNet *un = usernet_new(vg_output, g, mac, 0);
    T_CHECK(un != NULL);
    if (!un) { free(g); return; }
    UserNetDnsInfo di;
    memset(&di, 0, sizeof(di));
    di.struct_size = sizeof(di);
    T_EQ_U(usernet_get_dns_info(un, &di), 0);
    T_EQ_U(di.v4_valid, r.have_v4 ? 1u : 0u);
    T_EQ_U(di.v6_valid, r.have_v6 ? 1u : 0u);
    T_EQ_U(usernet_dns_server(un), di.v4_addr);
    T_NOTE("backend reports v4_valid=%u v6_valid=%u ipv6_guest=%u nat64=%u",
           di.v4_valid, di.v6_valid, di.ipv6_guest_enabled, di.nat64_active);
    usernet_destroy(un);
    free(g);
}

#ifdef FLOE_USERNET_TEST_HOOKS
/* ================= layer B: mapping decision logic ================= */

static void test_nat64_exclusions(void) {
    T_BEGIN("B: NAT64 excludes specials but not RFC1918 private LANs");

    VGuest *g = calloc(1, sizeof(*g));
    vg_init(g);
    uint8_t mac[6] = VG_MAC_GUEST;
    struct UserNet *un = usernet_new(vg_output, g, mac, 0);
    T_CHECK(un != NULL);
    if (!un) { free(g); return; }
    un_host_nat64_flush(un);
    un_host_reset_nat64_map();     /* use the real getaddrinfo path */

    static const char *excluded[] = {
        "127.0.0.1", "127.5.6.7",        /* loopback        */
        "169.254.1.1",                   /* link-local      */
        "224.0.0.1", "239.1.2.3",        /* multicast       */
        "255.255.255.255",               /* broadcast       */
        "0.0.0.0",                       /* unspecified     */
        "10.0.2.15",                     /* the guest virtual /24 only */
        "192.0.0.1",                     /* DSLite 192.0.0.0/29 */
        "192.88.99.1",                   /* 6to4 relay anycast */
    };
    for (unsigned i = 0; i < sizeof(excluded) / sizeof(excluded[0]); i++) {
        struct in_addr a;
        T_CHECK(inet_pton(AF_INET, excluded[i], &a) == 1);
        struct in6_addr out;
        memset(&out, 0, sizeof(out));
        int rc = un_host_nat64_lookup(un, &a, &out);
        if (rc != 0) {
            fprintf(stderr, "  exclusion %s returned %d\n", excluded[i], rc);
        }
        T_EQ_U(rc, 0);
    }
    T_NOTE("%zu addresses correctly never mapped",
           sizeof(excluded) / sizeof(excluded[0]));
    usernet_destroy(un);
    free(g);
}

static void test_nat64_private_lan_mapping(void) {
    T_BEGIN("B: RFC1918 private LAN destinations are eligible for NAT64");

    VGuest *g = calloc(1, sizeof(*g));
    vg_init(g);
    uint8_t mac[6] = VG_MAC_GUEST;
    struct UserNet *un = usernet_new(vg_output, g, mac, 0);
    T_CHECK(un != NULL);
    if (!un) { free(g); return; }
    un_host_nat64_flush(un);
    g_map_result = 1;
    g_map_calls = 0;
    un_host_set_nat64_map(inj_map, NULL);

    static const char *private_targets[] = {
        "10.1.2.3", "172.16.0.1", "192.168.100.1"
    };
    for (unsigned i = 0; i < sizeof(private_targets) / sizeof(private_targets[0]); i++) {
        struct in_addr v4;
        T_CHECK(inet_pton(AF_INET, private_targets[i], &v4) == 1);
        T_CHECK(inet_pton(AF_INET6, "2001:db8:4444::", &g_map_to) == 1);
        memcpy(&g_map_to.s6_addr[12], &v4.s_addr, 4);
        struct in6_addr out;
        memset(&out, 0, sizeof(out));
        T_EQ_U(un_host_nat64_lookup(un, &v4, &out), 1);
        T_MEM_EQ(out.s6_addr, g_map_to.s6_addr, 16);
    }
    T_EQ_U(g_map_calls, 3);
    T_NOTE("10/8, 172.16/12 and 192.168/16 all reached the platform mapper");

    un_host_reset_nat64_map();
    un_host_nat64_flush(un);
    usernet_destroy(un);
    free(g);
}

static void test_nat64_default_path_honest(void) {
    T_BEGIN("B: default family-neutral AI_DEFAULT getaddrinfo path reports reality");

    VGuest *g = calloc(1, sizeof(*g));
    vg_init(g);
    uint8_t mac[6] = VG_MAC_GUEST;
    struct UserNet *un = usernet_new(vg_output, g, mac, 0);
    T_CHECK(un != NULL);
    if (!un) { free(g); return; }
    un_host_nat64_flush(un);
    un_host_reset_nat64_map();

    /* example.com's well-known address. On an ordinary dual-stack or IPv4
     * network getaddrinfo(AI_DEFAULT|AF_UNSPEC) returns the IPv4 address
     * itself, so there is NO mapping and the backend must say so rather than
     * inventing a 64:ff9b::/96 address. */
    struct in_addr a;
    T_CHECK(inet_pton(AF_INET, "93.184.216.34", &a) == 1);
    struct in6_addr out;
    memset(&out, 0, sizeof(out));
    int rc = un_host_nat64_lookup(un, &a, &out);
    T_NOTE("un_host_nat64_lookup(93.184.216.34) = %d (1=mapped, 0=none)", rc);
    T_CHECK(rc == 0 || rc == 1);
    T_EQ_U(un_host_nat64_active(un), rc == 1 ? 1u : 0u);
    if (rc == 0) {
        T_EQ_U(un_host_nat64_prefix(un, &out), 0);
        T_NOTE("this host is NOT behind DNS64/NAT64: real-network acceptance "
               "stays open (gate G3), not passed");
    } else {
        char buf[INET6_ADDRSTRLEN];
        inet_ntop(AF_INET6, &out, buf, sizeof(buf));
        unsigned plen = un_host_nat64_prefix(un, &out);
        T_NOTE("host DOES synthesize: %s prefix_len=%u", buf, plen);
        T_CHECK(plen == 96 || plen == 128);
    }
    /* A hardcoded prefix must never appear unless the platform produced it. */
    if (rc == 0) {
        static const uint8_t wkp[12] = {0,0,0,0,0,0,0,0,0,0,0,0};
        struct in6_addr p;
        un_host_nat64_prefix(un, &p);
        T_MEM_EQ(p.s6_addr, wkp, 12);
    }
    usernet_destroy(un);
    free(g);
}

static void test_nat64_injected_mapping(void) {
    T_BEGIN("B: injected mapping, per-instance cache, TTL and prefix reporting");

    VGuest *g = calloc(1, sizeof(*g));
    vg_init(g);
    uint8_t mac[6] = VG_MAC_GUEST;
    struct UserNet *un = usernet_new(vg_output, g, mac, 0);
    T_CHECK(un != NULL);
    if (!un) { free(g); return; }
    un_host_nat64_flush(un);
    g_map_result = 1;
    g_map_calls = 0;
    /* A /96 synthesis of 93.184.216.34 in a NON-well-known prefix, to prove the
     * prefix is read from the platform answer and never assumed. */
    T_CHECK(inet_pton(AF_INET6, "2001:db8:1234:5678::", &g_map_to) == 1);
    uint8_t tail[4];
    struct in_addr v4;
    T_CHECK(inet_pton(AF_INET, "93.184.216.34", &v4) == 1);
    memcpy(tail, &v4.s_addr, 4);
    memcpy(&g_map_to.s6_addr[12], tail, 4);
    un_host_set_nat64_map(inj_map, NULL);

    struct in6_addr out;
    memset(&out, 0, sizeof(out));
    int rc = un_host_nat64_lookup(un, &v4, &out);
    T_EQ_U(rc, 1);
    T_EQ_U(g_map_calls, 1);
    T_MEM_EQ(out.s6_addr, g_map_to.s6_addr, 16);
    T_CHECK(un_host_nat64_active(un));

    struct in6_addr pfx;
    unsigned plen = un_host_nat64_prefix(un, &pfx);
    T_EQ_U(plen, 96);
    T_MEM_EQ(pfx.s6_addr, g_map_to.s6_addr, 12);
    static const uint8_t zero4[4] = {0, 0, 0, 0};
    T_MEM_EQ(pfx.s6_addr + 12, zero4, 4);
    char pbuf[INET6_ADDRSTRLEN];
    inet_ntop(AF_INET6, &pfx, pbuf, sizeof(pbuf));
    T_NOTE("observed prefix %s/%u (derived from the answer, never hardcoded)",
           pbuf, plen);

    /* Cached: a second lookup must not re-enter the mapping function. */
    memset(&out, 0, sizeof(out));
    rc = un_host_nat64_lookup(un, &v4, &out);
    T_EQ_U(rc, 1);
    T_EQ_U(g_map_calls, 1);
    T_MEM_EQ(out.s6_addr, g_map_to.s6_addr, 16);

    /* A non-/96 synthesis is reported as a full observed address rather than
     * an invented prefix length. */
    un_host_nat64_flush(un);
    T_CHECK(inet_pton(AF_INET6, "2001:db8:9999::abcd", &g_map_to) == 1);
    g_map_calls = 0;
    rc = un_host_nat64_lookup(un, &v4, &out);
    T_EQ_U(rc, 1);
    plen = un_host_nat64_prefix(un, &pfx);
    T_EQ_U(plen, 128);
    T_NOTE("non-/96 synthesis reported as /%u (no prefix invented)", plen);

    /* "No mapping" is negatively cached, then expires. */
    un_host_nat64_flush(un);
    g_map_result = 0;
    g_map_calls = 0;
    T_EQ_U(un_host_nat64_lookup(un, &v4, &out), 0);
    T_EQ_U(un_host_nat64_lookup(un, &v4, &out), 0);
    T_EQ_U(g_map_calls, 1);
    T_NOTE("negative result cached: 2 lookups, %d mapping calls", g_map_calls);

    /* A mapping failure degrades to plain IPv4 rather than failing the flow. */
    un_host_nat64_flush(un);
    g_map_result = -EHOSTUNREACH;
    g_map_calls = 0;
    T_EQ_U(un_host_nat64_lookup(un, &v4, &out), 0);
    T_EQ_U(g_map_calls, 1);

    un_host_nat64_flush(un);
    un_host_reset_nat64_map();
    T_EQ_U(un_host_nat64_active(un), 0u);
    usernet_destroy(un);
    free(g);
}

static void test_nat64_instance_isolation(void) {
    T_BEGIN("B: NAT64 cache and observed prefix are isolated per UserNet");

    VGuest *g1 = calloc(1, sizeof(*g1));
    VGuest *g2 = calloc(1, sizeof(*g2));
    vg_init(g1);
    vg_init(g2);
    uint8_t mac[6] = VG_MAC_GUEST;
    struct UserNet *un1 = usernet_new(vg_output, g1, mac, 0);
    struct UserNet *un2 = usernet_new(vg_output, g2, mac, 0);
    T_CHECK(un1 != NULL);
    T_CHECK(un2 != NULL);
    if (!un1 || !un2) {
        usernet_destroy(un1);
        usernet_destroy(un2);
        free(g1);
        free(g2);
        return;
    }

    struct in_addr v4;
    T_CHECK(inet_pton(AF_INET, "93.184.216.34", &v4) == 1);
    g_map_result = 1;
    g_map_calls = 0;
    T_CHECK(inet_pton(AF_INET6, "2001:db8:1111::", &g_map_to) == 1);
    memcpy(&g_map_to.s6_addr[12], &v4.s_addr, 4);
    struct in6_addr map1 = g_map_to;
    un_host_set_nat64_map(inj_map, NULL);
    un_host_nat64_flush(un1);
    un_host_nat64_flush(un2);

    struct in6_addr out1, out2;
    memset(&out1, 0, sizeof(out1));
    memset(&out2, 0, sizeof(out2));
    T_EQ_U(un_host_nat64_lookup(un1, &v4, &out1), 1);
    T_EQ_U(g_map_calls, 1);
    T_MEM_EQ(out1.s6_addr, map1.s6_addr, 16);

    /* The same IPv4 key on another VM must call the mapper again and receive
     * that VM's current answer, not the first VM's cached address. */
    T_CHECK(inet_pton(AF_INET6, "2001:db8:2222::", &g_map_to) == 1);
    memcpy(&g_map_to.s6_addr[12], &v4.s_addr, 4);
    struct in6_addr map2 = g_map_to;
    T_EQ_U(un_host_nat64_lookup(un2, &v4, &out2), 1);
    T_EQ_U(g_map_calls, 2);
    T_MEM_EQ(out2.s6_addr, map2.s6_addr, 16);

    memset(&out1, 0, sizeof(out1));
    T_EQ_U(un_host_nat64_lookup(un1, &v4, &out1), 1);
    T_EQ_U(g_map_calls, 2);
    T_MEM_EQ(out1.s6_addr, map1.s6_addr, 16);
    struct in6_addr prefix;
    T_EQ_U(un_host_nat64_prefix(un1, &prefix), 96);
    T_MEM_EQ(prefix.s6_addr, map1.s6_addr, 12);
    T_EQ_U(un_host_nat64_prefix(un2, &prefix), 96);
    T_MEM_EQ(prefix.s6_addr, map2.s6_addr, 12);

    un_host_nat64_flush(un1);
    T_EQ_U(un_host_nat64_active(un1), 0u);
    T_EQ_U(un_host_nat64_active(un2), 1u);
    T_NOTE("same IPv4 key retained independent IPv6 answers across two VMs");

    un_host_reset_nat64_map();
    usernet_destroy(un1);
    usernet_destroy(un2);
    free(g1);
    free(g2);
}

static void test_injected_resolver_reporting(void) {
    T_BEGIN("B: injected resolver reaches the public DNS getters");

    set_inj_resolver("203.0.113.53", "2001:db8::53");
    un_host_set_resolver_probe(inj_probe, NULL);
    g_inj_calls = 0;

    VGuest *g = calloc(1, sizeof(*g));
    vg_init(g);
    uint8_t mac[6] = VG_MAC_GUEST;
    struct UserNet *un = usernet_new(vg_output, g, mac, 0);
    T_CHECK(un != NULL);
    if (!un) { free(g); return; }

    UserNetDnsInfo di;
    memset(&di, 0, sizeof(di));
    di.struct_size = sizeof(di);
    T_EQ_U(usernet_get_dns_info(un, &di), 0);
    T_EQ_U(di.v4_valid, 1);
    T_CHECK(di.v4_addr == 0xcb007135u);       /* 203.0.113.53 host order */
    T_EQ_U(di.v6_valid, 1);
    struct in6_addr want6;
    T_CHECK(inet_pton(AF_INET6, "2001:db8::53", &want6) == 1);
    T_MEM_EQ(di.v6_addr, want6.s6_addr, 16);
    T_EQ_U(usernet_dns_server(un), di.v4_addr);
    T_NOTE("injected dual-stack resolver reported through the public getters");

    usernet_destroy(un);

    /* IPv6-only resolver: the IPv4 field must stay 0 (never faked as the
     * guest-visible 10.0.2.3) while availability is still true. */
    set_inj_resolver(NULL, "2001:db8::53");
    un = usernet_new(vg_output, g, mac, 0);
    T_CHECK(un != NULL);
    if (un) {
        memset(&di, 0, sizeof(di));
        di.struct_size = sizeof(di);
        T_EQ_U(usernet_get_dns_info(un, &di), 0);
        T_EQ_U(di.v4_valid, 0);
        T_EQ_U(di.v4_addr, 0);
        T_EQ_U(usernet_dns_server(un), 0);
        T_EQ_U(di.v6_valid, 1);
        T_CHECK(di.v4_addr != VG_IP_DNS);   /* never dress 10.0.2.3 as a host DNS */
        T_NOTE("IPv6-only resolver: v4 field honestly 0, v6_valid=1");
        usernet_destroy(un);
    }

    /* No resolver at all: refuse honestly, never fabricate. */
    set_inj_resolver(NULL, NULL);
    un = usernet_new(vg_output, g, mac, 0);
    T_CHECK(un != NULL);
    if (un) {
        memset(&di, 0, sizeof(di));
        di.struct_size = sizeof(di);
        T_EQ_U(usernet_get_dns_info(un, &di), 0);
        T_EQ_U(di.v4_valid, 0);
        T_EQ_U(di.v6_valid, 0);
        T_EQ_U(usernet_dns_server(un), 0);
        T_NOTE("no resolver: DNS reported unavailable, nothing fabricated");
        usernet_destroy(un);
    }

    un_host_reset_resolver_probe();
    free(g);
}
#endif /* FLOE_USERNET_TEST_HOOKS */

/* ================= layer C: the patch must be compiled AND called ========== */

static void test_hooks_present(void) {
    T_BEGIN("C: libslirp host-hook patch presence");
#ifdef SLIRP_FLOE_HOST_HOOKS
    T_NOTE("built against PATCHED libslirp: SLIRP_FLOE_HOST_HOOKS is defined");
    T_CHECK(1);
#else
    T_NOTE("built against STOCK libslirp: the hook layer is compiled out and "
           "layer-C assertions below are skipped, NOT passed");
    T_CHECK(1);
#endif
}

#ifdef SLIRP_FLOE_HOST_HOOKS
static int64_t v6_listener_port;
static int v6_listener = -1;
static int v6_conn = -1;
static uint8_t v6_buf[65536];
static size_t v6_got;

static void v6_echo_service(void *ctx) {
    (void)ctx;
    if (v6_listener >= 0 && v6_conn < 0) {
        int c = accept(v6_listener, NULL, NULL);
        if (c >= 0) { tu_set_nonblock(c); v6_conn = c; }
    }
    if (v6_conn < 0) return;
    for (;;) {
        ssize_t n = recv(v6_conn, v6_buf + v6_got, sizeof(v6_buf) - v6_got, 0);
        if (n > 0) {
            size_t base = v6_got;
            v6_got += (size_t)n;
            size_t off = 0;
            while (off < (size_t)n) {
                ssize_t w = send(v6_conn, v6_buf + base + off, (size_t)n - off, 0);
                if (w <= 0) break;
                off += (size_t)w;
            }
            continue;
        }
        break;
    }
}

/* The whole point of the patch: a guest that only speaks IPv4 reaches a
 * destination over a real AF_INET6 host socket, because the embedder resolved a
 * DNS64-synthesized address for it. The guest never learns IPv6 exists. */
static void test_nat64_end_to_end(void) {
    T_BEGIN("C: guest IPv4 TCP carried over an AF_INET6 host socket (NAT64)");

    /* Real IPv6 listener on loopback. */
    v6_listener = socket(AF_INET6, SOCK_STREAM, 0);
    if (v6_listener < 0) { T_NOTE("no IPv6 socket support: %s", strerror(errno)); T_CHECK(0); return; }
    int one = 1;
    setsockopt(v6_listener, IPPROTO_IPV6, IPV6_V6ONLY, &one, sizeof(one));
    setsockopt(v6_listener, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in6 sa6;
    memset(&sa6, 0, sizeof(sa6));
    sa6.sin6_family = AF_INET6;
    sa6.sin6_addr = in6addr_loopback;
    sa6.sin6_port = 0;
    if (bind(v6_listener, (struct sockaddr *)&sa6, sizeof(sa6)) < 0) {
        T_NOTE("bind [::1] failed: %s", strerror(errno));
        close(v6_listener); v6_listener = -1; T_CHECK(0); return;
    }
    socklen_t sl = sizeof(sa6);
    getsockname(v6_listener, (struct sockaddr *)&sa6, &sl);
    v6_listener_port = ntohs(sa6.sin6_port);
    listen(v6_listener, 4);
    tu_set_nonblock(v6_listener);
    T_NOTE("real IPv6 echo listener on [::1]:%lld", (long long)v6_listener_port);

    VGuest *g = calloc(1, sizeof(*g));
    vg_init(g);
    uint8_t mac[6] = VG_MAC_GUEST;
    struct UserNet *un = usernet_new(vg_output, g, mac, 0);
    T_CHECK(un != NULL);
    if (!un) { close(v6_listener); free(g); return; }
    T_CHECK(tu_boot(g, un));

#ifdef FLOE_USERNET_TEST_HOOKS
    /* Inject the platform mapping we do not have on this network: the public
     * IPv4 literal the guest dials maps onto ::1, where the real listener is. */
    un_host_nat64_flush(un);
    g_map_result = 1;
    g_map_calls = 0;
    memset(&g_map_to, 0, sizeof(g_map_to));
    g_map_to = in6addr_loopback;
    un_host_set_nat64_map(inj_map, NULL);
#endif

    uint16_t dport = (uint16_t)v6_listener_port;
    g->conn.echo_on = false;
    vg_tcp_connect(g, un, tu_emit, 0x5db8d822u /* 93.184.216.34 */, dport, 47777);

    struct pollfd lpf = { .fd = v6_listener, .events = POLLIN };
    bool est = vg_pump(g, un, tu_emit, &lpf, 1, v6_echo_service, NULL,
                       tu_pred_est, g, 6000);
    T_CHECK(est);
    T_CHECK(v6_conn >= 0);
    T_NOTE("guest IPv4 connection established over IPv6: host side fd=%d", v6_conn);

    static uint8_t pattern[8192];
    tu_fill_pattern(pattern, sizeof(pattern), 0xA76A76);
    uint64_t want = tu_fnv64(pattern, sizeof(pattern));
    vg_tcp_send(g, un, tu_emit, pattern, sizeof(pattern));

    uint32_t target = (uint32_t)sizeof(pattern);
    bool got = false;
    for (int round = 0; round < 400 && !got; round++) {
        for (int k = 0; k < 30; k++) {
            usernet_poll(un);
            vg_drain(g, un, tu_emit);
            v6_echo_service(NULL);
            if (g->conn.rxlen >= target) { got = true; break; }
        }
        if (!got) {
            struct pollfd p2 = { .fd = v6_conn, .events = POLLIN };
            if (v6_conn >= 0) poll(&p2, 1, 20);
        }
    }
    T_CHECK(got);
    T_EQ_U(g->conn.rxlen, sizeof(pattern));
    T_EQ_U(tu_fnv64(g->conn.rx, sizeof(pattern)), want);
    T_EQ_U(v6_got, sizeof(pattern));
    T_NOTE("8KiB echoed guest(IPv4) <-> host(IPv6), digest %016llx matched",
           (unsigned long long)want);

    uint64_t refused = 0, mapped = 0, dnsu = 0;
    usernet_get_hook_stats(un, &refused, &mapped, &dnsu);
    T_NOTE("hook counters: admit_refused=%llu nat64_mapped=%llu dns_used=%llu",
           (unsigned long long)refused, (unsigned long long)mapped,
           (unsigned long long)dnsu);
    T_CHECK(mapped > 0);          /* the patch really called our mapping hook */

    if (v6_conn >= 0) close(v6_conn);
    close(v6_listener);
    v6_conn = -1; v6_listener = -1; v6_got = 0;
    un_host_reset_nat64_map();
    usernet_destroy(un);
    free(g);
}

typedef struct {
    int fd;
    uint8_t bytes[1600];
    size_t got;
    unsigned packets;
} V6UdpEcho;

typedef struct {
    VGuest *g;
    uint32_t want;
} V6DgramWait;

static bool v6_pred_dgram(void *ctx) {
    V6DgramWait *w = ctx;
    return w->g->dgram_count >= w->want;
}

static void v6_udp_echo_service(void *ctx) {
    V6UdpEcho *e = ctx;
    for (;;) {
        struct sockaddr_in6 from;
        socklen_t from_len = sizeof(from);
        ssize_t n = recvfrom(e->fd, e->bytes, sizeof(e->bytes), 0,
                             (struct sockaddr *)&from, &from_len);
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) break;
        if (n <= 0) break;
        e->got = (size_t)n;
        e->packets++;
        ssize_t off = 0;
        while (off < n) {
            ssize_t w = sendto(e->fd, e->bytes + off, (size_t)(n - off), 0,
                               (struct sockaddr *)&from, from_len);
            if (w <= 0) break;
            off += w;
        }
    }
}

static int v6_udp_echo_open(V6UdpEcho *e, uint16_t *port) {
    memset(e, 0, sizeof(*e));
    e->fd = socket(AF_INET6, SOCK_DGRAM, 0);
    if (e->fd < 0) return -1;
    int one = 1;
    setsockopt(e->fd, IPPROTO_IPV6, IPV6_V6ONLY, &one, sizeof(one));
    struct sockaddr_in6 sa;
    memset(&sa, 0, sizeof(sa));
    sa.sin6_family = AF_INET6;
    sa.sin6_addr = in6addr_loopback;
    if (bind(e->fd, (struct sockaddr *)&sa, sizeof(sa)) != 0) {
        close(e->fd);
        e->fd = -1;
        return -1;
    }
    socklen_t sl = sizeof(sa);
    if (getsockname(e->fd, (struct sockaddr *)&sa, &sl) != 0) {
        close(e->fd);
        e->fd = -1;
        return -1;
    }
    *port = ntohs(sa.sin6_port);
    tu_set_nonblock(e->fd);
    return 0;
}

/* UDP uses sendto()/recvfrom(), not TCP's connect() path. This proves the
 * translated host destination is consumed exactly once and that the reply is
 * restored to the guest-visible IPv4 tuple. */
static void test_nat64_udp_end_to_end(void) {
    T_BEGIN("C: guest IPv4 UDP carried over an AF_INET6 host socket (NAT64)");

    V6UdpEcho echo;
    uint16_t dport = 0;
    T_EQ_U(v6_udp_echo_open(&echo, &dport), 0);
    if (echo.fd < 0) return;

    VGuest *g = calloc(1, sizeof(*g));
    vg_init(g);
    uint8_t mac[6] = VG_MAC_GUEST;
    struct UserNet *un = usernet_new(vg_output, g, mac, 0);
    T_CHECK(un != NULL);
    if (!un) { close(echo.fd); free(g); return; }
    T_CHECK(tu_boot(g, un));

    un_host_nat64_flush(un);
    g_map_result = 1;
    g_map_calls = 0;
    g_map_to = in6addr_loopback;
    un_host_set_nat64_map(inj_map, NULL);

    uint16_t sport = 47888;
    static uint8_t payload[1200];
    tu_fill_pattern(payload, sizeof(payload), 0x64d0);
    uint8_t frame[VG_MAX_FRAME];
    /* A private-LAN destination must also reach the platform mapper; Darwin
     * does not exclude RFC1918 from NAT64 synthesis. */
    uint32_t private_dst = 0xc0a83214u;  /* 192.168.50.20 */
    size_t n = vg_udp(g, frame, VG_IP_GUEST, private_dst, sport, dport,
                      payload, sizeof(payload));
    T_CHECK(n > 0);
    tu_emit(un, frame, n);

    V6DgramWait wait = { .g = g, .want = 1 };
    struct pollfd pfd = { .fd = echo.fd, .events = POLLIN };
    bool got = vg_pump(g, un, tu_emit, &pfd, 1, v6_udp_echo_service, &echo,
                       v6_pred_dgram, &wait, 5000);
    T_CHECK(got);
    T_EQ_U(echo.packets, 1);
    T_EQ_U(echo.got, sizeof(payload));
    T_MEM_EQ(echo.bytes, payload, sizeof(payload));
    const VDatagram *reply = vg_dgram_last(g, sport);
    T_CHECK(reply != NULL);
    if (reply) {
        T_EQ_U(reply->src_ip, private_dst); /* guest tuple is unchanged */
        T_EQ_U(reply->sport, dport);
        T_EQ_U(reply->len, sizeof(payload));
        T_MEM_EQ(reply->payload, payload, sizeof(payload));
    }
    uint64_t mapped = 0;
    usernet_get_hook_stats(un, NULL, &mapped, NULL);
    T_CHECK(mapped > 0);
    T_NOTE("1200B UDP echoed through real IPv6 host socket, mapped=%llu",
           (unsigned long long)mapped);

    un_host_reset_nat64_map();
    un_host_nat64_flush(un);
    usernet_destroy(un);
    close(echo.fd);
    free(g);
}

/* An IPv4-only guest still uses 10.0.2.3:53 on an IPv6-only host. The host
 * resolver is a real IPv6 UDP endpoint on a nonprivileged ephemeral port, so
 * this exercises the DNS relay path without depending on an external network. */
static void test_ipv4_guest_dns_over_ipv6(void) {
    T_BEGIN("C: IPv4 guest virtual DNS relays over a real IPv6 resolver socket");

    V6UdpEcho resolver;
    uint16_t resolver_port = 0;
    T_EQ_U(v6_udp_echo_open(&resolver, &resolver_port), 0);
    if (resolver.fd < 0) return;

    set_inj_resolver(NULL, "::1");
    g_inj_v6_port = resolver_port;
    un_host_set_resolver_probe(inj_probe, NULL);

    VGuest *g = calloc(1, sizeof(*g));
    vg_init(g);
    uint8_t mac[6] = VG_MAC_GUEST;
    struct UserNet *un = usernet_new(vg_output, g, mac, 0);
    T_CHECK(un != NULL);
    if (!un) {
        un_host_reset_resolver_probe();
        close(resolver.fd);
        free(g);
        return;
    }
    T_CHECK(tu_boot(g, un));
    UserNetDnsInfo di;
    memset(&di, 0, sizeof(di));
    T_EQ_U(usernet_get_dns_info(un, &di), 0);
    T_EQ_U(di.v4_valid, 0);
    T_EQ_U(di.v4_addr, 0);
    T_EQ_U(di.v6_valid, 1);
    T_EQ_U(ntohs(di.v6_port), resolver_port);

    uint16_t sport = 47889;
    uint8_t frame[VG_MAX_FRAME];
    size_t n = vg_dns_query_a(g, frame, VG_IP_GUEST, sport, 0x6464,
                              "example.invalid");
    T_CHECK(n > 14 + 20 + 8);
    tu_emit(un, frame, n);
    size_t query_len = n - 14 - 20 - 8;

    V6DgramWait wait = { .g = g, .want = 1 };
    struct pollfd pfd = { .fd = resolver.fd, .events = POLLIN };
    bool got = vg_pump(g, un, tu_emit, &pfd, 1, v6_udp_echo_service, &resolver,
                       v6_pred_dgram, &wait, 5000);
    T_CHECK(got);
    T_EQ_U(resolver.packets, 1);
    T_EQ_U(resolver.got, query_len);
    T_MEM_EQ(resolver.bytes, frame + 14 + 20 + 8, query_len);
    const VDatagram *reply = vg_dgram_last(g, sport);
    T_CHECK(reply != NULL);
    if (reply) {
        T_EQ_U(reply->src_ip, VG_IP_DNS);
        T_EQ_U(reply->sport, 53);
        T_EQ_U(reply->len, query_len);
        T_MEM_EQ(reply->payload, frame + 14 + 20 + 8, query_len);
    }
    uint64_t dns_used = 0;
    usernet_get_hook_stats(un, NULL, NULL, &dns_used);
    T_CHECK(dns_used > 0);
    T_NOTE("IPv4 DNS tuple preserved over [::1]:%u, dns_used=%llu",
           resolver_port, (unsigned long long)dns_used);

    usernet_destroy(un);
    un_host_reset_resolver_probe();
    close(resolver.fd);
    free(g);
}

/* The inbound accept ceiling through the hook, which stock libslirp cannot do. */
static void test_admit_hook_inbound(void) {
    T_BEGIN("C: listeners stay polled and excess accepts fail fast at the ceiling");

    VGuest *g = calloc(1, sizeof(*g));
    vg_init(g);
    uint8_t mac[6] = VG_MAC_GUEST;
    UserNetConfig cfg;
    memset(&cfg, 0, sizeof(cfg));
    cfg.struct_size = sizeof(cfg);
    cfg.abi = USERNET_CFG_ABI;
    memcpy(cfg.guest_mac, mac, 6);
    cfg.max_sockets = 2;             /* one listener + one accepted flow */
    cfg.poll_capacity = 64;
    struct UserNet *un = usernet_new_with_config(vg_output, g, &cfg);
    T_CHECK(un != NULL);
    if (!un) { free(g); return; }
    T_CHECK(tu_boot(g, un));

    uint16_t hp = tu_reserve_tcp_port();
    T_EQ_U(usernet_add_hostfwd(un, false, hp, 9900), 0);
    uint64_t refused0 = 0;
    usernet_get_hook_stats(un, &refused0, NULL, NULL);

    int clients[24];
    bool closed_by_peer[24];
    memset(closed_by_peer, 0, sizeof(closed_by_peer));
    int nc = 0;
    for (int i = 0; i < 24; i++) {
        int c = socket(AF_INET, SOCK_STREAM, 0);
        if (c < 0) break;
        tu_set_nonblock(c);
        struct sockaddr_in sa;
        memset(&sa, 0, sizeof(sa));
        sa.sin_family = AF_INET;
        sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        sa.sin_port = htons(hp);
        connect(c, (struct sockaddr *)&sa, sizeof(sa));
        clients[nc++] = c;
        for (int k = 0; k < 4; k++) { usernet_poll(un); vg_drain(g, un, tu_emit); }
    }

    UserNetExtStats xs;
    tu_ext(un, &xs);
    uint64_t refused1 = 0;
    usernet_get_hook_stats(un, &refused1, NULL, NULL);
    T_NOTE("ceiling=%u live=%u max_live=%u suppressed=%llu hook_refused=%llu",
           xs.socket_ceiling, xs.live_sockets, xs.max_live_sockets,
           (unsigned long long)xs.accept_suppressed,
           (unsigned long long)(refused1 - refused0));
    T_CHECK(xs.max_live_sockets <= xs.socket_ceiling);
    T_EQ_U(xs.accept_suppressed, 0); /* no queued-client suppression in hooks-on */
    T_CHECK(refused1 > refused0);

    /* A withheld listener with a larger backlog can leave clients hanging.
     * The production hook instead accepts and closes each excess client, so
     * real host sockets must observe EOF/reset promptly without VM timeouts. */
    int terminal = 0;
    for (int round = 0; round < 100; round++) {
        usernet_poll(un);
        vg_drain(g, un, tu_emit);
        for (int i = 0; i < nc; i++) {
            if (closed_by_peer[i]) continue;
            struct pollfd p = { .fd = clients[i],
                                .events = POLLIN | POLLOUT | POLLERR | POLLHUP };
            poll(&p, 1, 0);
            if (!p.revents) continue;
            char byte;
            ssize_t r = recv(clients[i], &byte, 1, 0);
            if (r == 0 || (r < 0 && errno != EAGAIN && errno != EWOULDBLOCK)) {
                closed_by_peer[i] = true;
                terminal++;
            }
        }
        if (terminal >= nc - 1) break;
        usleep(10000);
    }
    T_CHECK(terminal >= nc - 1);
    T_NOTE("%d/%d excess real host clients observed prompt EOF/reset",
           terminal, nc);

    for (int i = 0; i < nc; i++) close(clients[i]);
    usernet_destroy(un);
    free(g);
}

/* Explicit resolver override, which stock libslirp cannot honour at all. */
static void test_dns_override_hook(void) {
    T_BEGIN("C: explicit resolver override reaches libslirp through the hook");

    VGuest *g = calloc(1, sizeof(*g));
    vg_init(g);
    uint8_t mac[6] = VG_MAC_GUEST;
    UserNetConfig cfg;
    memset(&cfg, 0, sizeof(cfg));
    cfg.struct_size = sizeof(cfg);
    cfg.abi = USERNET_CFG_ABI;
    memcpy(cfg.guest_mac, mac, 6);
    /* A documentation-only address (RFC 5737): no real query is sent, we only
     * assert that libslirp asks the hook for the relay target. */
    cfg.dns_server = "198.51.100.53";
    struct UserNet *un = usernet_new_with_config(vg_output, g, &cfg);
    T_CHECK(un != NULL);
    if (!un) { free(g); return; }
    T_CHECK(tu_boot(g, un));

    UserNetDnsInfo di;
    memset(&di, 0, sizeof(di));
    di.struct_size = sizeof(di);
    T_EQ_U(usernet_get_dns_info(un, &di), 0);
    T_EQ_U(di.v4_valid, 1);
    T_CHECK(di.v4_addr == 0xc6336435u);      /* 198.51.100.53 host order */
    T_EQ_U(usernet_dns_server(un), di.v4_addr);

    /* Send a DNS query for a name; libslirp must consult the override hook to
     * pick the relay target. The query will fail to be answered (the address is
     * documentation-only and unreachable), which is the honest outcome — what
     * is asserted is that the hook ran. */
    uint8_t frame[VG_MAX_FRAME];
    size_t n = vg_dns_query_a(g, frame, VG_IP_GUEST, 44444, 0x4242,
                              "example.invalid");
    tu_emit(un, frame, n);
    for (int i = 0; i < 40; i++) { usernet_poll(un); vg_drain(g, un, tu_emit); }

    uint64_t dnsu = 0;
    usernet_get_hook_stats(un, NULL, NULL, &dnsu);
    T_NOTE("dns override hook invocations = %llu", (unsigned long long)dnsu);
    T_CHECK(dnsu > 0);

    usernet_destroy(un);
    free(g);
}
#endif /* SLIRP_FLOE_HOST_HOOKS */

int main(void) {
    test_real_resolver_discovery();
#ifdef FLOE_USERNET_TEST_HOOKS
    test_nat64_exclusions();
    test_nat64_private_lan_mapping();
    test_nat64_default_path_honest();
    test_nat64_injected_mapping();
    test_nat64_instance_isolation();
    test_injected_resolver_reporting();
#else
    fprintf(stderr, "\n--- injection layer SKIPPED: built without "
                    "-DFLOE_USERNET_TEST_HOOKS ---\n");
#endif
    test_hooks_present();
#ifdef SLIRP_FLOE_HOST_HOOKS
    test_nat64_end_to_end();
    test_nat64_udp_end_to_end();
    test_ipv4_guest_dns_over_ipv6();
    test_admit_hook_inbound();
    test_dns_override_hook();
#else
    fprintf(stderr, "\n--- layer C SKIPPED: linked against STOCK libslirp, the "
                    "host-hook patch is not in this image ---\n");
#endif
    T_EXIT("test_nat64");
}
