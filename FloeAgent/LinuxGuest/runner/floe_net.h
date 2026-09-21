// floe_net.h — Floe Linux guest first-boot network plan (pure helpers).
//
// The TinyEMU guest is attached to the engine's per-VM slirp network
// (10.0.2.0/24, host 10.0.2.2, DHCP pool from 10.0.2.15). There is no init
// system and no DHCP client in the init path, so the Debian userland used to
// boot with eth0 DOWN, no default route and a stale /etc/resolv.conf. apt,
// pip and npm then failed with "Temporary failure in name resolution" even
// though slirp forwarded traffic as soon as an address and route existed.
//
// The engine (adapter/floe_vm.c -> slirp_init) always reserves 10.0.2.3 as
// its name-server alias, and the pinned slirp really does serve it: when the
// guest sends a datagram to the alias, socket.c's sosendto() rewrites the
// destination to the host's own first resolver (get_dns_addr() reads the
// host /etc/resolv.conf) and relays the answer back. Qualification run
// 35500083112 proved this end to end inside the shipped Debian guest: with
// only `nameserver 10.0.2.3` written, apt-get update, an apt install and an
// HTTPS fetch all succeeded. That alias is therefore the first resolver we
// write (and the first we probe); the public resolvers stay behind it so a
// host that cannot resolve still has a working fallback when the network
// allows one.
//
// This header owns the *content* of the first-boot network configuration and
// the status vocabulary. The Linux-only side effects (ioctls, file writes,
// the resolver probe) live in floe_exec.c's guest_bring_up_network(), which
// is compiled out of the native host build. Keeping the rendered files and
// the status mapping here makes them deterministic and testable on the
// developer host without a VM, a network or root:
//
//   make -C FloeAgent/LinuxGuest/runner check-net
//
// Contract:
//   - the guest address, mask and gateway are the slirp defaults, never
//     discovered by scanning;
//   - the resolver file starts with the engine's own alias (10.0.2.3) and
//     then a fixed public list; the readiness probe walks the same ordered
//     list with a per-attempt bound, so a dead resolver costs one bounded
//     probe instead of poisoning every later lookup;
//   - `/etc/resolv.conf`, `/etc/network/interfaces.d/eth0` and
//     `/etc/gitconfig` are rendered completely from this header so the files
//     can be asserted without running the runner;
//   - `net=up` means "interface configured, route installed, resolver file
//     written and one resolver in the ordered list answered a bounded
//     query"; `net=partial` means the interface is configured but no
//     resolver answered within the probe budget; `net=down` means the
//     interface could not be configured at all. The host reports the three
//     states differently and never calls `partial`/`down` ready.

#ifndef FLOE_NET_H
#define FLOE_NET_H

#include <stddef.h>
#include <stdio.h>
#include <string.h>

// Slirp network defaults (ThirdParty/TinyEMU adapter/floe_vm.c).
#define FLOE_NET_GUEST_ADDRESS "10.0.2.15"
#define FLOE_NET_GUEST_PREFIX "24"
#define FLOE_NET_NETMASK "255.255.255.0"
#define FLOE_NET_GATEWAY "10.0.2.2"
#define FLOE_NET_INTERFACE "eth0"

// Resolver plan, in probe order. The first entry is slirp's own alias: the
// engine rewrites it to the host's configured resolver, which is the most
// reliable path on an iPad/CI host and the only one that follows a network
// that forces its own DNS. The four public servers are fallbacks for a host
// whose /etc/resolv.conf cannot be read (slirp then falls back to loopback).
#define FLOE_NET_RESOLVER_SLIRP "10.0.2.3"
#define FLOE_NET_RESOLVER_1 "223.5.5.5"
#define FLOE_NET_RESOLVER_2 "119.29.29.29"
#define FLOE_NET_RESOLVER_3 "8.8.8.8"
#define FLOE_NET_RESOLVER_4 "1.1.1.1"

// Ordered resolver list used by both the rendered file and the probe. Kept as
// accessors (not an array in the header) so the pure check compiles the same
// values floe_exec.c uses without any storage or initialization concerns.
#define FLOE_NET_RESOLVER_COUNT 5

static inline const char *floe_net_resolver_at(size_t index) {
    switch (index) {
    case 0: return FLOE_NET_RESOLVER_SLIRP;
    case 1: return FLOE_NET_RESOLVER_1;
    case 2: return FLOE_NET_RESOLVER_2;
    case 3: return FLOE_NET_RESOLVER_3;
    case 4: return FLOE_NET_RESOLVER_4;
    default: return NULL;
    }
}

// Bounds on the first-boot readiness probe: each resolver gets one short
// query, and only the first few entries are tried so a host with no working
// DNS at all cannot delay the first HELLO answer indefinitely. The values are
// part of every rendered status line, so they are asserted in check-net.
#define FLOE_NET_PROBE_TIMEOUT_SECONDS 2
#define FLOE_NET_PROBE_MAX_ATTEMPTS 4

// Bound on one rendered configuration file. All three files are tiny.
#ifndef FLOE_NET_CONFIG_MAX
#define FLOE_NET_CONFIG_MAX 1024
#endif

typedef enum {
    FLOE_NET_DOWN = 0,   // interface/route configuration failed
    FLOE_NET_PARTIAL = 1, // configured, but the first resolver did not answer
    FLOE_NET_UP = 2       // configured and DNS answered
} floe_net_status;

static inline const char *floe_net_status_text(floe_net_status status) {
    switch (status) {
    case FLOE_NET_UP: return "up";
    case FLOE_NET_PARTIAL: return "partial";
    case FLOE_NET_DOWN:
    default: return "down";
    }
}

// Parses the `net=` field of a host-visible status value. Unknown or missing
// text maps to FLOE_NET_DOWN so a caller can never mistake "I did not hear a
// status" for "the network is ready".
static inline floe_net_status floe_net_status_parse(const char *text) {
    if (text == NULL) return FLOE_NET_DOWN;
    if (strcmp(text, "up") == 0) return FLOE_NET_UP;
    if (strcmp(text, "partial") == 0) return FLOE_NET_PARTIAL;
    return FLOE_NET_DOWN;
}

// /etc/resolv.conf. The engine alias comes first (see the resolver plan
// above) and every public fallback is emitted even when a resolver is
// unreachable: glibc tries them in order, and a partially reachable network
// must not lose the remaining servers.
static inline int floe_net_render_resolv_conf(char *buf, size_t cap) {
    int n = snprintf(buf, cap,
                     "# Written by floe-exec on guest start; edits are replaced.\n"
                     "nameserver " FLOE_NET_RESOLVER_SLIRP "\n"
                     "nameserver " FLOE_NET_RESOLVER_1 "\n"
                     "nameserver " FLOE_NET_RESOLVER_2 "\n"
                     "nameserver " FLOE_NET_RESOLVER_3 "\n"
                     "nameserver " FLOE_NET_RESOLVER_4 "\n");
    return (n > 0 && (size_t)n < cap) ? n : -1;
}

// /etc/network/interfaces.d/eth0, for Debian tools that read the classic
// configuration. The runner does not depend on this file; it is written so a
// user who installs ifupdown sees the same address the guest already has.
static inline int floe_net_render_interfaces(char *buf, size_t cap) {
    int n = snprintf(buf, cap,
                     "# Written by floe-exec on guest start; edits are replaced.\n"
                     "auto " FLOE_NET_INTERFACE "\n"
                     "iface " FLOE_NET_INTERFACE " inet static\n"
                     "    address " FLOE_NET_GUEST_ADDRESS "\n"
                     "    netmask " FLOE_NET_NETMASK "\n"
                     "    gateway " FLOE_NET_GATEWAY "\n");
    return (n > 0 && (size_t)n < cap) ? n : -1;
}

// /etc/gitconfig. The workspace share is a virtio-9p export of a host
// directory: files created by the guest show the host user's uid/gid, so a
// git installed from the guest's apt sources refuses the repository with
// "detected dubious ownership". The guest is a single-user root VM whose only
// writable git surface is the task's own shares, so the system config marks
// both share roots safe. This is a system file, not ~/.gitconfig: it applies
// to root and to any user created inside the guest.
static inline int floe_net_render_gitconfig(char *buf, size_t cap) {
    int n = snprintf(buf, cap,
                     "# Written by floe-exec on guest start; edits are replaced.\n"
                     "[safe]\n"
                     "\tdirectory = /workspace\n"
                     "\tdirectory = /workspace/*\n"
                     "\tdirectory = /floe/env\n"
                     "\tdirectory = /floe/env/*\n");
    return (n > 0 && (size_t)n < cap) ? n : -1;
}

#endif // FLOE_NET_H
