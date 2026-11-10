/* SPDX-License-Identifier: BSD-3-Clause */
/*
 * Floe embedder hooks for libslirp.
 *
 * Everything in this header is inert unless libslirp is compiled with
 * -DSLIRP_FLOE_HOST_HOOKS. Without that macro the library behaves exactly as
 * upstream and this header declares nothing.
 *
 * Why these three hooks exist
 * ---------------------------
 * 1. admit_socket: upstream libslirp has NO per-instance limit on the number
 *    of host descriptors it will create. An embedded host that runs one VM
 *    inside an app sandbox needs a real, finite ceiling enforced where the
 *    resource is actually created — including the inbound accept() path, which
 *    is driven by libslirp's own poll dispatch and never passes through the
 *    embedder's packet-input entry point. Refusing an inbound connection uses
 *    upstream's own idiom (accept, then immediately close), because that is the
 *    only way to reject a forwarded connection.
 *
 * 2. map_nat64: on an IPv6-only DNS64/NAT64 network an AF_INET connect() to a
 *    public IPv4 literal fails. Apple documents a family-neutral getaddrinfo()
 *    as the way to obtain the synthesized IPv6 address; the embedder performs
 *    that lookup and hands the result back here, so libslirp can create the
 *    host socket in the right family. The prefix is NEVER hardcoded: it is
 *    whatever the platform resolver produced. Guest-visible state (so_fhost,
 *    so_ffamily) is left untouched, so packet demultiplexing and the source
 *    address the guest sees are unchanged.
 *
 * 3. dns4_override / dns6_override: upstream discovers the relay target with
 *    get_dns_addr()/get_dns6_addr() and offers no way to name one. An embedder
 *    that was explicitly configured with a resolver must be able to honour
 *    that configuration instead of silently using something else.
 */
#ifndef FLOE_HOST_NET_H
#define FLOE_HOST_NET_H

#ifdef SLIRP_FLOE_HOST_HOOKS

#include <stdint.h>
#include <netinet/in.h>

/* libslirp.h defines `typedef struct Slirp Slirp;` and includes this header
 * from there, so do not include it back: the guard would make it a no-op and
 * the forward declaration below is all this header needs. */
#ifndef LIBSLIRP_H
#include "libslirp.h"
#endif
typedef struct Slirp Slirp;

#ifdef __cplusplus
extern "C" {
#endif

/* Why libslirp is about to create a host descriptor. */
typedef enum FloeSlirpSockReason {
    FLOE_SLIRP_SOCK_INBOUND_ACCEPT = 1, /* hostfwd listener accepted a client */
    FLOE_SLIRP_SOCK_OUTBOUND_TCP   = 2, /* guest opened a TCP connection    */
    FLOE_SLIRP_SOCK_OUTBOUND_UDP   = 3, /* guest sent a UDP datagram        */
    FLOE_SLIRP_SOCK_OUTBOUND_ICMP  = 4, /* guest sent an ICMPv4 echo        */
    FLOE_SLIRP_SOCK_OUTBOUND_ICMP6 = 5, /* guest sent an ICMPv6 echo        */
} FloeSlirpSockReason;

typedef struct FloeSlirpHooks {
    uint32_t struct_size;   /* == sizeof(FloeSlirpHooks) */
    uint32_t abi;           /* == FLOE_SLIRP_HOOKS_ABI   */

    /* Return 0 to permit, or a negative errno to refuse. A NULL pointer means
     * "always permit". */
    int (*admit_socket)(FloeSlirpSockReason reason, void *ctx);

    /* Return 1 and fill the output address to reach this IPv4 destination
     * through a DNS64/NAT64-synthesized IPv6 address; 0 to keep plain IPv4; negative on
     * error (treated as 0). A NULL pointer means "never map". */
    int (*map_nat64)(const struct in_addr *v4, struct in6_addr *out, void *ctx);

    /* Return 1 and fill the address and port to override the discovered IPv4
     * resolver;
     * 0 to fall through to get_dns_addr(); negative to refuse DNS outright. */
    int (*dns4_override)(struct in_addr *addr, uint16_t *port, void *ctx);

    /* Same for IPv6, with an optional scope id. */
    int (*dns6_override)(struct in6_addr *addr, uint16_t *port,
                         uint32_t *scope, void *ctx);

    /* Return 1 and fill the address, port and scope id to relay an IPv4
     * guest's DNS query to this IPv6 resolver. This is what an IPv6-only host needs when the guest
     * itself is IPv4-only: upstream get_dns_addr() finds no IPv4 resolver, so
     * without this the guest's DNS is refused even though the host can resolve
     * perfectly well over IPv6. Takes precedence over the plain IPv4 path. */
    int (*dns4_via_nat64)(struct in6_addr *v6, uint16_t *port,
                          uint32_t *scope, void *ctx);

    void *ctx;
    uint64_t reserved[4];   /* must be zero */
} FloeSlirpHooks;

#define FLOE_SLIRP_HOOKS_ABI 1u

/* Bounded production listen backlog. Upstream's listen(fd, 1) collapses under
 * a small burst of parallel web clients. This value is used by tcpx_listen(),
 * so both initial hostfwd creation and reset replay receive the same capacity. */
#define FLOE_SLIRP_LISTEN_BACKLOG 128

/* Install (or, with hooks == NULL, clear) the embedder hooks for one instance.
 * Safe to call once after slirp_new() and before any traffic. */
SLIRP_EXPORT
void slirp_floe_set_hooks(Slirp *slirp, const FloeSlirpHooks *hooks);

#ifdef __cplusplus
}
#endif

#endif /* SLIRP_FLOE_HOST_HOOKS */
#endif /* FLOE_HOST_NET_H */
