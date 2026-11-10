/* SPDX-License-Identifier: Apache-2.0 */
/* Copyright 2026 Floe contributors */
/* Host resolver discovery and Apple DNS64/NAT64 adaptation. See
 * usernet_host.h for the API contract and the Apple-compliance argument. */
#include "usernet_priv.h"
#include "usernet_host.h"

#include <arpa/inet.h>
#include <netdb.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>

#if defined(__APPLE__) || defined(__linux__)
#  if !defined(FLOE_AE_NO_SYSTEM_RESOLVER)
#    define UN_HAVE_RES_NINIT 1
#    include <resolv.h>
#  endif
#endif

/* Rate-limited diagnostics, shared shape with usernet_core.c. */
static int64_t  h_note_window_ms;
static unsigned h_note_count;
static void hnote(const char *fmt, ...) {
    int64_t now = un_now_ms();
    if (now - h_note_window_ms > 5000) { h_note_window_ms = now; h_note_count = 0; }
    if (h_note_count >= 8) return;
    h_note_count++;
    va_list ap; va_start(ap, fmt);
    fprintf(stderr, "[usernet/host] ");
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
    va_end(ap);
}

/* ---- injectable hooks (QUALIFICATION ONLY) -------------------------------
 * Compiled out entirely unless FLOE_USERNET_TEST_HOOKS is defined. A shipping
 * build has no override symbol at all, so the qualification fixtures and any
 * test-only loopback exception can never be reachable in production. */
#ifdef FLOE_USERNET_TEST_HOOKS
static un_resolver_probe_fn g_probe_fn;
static void                *g_probe_ctx;
static un_nat64_map_fn      g_map_fn;
static void                *g_map_ctx;

void un_host_set_resolver_probe(un_resolver_probe_fn fn, void *ctx) {
    g_probe_fn = fn; g_probe_ctx = ctx;
}
void un_host_reset_resolver_probe(void) { g_probe_fn = NULL; g_probe_ctx = NULL; }
void un_host_set_nat64_map(un_nat64_map_fn fn, void *ctx) {
    g_map_fn = fn; g_map_ctx = ctx;
}
void un_host_reset_nat64_map(void) { g_map_fn = NULL; g_map_ctx = NULL; }
#define UN_HAVE_HOOKS 1
#endif

/* ---- built-in resolver probe -------------------------------------------- */

#ifndef FLOE_AE_NO_SYSTEM_RESOLVER
static int probe_resolv_conf(UnResolver *out) {
    FILE *f = fopen("/etc/resolv.conf", "r");
    if (!f) return -ENOENT;
    char line[256];
    while (fgets(line, sizeof(line), f)) {
        char addr[64];
        if (sscanf(line, " nameserver %63s", addr) != 1) continue;
        if (!out->have_v4) {
            struct in_addr a4;
            if (inet_pton(AF_INET, addr, &a4) == 1) {
                if (a4.s_addr != htonl(INADDR_ANY) &&
                    a4.s_addr != htonl(INADDR_LOOPBACK)) {
                    out->v4 = a4;
                    out->v4_port = htons(53);
                    out->have_v4 = true;
                    out->from_probe = true;
                    continue;
                }
            }
        }
        if (!out->have_v6) {
            struct in6_addr a6;
            if (inet_pton(AF_INET6, addr, &a6) == 1) {
                out->v6 = a6;
                out->v6_port = htons(53);
                out->have_v6 = true;
                out->from_probe = true;
            }
        }
    }
    fclose(f);
    return (out->have_v4 || out->have_v6) ? 0 : -ENOENT;
}
#endif

#ifdef UN_HAVE_RES_NINIT
static int probe_res_ninit(UnResolver *out) {
    struct __res_state state;
    union res_sockaddr_union servers[NI_MAXSERV];
    memset(&state, 0, sizeof(state));
    if (res_ninit(&state) != 0) return -EIO;
    int count = res_getservers(&state, servers, NI_MAXSERV);
    for (int i = 0; i < count; i++) {
        if (servers[i].sin.sin_family == AF_INET && !out->have_v4) {
            if (servers[i].sin.sin_addr.s_addr == htonl(INADDR_ANY) ||
                servers[i].sin.sin_addr.s_addr == htonl(INADDR_LOOPBACK))
                continue;
            out->v4 = servers[i].sin.sin_addr;
            out->v4_port = servers[i].sin.sin_port ? servers[i].sin.sin_port
                                                    : htons(53);
            out->have_v4 = true;
            out->from_probe = true;
        } else if (servers[i].sin6.sin6_family == AF_INET6 && !out->have_v6) {
            if (IN6_IS_ADDR_UNSPECIFIED(&servers[i].sin6.sin6_addr) ||
                IN6_IS_ADDR_LOOPBACK(&servers[i].sin6.sin6_addr))
                continue;
            out->v6 = servers[i].sin6.sin6_addr;
            out->v6_port = servers[i].sin6.sin6_port ? servers[i].sin6.sin6_port
                                                     : htons(53);
            out->v6_scope = servers[i].sin6.sin6_scope_id;
            out->have_v6 = true;
            out->from_probe = true;
        }
    }
    res_ndestroy(&state);
    return (out->have_v4 || out->have_v6) ? 0 : -ENOENT;
}
#endif

static int builtin_probe(UnResolver *out) {
    int rc = -ENOENT;
#ifdef UN_HAVE_RES_NINIT
    /* res_ninit is the public per-call resolver state on Apple platforms and
     * is the same mechanism upstream libslirp uses under __APPLE__. */
    rc = probe_res_ninit(out);
#endif
#ifndef FLOE_AE_NO_SYSTEM_RESOLVER
    if (rc != 0) rc = probe_resolv_conf(out);
#endif
    return rc;
}

int un_host_discover(UnResolver *out) {
    if (!out) return -EINVAL;
    memset(out, 0, sizeof(*out));
#ifdef UN_HAVE_HOOKS
    int rc = g_probe_fn ? g_probe_fn(out, g_probe_ctx) : builtin_probe(out);
#else
    int rc = builtin_probe(out);
#endif
    if (rc != 0) {
        out->probe_failed = true;
        return rc;
    }
    return 0;
}

/* ---- NAT64 mapping ------------------------------------------------------ */

/* Never map an address that must keep its IPv4/loopback meaning. Match
 * Darwin's synthesis exclusions rather than inventing a broader private-LAN
 * block: RFC1918 10/8, 172.16/12 and 192.168/16 are intentionally eligible;
 * the platform route/resolver decides whether they can be synthesized. The
 * configured libslirp virtual /24 stays excluded defensively, although the
 * hook normally runs after libslirp has translated its host/DNS specials. */
static bool nat64_excluded(uint32_t host_order) {
    if ((host_order & 0xff000000u) == 0x7f000000u) return true; /* 127/8      */
    if ((host_order & 0xffff0000u) == 0xa9fe0000u) return true; /* 169.254/16 */
    if ((host_order & 0xfffffff8u) == 0xc0000000u) return true; /* DSLite     */
    if ((host_order & 0xffffff00u) == 0xc0586300u) return true; /* 6to4 relay */
    if ((host_order & 0xf0000000u) == 0xe0000000u) return true; /* 224/4 mcast*/
    if (host_order == 0xffffffffu) return true;                 /* broadcast  */
    if ((host_order & 0xff000000u) == 0x00000000u) return true; /* 0/8        */
    if ((host_order & 0xffffff00u) == 0x0a000200u) return true; /* guest /24  */
    return false;
}

static bool in6_is_v4mapped_any(const struct in6_addr *a) {
    /* ::ffff:0:0/96 — a mapped literal, not a NAT64 synthesis. Connecting to
     * it on an IPv6-only host fails exactly like the bare IPv4 would. */
    for (int i = 0; i < 10; i++) if (a->s6_addr[i]) return false;
    return a->s6_addr[10] == 0xff && a->s6_addr[11] == 0xff;
}

static bool in6_is_plain_v6(const struct in6_addr *a) {
    return !IN6_IS_ADDR_UNSPECIFIED(a) && !IN6_IS_ADDR_LOOPBACK(a) &&
           !IN6_IS_ADDR_LINKLOCAL(a) && !in6_is_v4mapped_any(a);
}

/* Default mapping: ask the platform resolver, family-neutrally, for the
 * numeric IPv4 literal. On a DNS64 network Apple's getaddrinfo() returns the
 * synthesized AAAA; on an ordinary dual-stack or IPv4 network it returns the
 * IPv4 address itself and we report "no mapping". The prefix is NEVER
 * hardcoded and NEVER constructed by us.
 *
 * AI_DEFAULT is required on Darwin. AI_NUMERICHOST is deliberately NOT added:
 * Apple OSS si_getaddrinfo.c returns before both NAT64 synthesis passes when
 * that flag is present. The input is still a numeric literal, so this is not a
 * hostname lookup and does not add application-controlled name resolution. */
static int default_nat64_map(const struct in_addr *v4, struct in6_addr *out) {
    char host[INET_ADDRSTRLEN];
    if (!inet_ntop(AF_INET, v4, host, sizeof(host))) return -EINVAL;

    struct addrinfo hints, *res = NULL;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family   = AF_UNSPEC;      /* family-neutral: the whole point */
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_flags    = AI_DEFAULT;     /* Darwin NAT64 synthesis requires this */

    int rc = getaddrinfo(host, NULL, &hints, &res);
    if (rc != 0 || !res) return -EHOSTUNREACH;

    int result = 0;
    for (struct addrinfo *ai = res; ai; ai = ai->ai_next) {
        if (ai->ai_family != AF_INET6) continue;
        if (ai->ai_addrlen < sizeof(struct sockaddr_in6)) continue;
        const struct sockaddr_in6 *s6 = (const struct sockaddr_in6 *)ai->ai_addr;
        if (!in6_is_plain_v6(&s6->sin6_addr)) continue;
        *out = s6->sin6_addr;
        result = 1;
        break;
    }
    freeaddrinfo(res);
    return result;
}

static void nat64_remember_prefix(struct UserNet *un, const struct in_addr *v4,
                                  const struct in6_addr *v6) {
    UnNat64Cache *cache = &un->nat64;
    /* Informational only. Report what the platform actually produced; do not
     * assume the well-known 64:ff9b::/96 and never use this to synthesize an
     * address ourselves.
     *
     * A /96 embedded scheme is one where the mapped address's low 32 bits are
     * exactly the IPv4 address. Comparing the high 96 bits instead would be
     * vacuous — they are equal by construction for any candidate — so compare
     * the embedded suffix. Anything else is reported as the full observed
     * address with /128 rather than an invented prefix length. */
    if (memcmp(&v6->s6_addr[12], &v4->s_addr, 4) == 0) {
        memcpy(cache->prefix.s6_addr, v6->s6_addr, 12);
        memset(&cache->prefix.s6_addr[12], 0, 4);
        cache->prefix_len = 96;
    } else {
        cache->prefix = *v6;
        cache->prefix_len = 128;
    }
}

int un_host_nat64_lookup(struct UserNet *un, const struct in_addr *v4,
                         struct in6_addr *out) {
    if (!un || !v4) return -EINVAL;
    uint32_t ho = ntohl(v4->s_addr);
    if (nat64_excluded(ho)) return 0;

    UnNat64Cache *cache = &un->nat64;
    int64_t now = un_now_ms();
    for (unsigned i = 0; i < UN_NAT64_CACHE; i++) {
        UnNat64Entry *e = &cache->entries[i];
        if (!e->in_use || e->v4.s_addr != v4->s_addr) continue;
        if (e->expires_ms > now) {
            if (e->mapped && out) *out = e->v6;
            return e->mapped ? 1 : 0;
        }
        e->in_use = false;
        break;
    }

    struct in6_addr mapped;
    memset(&mapped, 0, sizeof(mapped));
#ifdef UN_HAVE_HOOKS
    int rc = g_map_fn ? g_map_fn(v4, &mapped, g_map_ctx)
                      : default_nat64_map(v4, &mapped);
#else
    int rc = default_nat64_map(v4, &mapped);
#endif
    bool is_mapped = (rc == 1);
    if (rc < 0) is_mapped = false;      /* resolver failure falls back to IPv4 */

    UnNat64Entry *e = &cache->entries[cache->next];
    cache->next = (cache->next + 1) % UN_NAT64_CACHE;
    e->in_use = true;
    e->mapped = is_mapped;
    e->v4 = *v4;
    e->expires_ms = now + (is_mapped ? UN_NAT64_TTL_MS : UN_NAT64_NEG_TTL_MS);
    if (is_mapped) {
        e->v6 = mapped;
        cache->active = true;
        nat64_remember_prefix(un, v4, &mapped);
        if (out) *out = mapped;
        return 1;
    }
    return 0;
}

bool un_host_nat64_active(struct UserNet *un) {
    if (!un || !un->nat64.active) return false;
    int64_t now = un_now_ms();
    for (unsigned i = 0; i < UN_NAT64_CACHE; i++) {
        const UnNat64Entry *e = &un->nat64.entries[i];
        if (e->in_use && e->mapped && e->expires_ms > now) return true;
    }
    return false;
}

unsigned un_host_nat64_prefix(struct UserNet *un, struct in6_addr *out) {
    if (out) memset(out, 0, sizeof(*out));
    if (!un || !un->nat64.prefix_len) return 0;
    if (out) *out = un->nat64.prefix;
    return un->nat64.prefix_len;
}

void un_host_nat64_flush(struct UserNet *un) {
    if (!un) return;
    memset(&un->nat64, 0, sizeof(un->nat64));
}

/* ---- backend integration ------------------------------------------------ */

void un_host_dns_probe(struct UserNet *un) {
    if (!un) return;
    int64_t now = un_now_ms();
    /* Re-probe at most every 5 s, matching the previous stack's cadence so a
     * network change (Wi-Fi -> cellular, IPv4 -> IPv6-only) is picked up
     * without paying for res_ninit on every tick. */
    if (atomic_load(&un->dns.probed_ok) && now - un->dns.probe_ms < 5000)
        return;
    un->dns.probe_ms = now;
    uint32_t revision = atomic_load_explicit(&un->dns.revision,
                                              memory_order_relaxed);
    atomic_store_explicit(&un->dns.revision, revision + 1,
                          memory_order_release);  /* odd: refresh in progress */

    UnResolver r;
    int rc = un_host_discover(&r);

    /* An explicit embedder override wins over probing. */
    if (un->dns_cfg4) {
        struct in_addr a;
        a.s_addr = htonl(un->dns_cfg4);
        if (!nat64_excluded(un->dns_cfg4)) {
            un->dns.v4_valid = 1;
            un->dns.v4_addr = un->dns_cfg4;
            un->dns.v4_port = htons(53);
        } else {
            un->dns.v4_valid = 0;
            un->dns.v4_addr = 0;
            un->dns.v4_port = 0;
        }
        (void)a;
    } else if (rc == 0 && r.have_v4) {
        un->dns.v4_valid = 1;
        un->dns.v4_addr = ntohl(r.v4.s_addr);
        un->dns.v4_port = r.v4_port;
    } else {
        un->dns.v4_valid = 0;
        un->dns.v4_addr = 0;
        un->dns.v4_port = 0;
    }

    if (un->dns_cfg6) {
        struct in6_addr a6;
        char buf[128];
        strncpy(buf, un->dns_cfg6, sizeof(buf) - 1);
        buf[sizeof(buf) - 1] = '\0';
        char *scope = strchr(buf, '%');
        uint32_t scope_id = 0;
        if (scope) { *scope++ = '\0'; scope_id = (uint32_t)strtoul(scope, NULL, 10); }
        if (inet_pton(AF_INET6, buf, &a6) == 1) {
            un->dns.v6_valid = 1;
            for (unsigned i = 0; i < 16; i++)
                atomic_store(&un->dns.v6_addr[i], a6.s6_addr[i]);
            un->dns.v6_port = htons(53);
            un->dns.v6_scope = scope_id;
        } else {
            un->dns.v6_valid = 0;
            for (unsigned i = 0; i < 16; i++) atomic_store(&un->dns.v6_addr[i], 0);
            un->dns.v6_port = 0;
            un->dns.v6_scope = 0;
            hnote("ignoring unparsable dns_server6");
        }
    } else if (rc == 0 && r.have_v6) {
        un->dns.v6_valid = 1;
        for (unsigned i = 0; i < 16; i++)
            atomic_store(&un->dns.v6_addr[i], r.v6.s6_addr[i]);
        un->dns.v6_port = r.v6_port;
        un->dns.v6_scope = r.v6_scope;
    } else {
        un->dns.v6_valid = 0;
        for (unsigned i = 0; i < 16; i++) atomic_store(&un->dns.v6_addr[i], 0);
        un->dns.v6_port = 0;
        un->dns.v6_scope = 0;
    }

    if (!un->dns.v4_valid && !un->dns.v6_valid) {
        /* Honest refusal. Never substitute a hardcoded public resolver: the
         * previous stack guaranteed this and the guarantee is preserved. */
        static bool warned;
        if (!warned) {
            warned = true;
            hnote("no host resolver discoverable: guest DNS to 10.0.2.3 will "
                  "be refused. Configure one explicitly in the device config.");
        }
    }

    un->dns.nat64_active = un_host_nat64_active(un) ? 1u : 0u;
    struct in6_addr observed_prefix;
    unsigned observed_prefix_len = un_host_nat64_prefix(un, &observed_prefix);
    un->dns.nat64_prefix_len = observed_prefix_len;
    for (unsigned i = 0; i < 16; i++) {
        atomic_store(&un->dns.nat64_prefix[i],
                     observed_prefix_len ? observed_prefix.s6_addr[i] : 0);
    }
    /* Publish an even revision only after every scalar and address byte is
     * visible. usernet_get_dns_info() retries if either revision read differs. */
    atomic_store_explicit(&un->dns.revision, revision + 2,
                          memory_order_release);
    atomic_store(&un->dns.probed_ok, 1u);
    atomic_store(&un->pub_dns_v4, un_host_dns4(un));
}

uint32_t un_host_dns4(const struct UserNet *un) {
    if (!un) return 0;
    return atomic_load(&un->dns.v4_valid) ? atomic_load(&un->dns.v4_addr) : 0u;
}

void un_host_apply_overrides(struct UserNet *un) {
    if (!un) return;
    if (!un->dns_cfg4 && !un->dns_cfg6) return;
#ifdef SLIRP_FLOE_HOST_HOOKS
    /* Nothing to do here: with the host-hook patch present, the override is
     * delivered through the hook table that un_host_install_hooks() installs
     * via slirp_floe_set_hooks(). libslirp's sotranslate_out4/6 then consult
     * hook_dns4_override / hook_dns6_override on the DNS path itself, so the
     * configured resolver really is the one guest DNS relays to. */
    un_host_install_hooks(un);
#else
    /* Without the hook, libslirp relays guest DNS to whatever res_ninit()
     * discovers and the override cannot be honoured. Say so once and report
     * the target that will ACTUALLY be used, rather than claiming a
     * configuration that silently does nothing. */
    static bool noted;
    if (!noted) {
        noted = true;
        hnote("an explicit resolver was configured but this libslirp build has "
              "no override hook; guest DNS relays to the discovered resolver "
              "and usernet_dns_server() reports that real target");
    }
#endif
}

/* ---- libslirp embedder hooks --------------------------------------------
 *
 * Compiled against stock libslirp this whole block is empty and
 * un_host_install_hooks() is a no-op, so the candidate builds and passes its
 * component tests either way. Built against the patched libslirp
 * (patches/0002-floe-host-hooks.patch) it becomes the authoritative enforcement
 * point for the per-VM ceiling — including the inbound accept() path that
 * libslirp drives from its own poll dispatch and that never passes through
 * usernet_input() — plus the explicit-resolver override and the DNS64/NAT64
 * outbound mapping. */
#ifdef SLIRP_FLOE_HOST_HOOKS

static int hook_admit_socket(FloeSlirpSockReason reason, void *ctx) {
    struct UserNet *un = ctx;
    if (!un || un->dead) return 0;
    if (un->live_sockets < un->socket_ceiling && un->fdreg_overflow == 0)
        return 0;
    /* At the ceiling. Every one of these reasons creates a NEW host
     * descriptor, so refusing is correct and fair: established connections are
     * never routed through here. */
    (void)reason;
    un->hook_admit_refused++;
    return -ENFILE;
}

static int hook_map_nat64(const struct in_addr *v4, struct in6_addr *out,
                          void *ctx) {
    struct UserNet *un = ctx;
    int rc = un_host_nat64_lookup(un, v4, out);
    if (rc == 1 && un) {
        un->hook_nat64_mapped++;
        atomic_store(&un->dns.nat64_active, 1u);
    }
    return rc == 1 ? 1 : 0;
}

static int hook_dns4_override(struct in_addr *addr, uint16_t *port, void *ctx) {
    struct UserNet *un = ctx;
    if (!un || !un->dns_cfg4) return 0;      /* fall through to discovery */
    addr->s_addr = htonl(un->dns_cfg4);
    *port = htons(53);
    un->hook_dns_used++;
    return 1;
}

static int hook_dns6_override(struct in6_addr *addr, uint16_t *port,
                              uint32_t *scope, void *ctx) {
    struct UserNet *un = ctx;
    if (!un || !un->dns_cfg6) return 0;
    char buf[128];
    strncpy(buf, un->dns_cfg6, sizeof(buf) - 1);
    buf[sizeof(buf) - 1] = '\0';
    char *sc = strchr(buf, '%');
    uint32_t scope_id = 0;
    if (sc) { *sc++ = '\0'; scope_id = (uint32_t)strtoul(sc, NULL, 10); }
    if (inet_pton(AF_INET6, buf, addr) != 1) return 0;
    *port = htons(53);
    *scope = scope_id;
    un->hook_dns_used++;
    return 1;
}

/* An IPv4-only guest on an IPv6-only host: there is no IPv4 resolver to find,
 * but there may be an IPv6 one. Relay over IPv6 rather than refusing DNS. */
static int hook_dns4_via_nat64(struct in6_addr *v6, uint16_t *port,
                               uint32_t *scope, void *ctx) {
    struct UserNet *un = ctx;
    if (!un) return 0;
    if (atomic_load(&un->dns.v4_valid)) return 0;   /* IPv4 works: use it */
    if (!atomic_load(&un->dns.v6_valid)) return 0;  /* nothing to relay to */
    memcpy(v6, un->dns.v6_addr, 16);
    *port = (uint16_t)atomic_load(&un->dns.v6_port);
    *scope = atomic_load(&un->dns.v6_scope);
    un->hook_dns_used++;
    return 1;
}

void un_host_install_hooks(struct UserNet *un) {
    if (!un || !un->slirp) return;
    memset(&un->floe_hooks, 0, sizeof(un->floe_hooks));
    un->floe_hooks.struct_size = sizeof(un->floe_hooks);
    un->floe_hooks.abi = FLOE_SLIRP_HOOKS_ABI;
    un->floe_hooks.admit_socket = hook_admit_socket;
    un->floe_hooks.map_nat64 = hook_map_nat64;
    un->floe_hooks.dns4_override = hook_dns4_override;
    un->floe_hooks.dns6_override = hook_dns6_override;
    un->floe_hooks.dns4_via_nat64 = hook_dns4_via_nat64;
    un->floe_hooks.ctx = un;
    slirp_floe_set_hooks(un->slirp, &un->floe_hooks);
}

void usernet_get_hook_stats(struct UserNet *un, uint64_t *admit_refused,
                            uint64_t *nat64_mapped, uint64_t *dns_used) {
    if (admit_refused) *admit_refused = un ? un->hook_admit_refused : 0;
    if (nat64_mapped)  *nat64_mapped  = un ? un->hook_nat64_mapped : 0;
    if (dns_used)      *dns_used      = un ? un->hook_dns_used : 0;
}

#else  /* !SLIRP_FLOE_HOST_HOOKS */

void un_host_install_hooks(struct UserNet *un) {
    /* Stock libslirp: no hook surface exists. The adapter still enforces the
     * ceiling at the guest-input boundary and by withholding forwarding
     * listeners from the poll set; the inbound accept() boundary then relies on
     * libslirp's listen(fd, 1) backlog rather than an explicit refusal. */
    (void)un;
}

#endif /* SLIRP_FLOE_HOST_HOOKS */

void un_host_free(struct UserNet *un) {
    /* No descriptor is owned here. Clear only this instance's mapping state;
     * another VM's cache and observed prefix are deliberately independent. */
    un_host_nat64_flush(un);
}
