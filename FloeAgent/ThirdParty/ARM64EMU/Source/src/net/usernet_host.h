/* SPDX-License-Identifier: Apache-2.0 */
/* Copyright 2026 Floe contributors */
/* Host resolver discovery and Apple DNS64/NAT64 adaptation for the libslirp
 * backend. Everything here is public iOS/macOS API only:
 *
 *   - res_ninit(3)/res_getservers(3) from <resolv.h> (public on Apple SDKs,
 *     libresolv is linked by libslirp's own meson rule for darwin and ios),
 *   - getaddrinfo(3) with a FAMILY-NEUTRAL ai_family, which is the mechanism
 *     Apple documents for obtaining a DNS64-synthesized address,
 *   - ordinary inet_pton/inet_ntop.
 *
 * No NetworkExtension, no TAP/TUN, no VPN, no private SystemConfiguration or
 * CoreServices symbol, no entitlement, no hardcoded 64:ff9b::/96. The NAT64
 * prefix is only ever OBSERVED from a platform-provided mapping and reported
 * for diagnostics; it is never used to synthesize an address ourselves.
 *
 * Testability: both the resolver probe and the NAT64 mapping are injectable,
 * so the deterministic component tests exercise the real decision logic
 * without requiring an actual IPv6-only/NAT64 network (which this host does
 * not have — see HANDOFF.md, remaining gate G3).
 *
 * SHIPPING DEFAULT vs QUALIFICATION INJECTION
 * -------------------------------------------
 * Every injection point below is compiled in ONLY under
 * -DFLOE_USERNET_TEST_HOOKS. A shipping build contains no resolver-override
 * symbol, no mapping-override symbol and no test-only loopback exception: the
 * symbols do not exist, so they cannot be reached by a guest, by a model
 * output or by an accidentally linked fixture. The qualification harness
 * defines the macro; the App target must not.
 */
#ifndef USERNET_HOST_H
#define USERNET_HOST_H

#include <netinet/in.h>
#include <stdbool.h>
#include <stdint.h>

struct UserNet;

/* ---- discovered host resolvers ------------------------------------------ */
typedef struct UnResolver {
    bool have_v4;
    struct in_addr  v4;
    uint16_t        v4_port;      /* network order */
    bool have_v6;
    struct in6_addr v6;
    uint16_t        v6_port;      /* network order */
    uint32_t        v6_scope;
    /* Where the answer came from, for honest diagnostics. */
    bool from_override;           /* embedder-supplied, not probed */
    bool from_probe;              /* res_ninit / resolv.conf */
    bool probe_failed;            /* no resolver of this family is reachable */
} UnResolver;

#ifdef FLOE_USERNET_TEST_HOOKS
/* Injectable resolver probe. Returns 0 and fills `out` on success, or a
 * negative errno. QUALIFICATION ONLY: absent from a shipping build. */
typedef int (*un_resolver_probe_fn)(UnResolver *out, void *ctx);
void un_host_set_resolver_probe(un_resolver_probe_fn fn, void *ctx);
/* Restore the built-in probe. */
void un_host_reset_resolver_probe(void);
#endif

/* Discover the host resolvers. Uses the injected probe when one is compiled in
 * and installed, otherwise the built-in one. Never fabricates a public
 * resolver: on failure every have_* stays false and the caller must refuse
 * guest DNS honestly. */
int un_host_discover(UnResolver *out);

/* ---- NAT64 mapping ------------------------------------------------------
 *
 * Cache and observed-prefix state belong to one UserNet instance. There is no
 * production process-global cache: two guests cannot reuse each other's mapping
 * after a resolver/network change, and destroying one guest cannot reset
 * another's diagnostic state. Qualification-only mapper injection remains
 * process-global because the component tests are serialized; it is absent from
 * shipping objects.
 */
#define UN_NAT64_CACHE 64
#define UN_NAT64_TTL_MS 60000
#define UN_NAT64_NEG_TTL_MS 5000

typedef struct UnNat64Entry {
    bool            in_use;
    bool            mapped;
    int64_t         expires_ms;
    struct in_addr  v4;
    struct in6_addr v6;
} UnNat64Entry;

typedef struct UnNat64Cache {
    UnNat64Entry entries[UN_NAT64_CACHE];
    unsigned next;
    bool active;
    struct in6_addr prefix;
    unsigned prefix_len;
} UnNat64Cache;

#ifdef FLOE_USERNET_TEST_HOOKS
/* Injectable mapping. Returns 1 and fills `out` when the platform maps this
 * IPv4 destination onto an IPv6 address (DNS64 synthesis), 0 when there is no
 * mapping, or a negative errno. QUALIFICATION ONLY. */
typedef int (*un_nat64_map_fn)(const struct in_addr *v4, struct in6_addr *out,
                               void *ctx);
void un_host_set_nat64_map(un_nat64_map_fn fn, void *ctx);
void un_host_reset_nat64_map(void);
#endif

/* Look up (and cache) the mapping for one IPv4 destination.
 * Returns 1 = mapped, 0 = not mapped, -errno on failure.
 * Loopback, link-local (169.254/16), multicast, broadcast and the virtual
 * network are never mapped: those must keep their IPv4/loopback semantics. */
int un_host_nat64_lookup(struct UserNet *un, const struct in_addr *v4,
                         struct in6_addr *out);

/* True when at least one live mapping is in use on this backend instance. */
bool un_host_nat64_active(struct UserNet *un);
/* Informational only: the prefix observed in a platform-provided mapping.
 * Never used to synthesize anything. Returns 0 when nothing was observed. */
unsigned un_host_nat64_prefix(struct UserNet *un, struct in6_addr *out);

/* Drop this backend's cached mappings (used on guest reset and by tests). */
void un_host_nat64_flush(struct UserNet *un);

#ifdef FLOE_USERNET_TEST_HOOKS
/* QUALIFICATION ONLY: advance the single monotonic clock that feeds both the
 * adapter's timers and libslirp's clock_get_ns(), so timer expiry, socket
 * expiry and RA scheduling can be tested deterministically instead of waiting
 * for libslirp's randomized multi-hundred-second RA interval. These symbols do
 * not exist in a shipping build. */
void un_host_test_advance_clock(int64_t ms);
void un_host_test_reset_clock(void);
int64_t un_host_test_clock_offset_ms(void);
#endif

/* ---- backend integration ------------------------------------------------ */

/* Refresh un->dns from the configured overrides and/or a probe, and publish
 * the atomically readable snapshot. Cheap when the cached probe is fresh. */
void un_host_dns_probe(struct UserNet *un);
/* Host-order IPv4 relay target actually in use, or 0 when IPv4 guest DNS
 * cannot be served. */
uint32_t un_host_dns4(const struct UserNet *un);
/* Install the embedder's explicit resolver overrides into libslirp when the
 * vendor hook patch is compiled in; otherwise record that the override cannot
 * be honoured and report the real target instead. */
void un_host_apply_overrides(struct UserNet *un);
/* Install the embedder hooks into libslirp when it was built with this lane's
 * 0002-floe-host-hooks.patch. A no-op against stock libslirp, so the same
 * adapter source builds either way. */
void un_host_install_hooks(struct UserNet *un);
void un_host_free(struct UserNet *un);

#endif
