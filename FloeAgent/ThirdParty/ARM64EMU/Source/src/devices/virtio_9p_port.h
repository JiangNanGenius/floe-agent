/* SPDX-License-Identifier: Apache-2.0 */
/* Copyright 2026 Sylirre */
/* Copyright 2026 Floe contributors */
/* virtio-9p portability layer: Linux-wire open-flag and errno translation,
 * root-relative lexical path containment, and name validation.
 *
 * The guest speaks 9P2000.L, whose open flags and errno values are the Linux
 * asm-generic numbers regardless of the host kernel. The host may be Linux
 * (identity mapping) or Darwin (explicit table). Anything the host cannot
 * honor is refused with EOPNOTSUPP — never passed through, never silently
 * dropped, and never "fixed" with a hardcoded substitute.
 *
 * This header is standalone (no engine types) so the focused qualification
 * tests can exercise it without a Machine. */
#ifndef A64_VIRTIO_9P_PORT_H
#define A64_VIRTIO_9P_PORT_H

#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>

/* ---- Linux asm-generic open(2) flag values on the 9P2000.L wire -------- */
#define P9_O_ACCMODE      000000003u
#define P9_O_RDONLY       000000000u
#define P9_O_WRONLY       000000001u
#define P9_O_RDWR         000000002u
#define P9_O_CREAT        000000100u   /* 0x40   */
#define P9_O_EXCL         000000200u   /* 0x80   */
#define P9_O_NOCTTY       000000400u   /* 0x100  */
#define P9_O_TRUNC        000001000u   /* 0x200  */
#define P9_O_APPEND       000002000u   /* 0x400  */
#define P9_O_NONBLOCK     000004000u   /* 0x800  */
#define P9_O_DSYNC        000010000u   /* 0x1000 */
#define P9_O_DIRECT       000040000u   /* 0x4000 */
#define P9_O_LARGEFILE    00100000u    /* 0x8000: implied, masked */
#define P9_O_DIRECTORY    00200000u    /* 0x10000 */
#define P9_O_NOFOLLOW     00400000u    /* 0x20000 */
#define P9_O_NOATIME      01000000u    /* 0x40000 */
#define P9_O_CLOEXEC      02000000u    /* 0x80000: host-local, masked */
#define P9_O_SYNC         04010000u    /* 0x101000 */
#define P9_O_PATH         010000000u   /* 0x200000 */

/* Unsupported-on-this-host bits refuse the whole open with EOPNOTSUPP. */
#ifndef O_DIRECTORY
#define A64_P9_NO_O_DIRECTORY 1
#endif
#ifndef O_NOFOLLOW
#define A64_P9_NO_O_NOFOLLOW 1
#endif

/* Translate a Linux-wire open-flag word to host O_* flags.
 * Returns the host flags, or -1 with *err set (EOPNOTSUPP) when the wire
 * word asks for something this host cannot honor (O_DIRECT, O_DSYNC,
 * O_SYNC, O_NOATIME, O_PATH, O_NOFOLLOW/O_DIRECTORY where absent). */
static inline int p9_dotl_to_host(uint32_t fl, int *err) {
    int h;
    switch (fl & P9_O_ACCMODE) {
        case P9_O_WRONLY: h = O_WRONLY; break;
        case P9_O_RDWR:   h = O_RDWR;   break;
        default:          h = O_RDONLY; break;
    }
    uint32_t rest = fl & ~(uint32_t)P9_O_ACCMODE;
    rest &= ~(uint32_t)(P9_O_LARGEFILE | P9_O_CLOEXEC); /* implied/host-local */
    if (rest & P9_O_CREAT)    { h |= O_CREAT;    rest &= ~P9_O_CREAT; }
    if (rest & P9_O_EXCL)     { h |= O_EXCL;     rest &= ~P9_O_EXCL; }
    if (rest & P9_O_NOCTTY)   { h |= O_NOCTTY;   rest &= ~P9_O_NOCTTY; }
    if (rest & P9_O_TRUNC)    { h |= O_TRUNC;    rest &= ~P9_O_TRUNC; }
    if (rest & P9_O_APPEND)   { h |= O_APPEND;   rest &= ~P9_O_APPEND; }
    if (rest & P9_O_NONBLOCK) { h |= O_NONBLOCK; rest &= ~P9_O_NONBLOCK; }
#ifdef A64_P9_NO_O_DIRECTORY
    if (rest & P9_O_DIRECTORY) { *err = EOPNOTSUPP; return -1; }
#else
    if (rest & P9_O_DIRECTORY) { h |= O_DIRECTORY; rest &= ~P9_O_DIRECTORY; }
#endif
#ifdef A64_P9_NO_O_NOFOLLOW
    if (rest & P9_O_NOFOLLOW) { *err = EOPNOTSUPP; return -1; }
#else
    if (rest & P9_O_NOFOLLOW) { h |= O_NOFOLLOW; rest &= ~P9_O_NOFOLLOW; }
#endif
    /* Everything left is host-synchronization/path metadata we do not
     * emulate: refuse the open rather than silently degrade it. */
    if (rest) { *err = EOPNOTSUPP; return -1; }
    return h;
}

static inline bool p9_dotl_wants_write(uint32_t fl) {
    return (fl & P9_O_ACCMODE) != P9_O_RDONLY ||
           (fl & (P9_O_CREAT | P9_O_TRUNC)) != 0;
}

/* ---- host errno -> Linux-wire errno --------------------------------------
 * 9P2000.L Rlerror carries Linux errno numbers. On Linux the mapping is the
 * identity. On Darwin the small table below covers every errno a file
 * syscall in this device can produce; anything unmapped degrades to EIO so
 * the guest never receives a host-private number. */
#ifdef __linux__
static inline int p9_err(int host_errno) { return host_errno; }
#else
static inline int p9_err(int host_errno) {
    switch (host_errno) {
        case 0: return 0;
        case EPERM: return 1;
        case ENOENT: return 2;
        case ESRCH: return 3;
        case EINTR: return 4;
        case EIO: return 5;
        case ENXIO: return 6;
        case E2BIG: return 7;
        case ENOEXEC: return 8;
        case EBADF: return 9;
        case ECHILD: return 10;
#ifdef EAGAIN
        case EAGAIN: return 11;
#endif
        case ENOMEM: return 12;
        case EACCES: return 13;
        case EFAULT: return 14;
#ifdef EBUSY
        case EBUSY: return 16;
#endif
        case EEXIST: return 17;
        case EXDEV: return 18;
        case ENODEV: return 19;
        case ENOTDIR: return 20;
        case EISDIR: return 21;
        case EINVAL: return 22;
        case ENFILE: return 23;
        case EMFILE: return 24;
        case ENOTTY: return 25;
#ifdef ETXTBSY
        case ETXTBSY: return 26;
#endif
        case EFBIG: return 27;
        case ENOSPC: return 28;
        case ESPIPE: return 29;
        case EROFS: return 30;
        case EMLINK: return 31;
        case EPIPE: return 32;
        case EDOM: return 33;
        case ERANGE: return 34;
#ifdef EDEADLK
        case EDEADLK: return 35;
#endif
        case ENAMETOOLONG: return 36;
#ifdef ENOLCK
        case ENOLCK: return 37;
#endif
        case ENOSYS: return 38;
        case ENOTEMPTY: return 39;
#ifdef ESTALE
        case ESTALE: return 116;
#endif
        case ELOOP: return 62;
#ifdef ENODATA
        case ENODATA: return 61;
#endif
#ifdef ENOLINK
        case ENOLINK: return 67;
#endif
#ifdef ENOSR
        case ENOSR: return 63;
#endif
#ifdef ENOSTR
        case ENOSTR: return 60;
#endif
#ifdef EPROTO
        case EPROTO: return 71;
#endif
#ifdef ETIME
        case ETIME: return 62;
#endif
#ifdef EADDRINUSE
        case EADDRINUSE: return 98;
#endif
#ifdef EADDRNOTAVAIL
        case EADDRNOTAVAIL: return 99;
#endif
#ifdef EAFNOSUPPORT
        case EAFNOSUPPORT: return 97;
#endif
#ifdef EPROTOTYPE
        case EPROTOTYPE: return 91;
#endif
#ifdef EPROTONOSUPPORT
        case EPROTONOSUPPORT: return 93;
#endif
#ifdef ENOPROTOOPT
        case ENOPROTOOPT: return 92;
#endif
#ifdef ENOTSOCK
        case ENOTSOCK: return 88;
#endif
#ifdef EDESTADDRREQ
        case EDESTADDRREQ: return 89;
#endif
        case EMSGSIZE: return 90;
#ifdef ENOBUFS
        case ENOBUFS: return 105;
#endif
#ifdef EISCONN
        case EISCONN: return 106;
#endif
#ifdef ENOTCONN
        case ENOTCONN: return 107;
#endif
#ifdef ESHUTDOWN
        case ESHUTDOWN: return 108;
#endif
#ifdef ETIMEDOUT
        case ETIMEDOUT: return 110;
#endif
#ifdef ECONNREFUSED
        case ECONNREFUSED: return 111;
#endif
#ifdef EHOSTDOWN
        case EHOSTDOWN: return 112;
#endif
#ifdef EHOSTUNREACH
        case EHOSTUNREACH: return 113;
#endif
#ifdef EINPROGRESS
        case EINPROGRESS: return 115;
#endif
#ifdef EALREADY
        case EALREADY: return 116;
#endif
#ifdef EOPNOTSUPP
        case EOPNOTSUPP: return 95;
#endif
#ifdef ENOTSUP
#if defined(EOPNOTSUPP) && (ENOTSUP != EOPNOTSUPP)
        case ENOTSUP: return 95;
#endif
#endif
#ifdef ECANCELED
        case ECANCELED: return 125;
#endif
#ifdef EDQUOT
        case EDQUOT: return 122;
#endif
        default: return 5;               /* EIO: never leak a host-private code */
    }
}
#endif /* __linux__ */

/* ---- root-relative lexical path containment ------------------------------
 * Fid paths are stored root-relative ("" names the share root). These helpers
 * are pure string operations; the device pairs them with openat/fstatat on
 * the pinned root descriptor so the kernel can never resolve outside it. */

/* A single 9P path element must be non-empty, must not be a dot component
 * ('.' / '..' are the caller's job), and must contain no '/'. Dotfiles such
 * as ".git" are legal elements and stay allowed. */
static inline bool p9_name_ok(const char *name) {
    if (name[0] == '\0') return false;
    if (name[0] == '.' && (name[1] == '\0' || (name[1] == '.' && name[2] == '\0')))
        return false;
    return strchr(name, '/') == NULL;
}

/* Tsetattr valid bits (Linux-wire values, host-independent). */
#define P9_ATTR_MODE      (1u << 0)
#define P9_ATTR_UID       (1u << 1)
#define P9_ATTR_GID       (1u << 2)
#define P9_ATTR_SIZE      (1u << 3)
#define P9_ATTR_ATIME     (1u << 4)
#define P9_ATTR_MTIME     (1u << 5)
#define P9_ATTR_CTIME     (1u << 6)
#define P9_ATTR_ATIME_SET (1u << 7)
#define P9_ATTR_MTIME_SET (1u << 8)

/* ---- live-share ownership / setattr policy (pure, standalone) -------------
 * These helpers freeze the decisions the device implements, so the focused
 * qualification tests can exercise them without a Machine:
 *
 *  - Guest uid/gid are a per-share PRESENTATION choice (synthetic ownership).
 *    They are never forwarded to a host chown/fchown: any setattr that asks
 *    to change uid/gid is refused EPERM, honestly, on every share.
 *  - A symlink node itself rejects metadata writes (EACCES) so a link can
 *    never be retargeted through setattr.
 * Returns 0 when the setattr may proceed, or the host errno to refuse with.
 */
static inline int p9_policy_setattr(uint32_t valid, bool is_link) {
    if (valid & (P9_ATTR_UID | P9_ATTR_GID)) return EPERM;
    if (is_link && (valid & (P9_ATTR_SIZE | P9_ATTR_ATIME | P9_ATTR_MTIME |
                             P9_ATTR_CTIME))) return EACCES;
    return 0;
}

/* Refuse anything that could block a slice or punch outside the file model. */
static inline bool p9_mode_blocked(mode_t mode) {
    return S_ISFIFO(mode) || S_ISSOCK(mode);
}

/* Join/resolve one element against a root-relative base, clamping '..' at
 * the root. Writes the result ("" when the walk returns to the root) and
 * returns true, or false when the result would exceed outsz. */
static inline bool p9_path_child(const char *base, const char *name,
                                 char *out, size_t outsz) {
    if (!strcmp(name, ".")) {
        size_t n = strlen(base);
        if (n + 1 > outsz) return false;
        memcpy(out, base, n + 1);
        return true;
    }
    if (!strcmp(name, "..")) {
        if (base[0] == '\0') { out[0] = '\0'; return true; }
        const char *slash = strrchr(base, '/');
        size_t n = slash ? (size_t)(slash - base) : 0;
        if (n + 1 > outsz) return false;
        memcpy(out, base, n);
        out[n] = '\0';
        return true;
    }
    size_t bn = strlen(base), nn = strlen(name);
    size_t n = bn ? bn + 1 + nn : nn;
    if (n + 1 > outsz) return false;
    if (bn) { memcpy(out, base, bn); out[bn] = '/'; memcpy(out + bn + 1, name, nn + 1); }
    else    { memcpy(out, name, nn + 1); }
    return true;
}

#endif /* A64_VIRTIO_9P_PORT_H */
