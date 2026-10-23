/*
 * Floe guest DNS NSS helper — libnss_floe.so.2 (glibc NSS module source).
 *
 * SPDX-License-Identifier: MPL-2.0
 *
 * This is the real guest-side resolver helper required by the Main-FROZEN
 * "Floe guest system DNS bridge v1" contract in PROTOCOL.json (id
 * floe-guest-dns-v1). It is a glibc NSS module for the pinned Debian
 * bookworm aarch64 guest (glibc 2.36), NOT an Android bionic JNI library.
 *
 * Contract (authoritative — PROTOCOL.json; this file implements it, it does
 * not extend it):
 *   - Transport: AF_UNIX SOCK_STREAM in the filesystem namespace at the
 *     fixed path /run/floe-dns/s. One request and one response per
 *     connection, then close. The runtime side authenticates the peer
 *     credential (same runtime UID) and resolves on the current Android
 *     Network / system PrivateDNS; this module never authenticates, never
 *     binds or listens, and never opens any network socket of its own.
 *   - Frame: "FDN1" magic (0x46444e31) + unsigned 16-bit big-endian DNS
 *     message length (12..4096) + raw DNS message.
 *   - Deadline: one monotonic 3500 ms absolute deadline covering
 *     connect + write + read for a logical query. No phase ever waits
 *     beyond it. EINTR/short-IO/EOF are handled; SIGPIPE is suppressed
 *     with MSG_NOSIGNAL.
 *   - Failure honesty: any transport failure, timeout, unknown frame,
 *     malformed or non-matching reply yields an honest temporary or
 *     notfound refusal. There is NO fallback resolver, NO host DNS call,
 *     NO raw/bypass network attempt, and NO fabricated positive record.
 *     `hosts: files floe` (no `dns` tail) makes resolution simply fail
 *     truthful while every non-name service keeps working.
 *   - State: no global mutable state, no background work, no threads, no
 *     retained sockets. Each call owns exactly its own bounded
 *     stack/caller-buffer state and at most one connection per family
 *     query (gethostbyname4_r performs at most two sequential
 *     transactions, A then AAAA, inside the one deadline).
 *
 * NSS ABI references (verified against the pinned build inputs, not memory):
 *   - enum nss_status { TRYAGAIN=-2, UNAVAIL=-1, NOTFOUND=0, SUCCESS=1,
 *     RETURN=2 } and struct gaih_addrtuple { next*, name*, family,
 *     addr[4], scopeid } from the glibc <nss.h> shipped with the pinned
 *     Zig 0.14.1 (lib/libc/include/generic-glibc/nss.h). The struct layout
 *     was diff-verified identical between glibc 2.28 and the guest's 2.36.
 *   - gethostbyname4_r result convention from glibc 2.36
 *     sysdeps/posix/getaddrinfo.c: tuples live in the caller buffer,
 *     `next` is a real pointer with the last tuple NULL-terminated, and
 *     the first tuple's `name` is consumed for AI_CANONNAME. The ERANGE
 *     retry protocol requires exactly NSS_STATUS_TRYAGAIN + errno ERANGE
 *     + h_errno NETDB_INTERNAL.
 *
 * Coverage boundary (documented honestly per the contract scope):
 *   - This module serves the guest glibc NSS path only: normal
 *     getaddrinfo/gethostbyname traffic — Python socket.getaddrinfo,
 *     Node's default dns.lookup, curl/openssl, apt/pip/npm.
 *   - Libraries that bypass NSS with their own resolver (Node dns.resolve*
 *     / c-ares, dnspython, dig, raw DNS clients) never call this module.
 *     They are not NSS users and are not intercepted.
 *   - Numeric literals (dotted-quad / IPv6 text) are short-circuited by
 *     glibc's digits-dots path before any NSS module runs.
 *   - IDNA: getaddrinfo(AI_IDN) converts to ASCII before NSS; this module
 *     only accepts ASCII hostnames and rejects everything else honestly.
 *
 * Reverse (PTR) lookups: deliberately NSS_STATUS_UNAVAIL. The bridge
 * contract is A/AAAA only; the system handles no reverse queries here,
 * and `files` remains authoritative for /etc/hosts.
 */

#define _GNU_SOURCE

#include <errno.h>
#include <netdb.h>
#include <nss.h>
#include <poll.h>
#include <stdalign.h>
#include <stdint.h>
#include <string.h>
#include <sys/random.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

/* ---- frozen contract constants (PROTOCOL.json) ---- */

#define FLOE_SOCKET_PATH "/run/floe-dns/s"
#define FLOE_MAGIC0 0x46u /* 'F' */
#define FLOE_MAGIC1 0x44u /* 'D' */
#define FLOE_MAGIC2 0x4eu /* 'N' */
#define FLOE_MAGIC3 0x31u /* '1' */
#define FLOE_HDR_BYTES 6u
#define FLOE_DNS_MIN 12u
#define FLOE_DNS_MAX 4096u
#define FLOE_DEADLINE_MS 3500u

/* internal bounds — every traversal below is explicitly bounded */
#define FLOE_MAX_NAME 254u      /* 253 wire bytes + NUL */
#define FLOE_MAX_LABEL 63u
#define FLOE_MAX_PTR_JUMPS 8u
#define FLOE_MAX_KNOWN_NAMES 9u /* qname + up to 8 CNAME targets */
#define FLOE_QDCOUNT_MAX 8u
#define FLOE_ANCOUNT_MAX 64u
#define FLOE_MAX_ADDRS_PER_FAMILY 16u
#define FLOE_FRAME_BYTES (FLOE_HDR_BYTES + FLOE_DNS_MAX)

/* DNS wire values used by this module */
#define DNS_TYPE_A 1u
#define DNS_TYPE_CNAME 5u
#define DNS_TYPE_AAAA 28u
#define DNS_CLASS_IN 1u

_Static_assert(sizeof FLOE_SOCKET_PATH - 1 < sizeof(((struct sockaddr_un *)0)->sun_path),
               "socket path must fit sun_path");

/* ---- outcomes of one family transaction (no fallback, no fabrication) ---- */

enum floe_outcome {
    FLOE_RESOLVED = 0,   /* records collected (count > 0 guaranteed)      */
    FLOE_NXDOMAIN,       /* definitive name absence                       */
    FLOE_NODATA,         /* name exists, no records of this family        */
    FLOE_TEMP,           /* transport/offline/temporary server failure    */
    FLOE_BADBRIDGE       /* unknown frame / malformed / non-matching reply */
};

/* ---- bounded per-family result (stack-local; never global) ---- */

struct floe_records {
    unsigned char addrs[FLOE_MAX_ADDRS_PER_FAMILY][16];
    unsigned count;
    unsigned addrlen;            /* 4 or 16 */
    int32_t min_ttl;             /* minimum TTL of accepted terminal records */
    char canon[FLOE_MAX_NAME];   /* canonical owner name (wire case preserved) */
};

/* ---- monotonic clock arithmetic ---- */

static uint64_t now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000u + (uint64_t)(ts.tv_nsec / 1000000);
}

/* Poll one fd for `events` until the absolute deadline. Returns 1 when ready,
 * 0 on timeout or fatal error. EINTR re-polls with the recomputed remainder;
 * it never extends the deadline. */
static int poll_until(int fd, short events, uint64_t deadline)
{
    for (;;) {
        uint64_t n = now_ms();
        if (n >= deadline)
            return 0;
        int timeout_ms = (int)(deadline - n);
        struct pollfd pfd = { .fd = fd, .events = events };
        int r = poll(&pfd, 1, timeout_ms);
        if (r < 0) {
            if (errno == EINTR)
                continue;
            return 0;
        }
        if (r == 0)
            return 0; /* poll timeout: our own deadline agrees */
        if (pfd.revents & (POLLERR | POLLNVAL))
            return 0;
        if (pfd.revents & events)
            return 1;
        /* POLLHUP alone: readable-but-EOF cases are handled by the caller's
         * recv loop (zero-length read => honest failure). */
        if ((events & POLLIN) && (pfd.revents & POLLHUP))
            return 1;
    }
}

/* Send the full frame over the non-blocking socket, or give up at the
 * deadline. MSG_NOSIGNAL suppresses SIGPIPE (never process-wide handled). */
static int io_send_all(int fd, const unsigned char *buf, size_t n, uint64_t deadline)
{
    size_t off = 0;
    while (off < n) {
        ssize_t w = send(fd, buf + off, n - off, MSG_NOSIGNAL | MSG_DONTWAIT);
        if (w > 0) {
            off += (size_t)w;
            continue;
        }
        if (w < 0 && errno == EINTR)
            continue;
        if (w < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            if (!poll_until(fd, POLLOUT, deadline))
                return 0;
            continue;
        }
        return 0; /* EPIPE/ENOTCONN/anything else: honest failure */
    }
    return 1;
}

/* Read exactly n bytes, or fail honestly at EOF/EINTR-exhausted/deadline. */
static int io_recv_exact(int fd, unsigned char *buf, size_t n, uint64_t deadline)
{
    size_t off = 0;
    while (off < n) {
        ssize_t r = recv(fd, buf + off, n - off, MSG_DONTWAIT);
        if (r > 0) {
            off += (size_t)r;
            continue;
        }
        if (r == 0)
            return 0; /* EOF before a complete frame: malformed */
        if (errno == EINTR)
            continue;
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            if (!poll_until(fd, POLLIN, deadline))
                return 0;
            continue;
        }
        return 0;
    }
    return 1;
}

/* ---- query id: entropy for corruption/mixup detection, not anti-spoofing
 * (the bridge stream itself is a same-UID private authenticated transport). */

static uint16_t query_id_new(void)
{
    unsigned char b[2];
    if (getrandom(b, sizeof b, 0) == (ssize_t)sizeof b)
        return (uint16_t)(((uint16_t)b[0] << 8) | b[1]);
    /* Honest fallback entropy: no global state, per-call derivation. */
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    uintptr_t sp = (uintptr_t)&b;
    uint32_t x = (uint32_t)ts.tv_nsec;
    x ^= (uint32_t)ts.tv_sec << 7;
    x ^= (uint32_t)getpid() << 16;
    x ^= (uint32_t)(sp >> 4);
    x ^= x >> 13;
    x *= 0x9e3779b9u;
    x ^= x >> 16;
    return (uint16_t)(x ^ (x >> 16));
}

/* ---- name encoding/validation ---- */

/* Validate and wire-encode a hostname into out (capacity `cap`), returning
 * the encoded length, or -1 for an invalid/oversized name. ASCII only;
 * labels 1..63; total <= 253; one optional trailing dot. */
static int dns_encode_name(unsigned char *out, size_t cap, const char *name)
{
    size_t nlen = strlen(name);
    if (nlen == 0 || nlen > 253)
        return -1;
    size_t cursor = 0;
    size_t i = 0;
    for (;;) {
        size_t start = i;
        while (i < nlen && name[i] != '.')
            i++;
        size_t llen = i - start;
        if (llen == 0 || llen > FLOE_MAX_LABEL)
            return -1;
        if (cursor + 1 + llen > cap)
            return -1;
        out[cursor++] = (unsigned char)llen;
        for (size_t k = 0; k < llen; k++) {
            unsigned char c = (unsigned char)name[start + k];
            if (c <= 0x20u || c >= 0x7fu) /* non-printable or space */
                return -1;
            if (c >= 'A' && c <= 'Z')
                c = (unsigned char)(c + 32u); /* wire canonical lowercase */
            out[cursor++] = c;
        }
        if (i == nlen)
            break;
        i++; /* skip the dot */
        if (i == nlen) {
            /* single trailing dot: root terminator already; stop */
            break;
        }
    }
    if (cursor + 1 > cap)
        return -1;
    out[cursor++] = 0u;
    return (int)cursor;
}

/* Build one A or AAAA query into dns[]; returns the message length or 0. */
static unsigned dns_build_query(unsigned char *dns, size_t cap, const char *name,
                                uint16_t qtype, uint16_t qid)
{
    if (cap < FLOE_DNS_MIN + 254u + 4u)
        return 0;
    dns[0] = (unsigned char)(qid >> 8);
    dns[1] = (unsigned char)(qid & 0xffu);
    dns[2] = 0x01u; /* RD=1, opcode 0 */
    dns[3] = 0x00u;
    dns[4] = 0x00u; dns[5] = 0x01u; /* QDCOUNT=1 */
    dns[6] = 0x00u; dns[7] = 0x00u; /* ANCOUNT */
    dns[8] = 0x00u; dns[9] = 0x00u; /* NSCOUNT */
    dns[10] = 0x00u; dns[11] = 0x00u; /* ARCOUNT */
    int elen = dns_encode_name(dns + 12, cap - 12u - 4u, name);
    if (elen < 0)
        return 0;
    unsigned cursor = 12u + (unsigned)elen;
    if (cursor + 4u > cap)
        return 0;
    dns[cursor++] = (unsigned char)(qtype >> 8);
    dns[cursor++] = (unsigned char)(qtype & 0xffu);
    dns[cursor++] = 0x00u; /* CLASS IN */
    dns[cursor++] = 0x01u;
    return cursor;
}

/* ---- response name decoding (bounded, loop-resistant) ---- */

/* Expand a possibly-compressed name at `pos`:
 *  - out receives the dot-separated name (capacity outcap incl. NUL),
 *  - newpos receives the offset after the encoded name for record walking.
 * Guarantees: every compression pointer refers strictly backwards in the
 * message (RFC 1035 §4.1.4), at most FLOE_MAX_PTR_JUMPS jumps, decoded
 * length bounded by FLOE_MAX_NAME. -1 on any bounds violation. */
static int dns_name_expand(const unsigned char *msg, unsigned len, unsigned pos,
                           char *out, size_t outcap, unsigned *newpos)
{
    size_t opos = 0;
    unsigned jumps = 0;
    unsigned cur = pos;
    int pos_set = 0;
    out[0] = '\0';
    for (;;) {
        if (cur >= len)
            return -1;
        unsigned char b = msg[cur];
        if ((b & 0xc0u) == 0xc0u) {
            if (cur + 2u > len)
                return -1;
            if (!pos_set) {
                *newpos = cur + 2u;
                pos_set = 1;
            }
            if (jumps >= FLOE_MAX_PTR_JUMPS)
                return -1;
            jumps++;
            unsigned target = (unsigned)(((unsigned)(b & 0x3fu) << 8) | msg[cur + 1u]);
            if (target >= cur) /* pointers must refer backwards */
                return -1;
            cur = target;
            continue;
        }
        if (b == 0u) {
            if (!pos_set) {
                *newpos = cur + 1u;
                pos_set = 1;
            }
            return opos == 0u ? -1 : 1; /* root-only answer name is invalid here */
        }
        if (b > FLOE_MAX_LABEL)
            return -1;
        if (cur + 1u + b > len)
            return -1;
        if (opos > 0u) {
            if (opos + 1u >= outcap)
                return -1;
            out[opos++] = '.';
        }
        if (opos + b + 1u >= outcap)
            return -1;
        for (unsigned k = 0; k < b; k++)
            out[opos++] = (char)msg[cur + 1u + k];
        out[opos] = '\0';
        cur += 1u + b;
    }
}

static char tolower_ascii(char c)
{
    return (c >= 'A' && c <= 'Z') ? (char)(c + 32) : c;
}

static int name_ci_equal(const char *a, const char *b)
{
    while (*a && *b) {
        if (tolower_ascii(*a) != tolower_ascii(*b))
            return 0;
        a++;
        b++;
    }
    if (*a == '\0' && *b == '\0')
        return 1;
    /* Tolerate one side's FQDN trailing dot only at the end. */
    const char *rest = *a ? a : b;
    return rest[0] == '.' && rest[1] == '\0';
}

/* Copy a name preserving wire case but lowercase the first letter only if
 * trivial; store raw (getaddrinfo canon keeps wire case). */
static void canon_copy(char *dst, const char *src)
{
    size_t i = 0;
    for (; i + 1 < FLOE_MAX_NAME && src[i]; i++)
        dst[i] = src[i];
    dst[i] = '\0';
}

/* ---- response validation + record walk (strict, matching-only) ---- */

static uint16_t be16(const unsigned char *p)
{
    return (uint16_t)(((uint16_t)p[0] << 8) | p[1]);
}

static uint32_t be32(const unsigned char *p)
{
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

static int32_t clamp_ttl(uint32_t t)
{
    if (t > 0x7ffffff0u)
        return 0x7ffffff0;
    return (int32_t)t;
}

/* Validate and harvest A/AAAA records for one query. `want6` selects the
 * family. Returns the outcome; on FLOE_RESOLVED, rec->count >= 1. */
static int dns_parse_response(const unsigned char *msg, unsigned len,
                              uint16_t qid, const char *qname, uint16_t qtype,
                              int want6, struct floe_records *rec)
{
    if (len < FLOE_DNS_MIN)
        return FLOE_BADBRIDGE;
    if (be16(msg) != qid)
        return FLOE_BADBRIDGE;                      /* transaction mismatch */
    uint16_t flags = be16(msg + 2);
    if ((flags & 0x8000u) == 0)
        return FLOE_BADBRIDGE;                      /* not a response */
    if ((flags & 0x7800u) != 0)
        return FLOE_BADBRIDGE;                      /* only standard opcode */
    int rcode = flags & 0x0fu;
    if (rcode == 3)
        return FLOE_NXDOMAIN;
    if (rcode == 2 || rcode == 5)
        return FLOE_TEMP;                           /* SERVFAIL/REFUSED */
    if (rcode != 0)
        return FLOE_BADBRIDGE;                      /* FORMERR/NOTIMP/other */

    unsigned qd = be16(msg + 4);
    unsigned an = be16(msg + 6);
    if (qd == 0u || qd > FLOE_QDCOUNT_MAX)
        return FLOE_BADBRIDGE;
    /* Bounded traversal: an oversized ANCOUNT is walked only up to the cap;
     * remaining records are ignored (never parsed unboundedly, never
     * fabricated into positives). */
    if (an > FLOE_ANCOUNT_MAX)
        an = FLOE_ANCOUNT_MAX;

    unsigned pos = 12u;
    /* Question section: parse fully (bounded) and require the first question
     * to match our query exactly — never trust a non-matching reply. */
    for (unsigned i = 0; i < qd; i++) {
        char qname_rep[FLOE_MAX_NAME];
        unsigned newpos;
        if (dns_name_expand(msg, len, pos, qname_rep, sizeof qname_rep, &newpos) != 1)
            return FLOE_BADBRIDGE;
        pos = newpos;
        if (pos + 4u > len)
            return FLOE_BADBRIDGE;
        uint16_t rt = be16(msg + pos);
        uint16_t rc = be16(msg + pos + 2u);
        pos += 4u;
        if (i == 0u) {
            if (rt != qtype || rc != DNS_CLASS_IN)
                return FLOE_BADBRIDGE;
            if (!name_ci_equal(qname_rep, qname))
                return FLOE_BADBRIDGE;
        }
    }

    /* Known-name set for the CNAME chain (res_hnok/res_hokify semantics,
     * small and bounded). */
    char known[FLOE_MAX_KNOWN_NAMES][FLOE_MAX_NAME];
    unsigned nknown = 0;
    /* Seed the chain with the (lowercased) query name without its optional
     * FQDN trailing dot; decoded response names never carry one. */
    size_t ql = strlen(qname);
    if (ql > 1u && qname[ql - 1u] == '.')
        ql--;
    if (ql == 0u || ql >= FLOE_MAX_NAME)
        return FLOE_NXDOMAIN; /* unreachable: callers validate <= 253 */
    for (size_t k = 0; k < ql; k++)
        known[0][k] = tolower_ascii(qname[k]);
    known[0][ql] = '\0';
    nknown = 1;

    char canon[FLOE_MAX_NAME];
    canon_copy(canon, known[0]);
    int have_terminal = 0;
    int terminal_is_target_family = 0;
    uint16_t wanted = want6 ? DNS_TYPE_AAAA : DNS_TYPE_A;
    unsigned rrlen = want6 ? 16u : 4u;

    rec->count = 0;
    rec->addrlen = rrlen;
    rec->min_ttl = 0x7ffffff0;

    for (unsigned i = 0; i < an; i++) {
        char owner[FLOE_MAX_NAME];
        unsigned newpos;
        if (dns_name_expand(msg, len, pos, owner, sizeof owner, &newpos) != 1)
            return FLOE_BADBRIDGE;
        pos = newpos;
        if (pos + 10u > len)
            return FLOE_BADBRIDGE;
        uint16_t rtype = be16(msg + pos);
        uint16_t rclass = be16(msg + pos + 2u);
        uint32_t ttl = be32(msg + pos + 4u);
        uint16_t rdlen = be16(msg + pos + 8u);
        pos += 10u;
        if (pos + rdlen > len)
            return FLOE_BADBRIDGE;
        if (rclass != DNS_CLASS_IN) {
            pos += rdlen;
            continue;
        }

        /* owner must be one of the known names in the chain */
        int owner_known = 0;
        unsigned owner_idx = 0;
        for (unsigned k = 0; k < nknown; k++) {
            if (name_ci_equal(owner, known[k])) {
                owner_known = 1;
                owner_idx = k;
                break;
            }
        }
        if (!owner_known)
            return FLOE_BADBRIDGE; /* answer outside the queried chain */

        if (rtype == DNS_TYPE_CNAME) {
            if (have_terminal && terminal_is_target_family)
                return FLOE_BADBRIDGE; /* CNAME after terminal records */
            char target[FLOE_MAX_NAME];
            unsigned tnew;
            if (dns_name_expand(msg, len, pos, target, sizeof target, &tnew) != 1)
                return FLOE_BADBRIDGE;
            if (nknown >= FLOE_MAX_KNOWN_NAMES)
                return FLOE_BADBRIDGE; /* chain too long: bounded refusal */
            size_t tl = strlen(target); /* expand already bounded to <= 253 */
            for (size_t k = 0; k < tl; k++)
                known[nknown][k] = tolower_ascii(target[k]);
            known[nknown][tl] = '\0';
            nknown++;
            canon_copy(canon, target);
            pos += rdlen;
            continue;
        }

        /* A terminal (non-CNAME) record: it defines the canonical owner.
         * The owner string keeps the response's wire case (comparisons
         * below remain case-insensitive). */
        if (!have_terminal) {
            (void)owner_idx;
            canon_copy(canon, owner);
            have_terminal = 1;
            terminal_is_target_family = (rtype == wanted);
        } else {
            if (rtype == wanted && !terminal_is_target_family)
                return FLOE_BADBRIDGE; /* family switch without chain reset */
            if (!name_ci_equal(owner, canon))
                return FLOE_BADBRIDGE; /* terminal records must share owner */
        }

        if (rtype == wanted) {
            if (rdlen != rrlen)
                return FLOE_BADBRIDGE; /* wrong rdlength for the family */
            if (rec->count < FLOE_MAX_ADDRS_PER_FAMILY) {
                memcpy(rec->addrs[rec->count], msg + pos, rrlen);
                rec->count++;
                int32_t t = clamp_ttl(ttl);
                if (t < rec->min_ttl)
                    rec->min_ttl = t;
            }
            /* beyond the cap: honest subset, documented; never fabricated */
        }
        pos += rdlen;
    }

    if (rec->count == 0u)
        return FLOE_NODATA;
    size_t cl = strlen(canon);
    if (cl == 0u || cl >= FLOE_MAX_NAME)
        return FLOE_BADBRIDGE;
    memcpy(rec->canon, canon, cl + 1u);
    return FLOE_RESOLVED;
}

/* ---- one authenticated-bridge transaction ---- */

/* Perform exactly one framed transaction against /run/floe-dns/s and
 * harvest records for one family. Returns the outcome; `errno` keeps the
 * last transport error for honest *errnop reporting. Never any retry,
 * never any second path, never a fallback. */
static int bridge_resolve_family(const char *qname, uint16_t qid, int want6,
                                 uint64_t deadline, struct floe_records *rec)
{
    uint16_t qtype = want6 ? DNS_TYPE_AAAA : DNS_TYPE_A;
    unsigned char dnsbuf[12u + 254u + 4u];
    unsigned dlen = dns_build_query(dnsbuf, sizeof dnsbuf, qname, qtype, qid);
    if (dlen == 0u || dlen < FLOE_DNS_MIN || dlen > FLOE_DNS_MAX)
        return FLOE_NXDOMAIN; /* name not encodable: nothing to ask */

    unsigned char frame[FLOE_FRAME_BYTES];
    frame[0] = FLOE_MAGIC0;
    frame[1] = FLOE_MAGIC1;
    frame[2] = FLOE_MAGIC2;
    frame[3] = FLOE_MAGIC3;
    frame[4] = (unsigned char)(dlen >> 8);
    frame[5] = (unsigned char)(dlen & 0xffu);
    memcpy(frame + FLOE_HDR_BYTES, dnsbuf, dlen);

    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    if (fd < 0)
        return FLOE_TEMP;

    struct sockaddr_un su;
    memset(&su, 0, sizeof su);
    su.sun_family = AF_UNIX;
    memcpy(su.sun_path, FLOE_SOCKET_PATH, sizeof FLOE_SOCKET_PATH); /* incl NUL */

    int outcome = FLOE_TEMP;
    for (;;) {
        if (connect(fd, (struct sockaddr *)&su, sizeof su) != 0) {
            int e = errno;
            if (e != EINPROGRESS && e != EINTR) {
                outcome = FLOE_TEMP; /* ENOENT/ECONNREFUSED: bridge not up */
                break;
            }
            if (e == EINTR || e == EINPROGRESS) {
                if (!poll_until(fd, POLLOUT, deadline)) {
                    outcome = FLOE_TEMP;
                    break;
                }
                int soerr = 0;
                socklen_t sl = sizeof soerr;
                if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &soerr, &sl) != 0 || soerr != 0) {
                    outcome = FLOE_TEMP;
                    break;
                }
            }
        }
        if (!io_send_all(fd, frame, FLOE_HDR_BYTES + dlen, deadline)) {
            outcome = FLOE_TEMP;
            break;
        }
        unsigned char hdr[FLOE_HDR_BYTES];
        if (!io_recv_exact(fd, hdr, FLOE_HDR_BYTES, deadline)) {
            outcome = FLOE_TEMP;
            break;
        }
        if (hdr[0] != FLOE_MAGIC0 || hdr[1] != FLOE_MAGIC1 ||
            hdr[2] != FLOE_MAGIC2 || hdr[3] != FLOE_MAGIC3) {
            outcome = FLOE_BADBRIDGE;
            break;
        }
        unsigned rlen = be16(hdr + 4);
        if (rlen < FLOE_DNS_MIN || rlen > FLOE_DNS_MAX) {
            outcome = FLOE_BADBRIDGE;
            break;
        }
        unsigned char resp[FLOE_DNS_MAX];
        if (!io_recv_exact(fd, resp, rlen, deadline)) {
            outcome = FLOE_TEMP;
            break;
        }
        /* One transaction per connection: any trailing bytes are ignored and
         * the connection is closed here regardless of parse result. */
        outcome = dns_parse_response(resp, rlen, qid, qname, qtype, want6, rec);
        break;
    }
    close(fd);
    return outcome;
}

/* ---- status helpers ---- */

/* errno is deliberately left untouched by refusals: it already carries the
 * last real transport failure for callers that inspect it (except ERANGE,
 * handled by range_again). */
static enum nss_status refusal_status(int outcome, int *errnop, int *h_errnop)
{
    (void)errnop;
    switch (outcome) {
    case FLOE_NXDOMAIN:
        *h_errnop = HOST_NOT_FOUND;
        return NSS_STATUS_NOTFOUND;
    case FLOE_NODATA:
        *h_errnop = NO_DATA;
        return NSS_STATUS_NOTFOUND;
    case FLOE_TEMP:
        *h_errnop = TRY_AGAIN;
        return NSS_STATUS_UNAVAIL;
    default: /* FLOE_BADBRIDGE */
        *h_errnop = NO_RECOVERY;
        return NSS_STATUS_UNAVAIL;
    }
}

static void range_again(int *errnop, int *h_errnop)
{
    *errnop = ERANGE;
    *h_errnop = NETDB_INTERNAL; /* exactly the glibc grow-the-buffer triple */
}

static size_t align_up(size_t v, size_t a)
{
    return (v + a - 1u) & ~(a - 1u);
}

/* ---- hostent fill (gethostbyname*_r 1/2/3 ABI) ---- */

/* Fill `host` + caller buffer with `rec` for family `af`. On success every
 * `host` pointer references only the caller buffer. */
static enum nss_status fill_hostent(const struct floe_records *rec, int af,
                                    struct hostent *host, char *buffer,
                                    size_t buflen, int *errnop, int *h_errnop,
                                    int32_t *ttlp, char **canonp)
{
    if (rec->count == 0u) {
        *h_errnop = NO_DATA;
        return NSS_STATUS_NOTFOUND;
    }
    size_t n = rec->count;
    size_t alen = rec->addrlen;
    size_t name_len = strlen(rec->canon) + 1u;

    /* Segment layout (all within buffer, pointer-aligned):
     *   [addr pointer array (n+1)] [alias pointer array (1)]
     *   [address bytes n*alen]     [canonical name string]     */
    size_t off_ptrs = 0u;
    size_t sz_ptrs = align_up((n + 1u) * sizeof(char *), alignof(void *));
    size_t off_alias = off_ptrs + sz_ptrs;
    size_t sz_alias = align_up(1u * sizeof(char *), alignof(void *));
    size_t off_addr = off_alias + sz_alias;
    /* Uniform 16-byte storage stride: every h_addr_list entry is then
     * 16-byte aligned inside the caller buffer (matches the safe glibc
     * nss_dns shape; h_length still reports the true 4/16 length). */
    size_t sz_addr = n * 16u;
    size_t off_name = off_addr + sz_addr;
    size_t need = off_name + name_len;
    if (buflen < need) {
        range_again(errnop, h_errnop);
        return NSS_STATUS_TRYAGAIN;
    }

    char **addr_list = (char **)(void *)(buffer + off_ptrs);
    char **alias_list = (char **)(void *)(buffer + off_alias);
    unsigned char *addr_bytes = (unsigned char *)(void *)(buffer + off_addr);
    char *name_copy = buffer + off_name;

    for (size_t i = 0; i < n; i++) {
        memcpy(addr_bytes + i * 16u, rec->addrs[i], alen);
        addr_list[i] = (char *)(void *)(addr_bytes + i * 16u);
    }
    addr_list[n] = NULL;
    alias_list[0] = NULL;
    memcpy(name_copy, rec->canon, name_len);

    host->h_name = name_copy;
    host->h_aliases = alias_list;
    host->h_addrtype = af;
    host->h_length = (int)alen;
    host->h_addr_list = addr_list;
    if (ttlp != NULL)
        *ttlp = rec->min_ttl;
    if (canonp != NULL)
        *canonp = name_copy;
    *h_errnop = 0;
    return NSS_STATUS_SUCCESS;
}

/* ---- NSS entry points (exact glibc ABI, see <nss.h> of the pinned tool) ---- */

enum nss_status _nss_floe_gethostbyname_r(const char *name, struct hostent *host,
                                          char *buffer, size_t buflen,
                                          int *errnop, int *h_errnop);

enum nss_status _nss_floe_gethostbyname2_r(const char *name, int af,
                                           struct hostent *host, char *buffer,
                                           size_t buflen, int *errnop,
                                           int *h_errnop);

enum nss_status _nss_floe_gethostbyname3_r(const char *name, int af,
                                           struct hostent *host, char *buffer,
                                           size_t buflen, int *errnop,
                                           int *h_errnop, int32_t *ttlp,
                                           char **canonp);

enum nss_status _nss_floe_gethostbyname4_r(const char *name,
                                           struct gaih_addrtuple **pat,
                                           char *buffer, size_t buflen,
                                           int *errnop, int *h_errnop,
                                           int32_t *ttlp);

/* ---- shared one-family core (used by gethostbyname{,2,3}_r) ---- */

static enum nss_status
floe_resolve_one(const char *name, int af, struct hostent *host, char *buffer,
                 size_t buflen, int *errnop, int *h_errnop, int32_t *ttlp,
                 char **canonp)
{
    int want6 = (af == AF_INET6);
    uint64_t deadline = now_ms() + FLOE_DEADLINE_MS;
    uint16_t qid = query_id_new();
    struct floe_records rec;
    memset(&rec, 0, sizeof rec);

    int outcome = bridge_resolve_family(name, qid, want6, deadline, &rec);
    if (outcome != FLOE_RESOLVED)
        return refusal_status(outcome, errnop, h_errnop);
    return fill_hostent(&rec, af, host, buffer, buflen, errnop, h_errnop,
                        ttlp, canonp);
}

enum nss_status
_nss_floe_gethostbyname2_r(const char *name, int af, struct hostent *host,
                           char *buffer, size_t buflen, int *errnop,
                           int *h_errnop)
{
    if (name == NULL || host == NULL || buffer == NULL || errnop == NULL ||
        h_errnop == NULL)
        return NSS_STATUS_UNAVAIL;
    if (af != AF_INET && af != AF_INET6) {
        *h_errnop = NO_RECOVERY;
        return NSS_STATUS_RETURN; /* cannot serve this family at all */
    }
    return floe_resolve_one(name, af, host, buffer, buflen, errnop, h_errnop,
                            NULL, NULL);
}

enum nss_status
_nss_floe_gethostbyname_r(const char *name, struct hostent *host,
                          char *buffer, size_t buflen, int *errnop,
                          int *h_errnop)
{
    /* Legacy IPv4-only entry point: identical semantics with AF_INET. */
    return _nss_floe_gethostbyname2_r(name, AF_INET, host, buffer, buflen,
                                      errnop, h_errnop);
}

enum nss_status
_nss_floe_gethostbyname3_r(const char *name, int af, struct hostent *host,
                           char *buffer, size_t buflen, int *errnop,
                           int *h_errnop, int32_t *ttlp, char **canonp)
{
    if (name == NULL || host == NULL || buffer == NULL || errnop == NULL ||
        h_errnop == NULL)
        return NSS_STATUS_UNAVAIL;
    if (af != AF_INET && af != AF_INET6) {
        *h_errnop = NO_RECOVERY;
        return NSS_STATUS_RETURN;
    }
    /* h_name is the canonical name string in the caller buffer (the CNAME
     * chain was validated in the response walk); fill_hostent exposes the
     * TTL and canonical outputs through the 3_r parameters when present. */
    return floe_resolve_one(name, af, host, buffer, buflen, errnop, h_errnop,
                            ttlp, canonp);
}

enum nss_status
_nss_floe_gethostbyname4_r(const char *name, struct gaih_addrtuple **pat,
                           char *buffer, size_t buflen, int *errnop,
                           int *h_errnop, int32_t *ttlp)
{
    if (name == NULL || pat == NULL || buffer == NULL || errnop == NULL ||
        h_errnop == NULL)
        return NSS_STATUS_UNAVAIL;

    /* One deadline across both sequential transactions (A, then AAAA). */
    uint64_t deadline = now_ms() + FLOE_DEADLINE_MS;
    uint16_t qid4 = query_id_new();
    struct floe_records v4, v6;
    memset(&v4, 0, sizeof v4);
    memset(&v6, 0, sizeof v6);

    int o4 = bridge_resolve_family(name, qid4, 0, deadline, &v4);
    if (o4 == FLOE_TEMP || o4 == FLOE_BADBRIDGE) {
        /* Transport or bridge failure: whole resolution fails honestly;
         * no fabricated partial positives. */
        return refusal_status(o4, errnop, h_errnop);
    }

    int o6 = FLOE_NXDOMAIN;
    if (o4 != FLOE_NXDOMAIN) {
        /* The name exists (or at least was not definitively absent): AAAA is
         * still worth asking, inside the same remaining deadline. */
        uint16_t qid6 = query_id_new();
        o6 = bridge_resolve_family(name, qid6, 1, deadline, &v6);
        if (o6 == FLOE_TEMP || o6 == FLOE_BADBRIDGE)
            return refusal_status(o6, errnop, h_errnop);
    }

    if (o4 == FLOE_NXDOMAIN && o6 == FLOE_NXDOMAIN) {
        *h_errnop = HOST_NOT_FOUND;
        return NSS_STATUS_NOTFOUND;
    }
    int n4 = (o4 == FLOE_RESOLVED) ? (int)v4.count : 0;
    int n6 = (o6 == FLOE_RESOLVED) ? (int)v6.count : 0;
    if (n4 == 0 && n6 == 0) {
        *h_errnop = NO_DATA;
        return NSS_STATUS_NOTFOUND;
    }

    size_t total = (size_t)n4 + (size_t)n6;
    size_t tsz = align_up(sizeof(struct gaih_addrtuple), alignof(void *));
    size_t canon4_len = n4 ? strlen(v4.canon) + 1u : 0u;
    size_t canon6_len = n6 ? strlen(v6.canon) + 1u : 0u;
    int canon_shared = (n4 && n6) && name_ci_equal(v4.canon, v6.canon);
    size_t names_len = canon_shared ? canon4_len : canon4_len + canon6_len;
    size_t need = align_up(total * tsz, alignof(void *)) + names_len;
    if (buflen < need) {
        range_again(errnop, h_errnop);
        return NSS_STATUS_TRYAGAIN;
    }

    char *p = buffer;
    struct gaih_addrtuple *first = NULL, *last = NULL;
    char *name_area = p + align_up(total * tsz, alignof(void *));
    char *canon4 = name_area;
    char *canon6 = canon4 + canon4_len; /* == canon4 when shared */
    if (canon_shared)
        canon6 = canon4;
    if (n4)
        memcpy(canon4, v4.canon, canon4_len);
    if (n6)
        memcpy(canon6, v6.canon, canon6_len);

    for (int i = 0; i < n4; i++) {
        struct gaih_addrtuple *t = (struct gaih_addrtuple *)(void *)p;
        memset(t, 0, tsz);
        t->family = AF_INET;
        memcpy(t->addr, v4.addrs[i], 4u);
        t->name = canon4;
        t->scopeid = 0;
        t->next = NULL;
        if (first == NULL)
            first = t;
        else
            last->next = t;
        last = t;
        p += tsz;
    }
    for (int i = 0; i < n6; i++) {
        struct gaih_addrtuple *t = (struct gaih_addrtuple *)(void *)p;
        memset(t, 0, tsz);
        t->family = AF_INET6;
        memcpy(t->addr, v6.addrs[i], 16u);
        t->name = canon6;
        t->scopeid = 0;
        t->next = NULL;
        if (first == NULL)
            first = t;
        else
            last->next = t;
        last = t;
        p += tsz;
    }

    *pat = first; /* real pointers inside the caller buffer, last next NULL
                   * (glibc 2.36 gaih_inet convention) */
    if (ttlp != NULL) {
        int32_t t = 0x7ffffff0;
        if (n4 && v4.min_ttl < t)
            t = v4.min_ttl;
        if (n6 && v6.min_ttl < t)
            t = v6.min_ttl;
        *ttlp = t;
    }
    *h_errnop = 0;
    return NSS_STATUS_SUCCESS;
}
