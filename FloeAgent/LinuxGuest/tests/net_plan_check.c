// net_plan_check.c — native check for the guest first-boot network plan.
//
// Compiles the runner's real floe_net.h (the same header floe_exec.c uses)
// and asserts the exact rendered resolver, interfaces and git files plus the
// status vocabulary. It performs no network call, writes no file and needs no
// root: the Linux-only ioctl path and the bounded resolver probe are compiled
// out of the native build and are NOT covered here (they need a booted
// guest).
//
// Usage:
//   make -C FloeAgent/LinuxGuest/runner check-net
// or directly:
//   cc -std=gnu11 -O2 -Wall -Wextra -Werror -o /tmp/net-plan-check net_plan_check.c

#include <stdio.h>
#include <string.h>

#include "../runner/floe_net.h"

static int g_checks;
static int g_failures;

#define CHECK(condition)                                                      \
    do {                                                                      \
        g_checks++;                                                           \
        if (!(condition)) {                                                   \
            g_failures++;                                                     \
            fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__,           \
                    #condition);                                              \
        }                                                                     \
    } while (0)

static void render_or_fail(const char *label,
                           int (*render)(char *, size_t),
                           char *buf, size_t cap) {
    int n = render(buf, cap);
    g_checks++;
    if (n <= 0 || (size_t)n >= cap) {
        g_failures++;
        fprintf(stderr, "FAIL %s: renderer failed (%d)\n", label, n);
        buf[0] = '\0';
    }
}

static int count_occurrences(const char *text, const char *needle) {
    int count = 0;
    const char *at = text;
    size_t len = strlen(needle);
    while ((at = strstr(at, needle)) != NULL) {
        count++;
        at += len;
    }
    return count;
}

int main(void) {
    char buf[FLOE_NET_CONFIG_MAX];

    // Resolver file: fixed public servers, never slirp's unusable 10.0.2.3,
    // each on its own nameserver line, in the documented order.
    render_or_fail("resolv.conf", floe_net_render_resolv_conf, buf, sizeof buf);
    CHECK(count_occurrences(buf, "nameserver ") == 4);
    CHECK(strstr(buf, "nameserver " FLOE_NET_RESOLVER_1 "\n") != NULL);
    CHECK(strstr(buf, "nameserver " FLOE_NET_RESOLVER_2 "\n") != NULL);
    CHECK(strstr(buf, "nameserver " FLOE_NET_RESOLVER_3 "\n") != NULL);
    CHECK(strstr(buf, "nameserver " FLOE_NET_RESOLVER_4 "\n") != NULL);
    CHECK(strstr(buf, "10.0.2.3") == NULL);
    CHECK(strstr(buf, "defoptions") == NULL);

    // Interfaces file: the slirp defaults, so ifupdown and the runner agree.
    render_or_fail("interfaces", floe_net_render_interfaces, buf, sizeof buf);
    CHECK(strstr(buf, "auto " FLOE_NET_INTERFACE "\n") != NULL);
    CHECK(strstr(buf, "iface " FLOE_NET_INTERFACE " inet static\n") != NULL);
    CHECK(strstr(buf, "address " FLOE_NET_GUEST_ADDRESS "\n") != NULL);
    CHECK(strstr(buf, "netmask " FLOE_NET_NETMASK "\n") != NULL);
    CHECK(strstr(buf, "gateway " FLOE_NET_GATEWAY "\n") != NULL);

    // git config: both 9p share roots are marked safe for the host-owned
    // uids the share reports, so guest git accepts /workspace repositories.
    render_or_fail("gitconfig", floe_net_render_gitconfig, buf, sizeof buf);
    CHECK(strstr(buf, "[safe]\n") != NULL);
    CHECK(strstr(buf, "directory = /workspace\n") != NULL);
    CHECK(strstr(buf, "directory = /workspace/*\n") != NULL);
    CHECK(strstr(buf, "directory = /floe/env\n") != NULL);
    CHECK(strstr(buf, "directory = /floe/env/*\n") != NULL);

    // Status vocabulary: only "up" may be treated as a working network.
    CHECK(strcmp(floe_net_status_text(FLOE_NET_UP), "up") == 0);
    CHECK(strcmp(floe_net_status_text(FLOE_NET_PARTIAL), "partial") == 0);
    CHECK(strcmp(floe_net_status_text(FLOE_NET_DOWN), "down") == 0);
    CHECK(floe_net_status_parse("up") == FLOE_NET_UP);
    CHECK(floe_net_status_parse("partial") == FLOE_NET_PARTIAL);
    CHECK(floe_net_status_parse("down") == FLOE_NET_DOWN);
    // Unknown, empty and missing must never be read as ready.
    CHECK(floe_net_status_parse("") == FLOE_NET_DOWN);
    CHECK(floe_net_status_parse("degraded") == FLOE_NET_DOWN);
    CHECK(floe_net_status_parse(NULL) == FLOE_NET_DOWN);

    // A too-small buffer must fail instead of truncating a resolver list.
    char tiny[16];
    CHECK(floe_net_render_resolv_conf(tiny, sizeof tiny) == -1);
    CHECK(floe_net_render_interfaces(tiny, sizeof tiny) == -1);
    CHECK(floe_net_render_gitconfig(tiny, sizeof tiny) == -1);

    if (g_failures != 0) {
        fprintf(stderr, "net-plan-check: %d/%d checks failed\n", g_failures, g_checks);
        return 1;
    }
    printf("net-plan-check: %d checks passed\n", g_checks);
    return 0;
}
