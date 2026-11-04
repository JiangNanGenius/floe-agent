/* SPDX-License-Identifier: Apache-2.0 */
/* Copyright 2026 Sylirre */
/* virtio-9p host directory share over a modern (version 2) virtio-mmio
 * transport. Exports a host directory tree into the guest as a 9P2000.L
 * filesystem; the guest mounts it with
 *
 *     mount -t 9p -o trans=virtio,version=9p2000.L <tag> /mnt/point
 *
 * One device == one share == one MMIO slot with its own mount tag (advertised
 * via the VIRTIO_9P_MOUNT_TAG feature + config space). Multiple shares create
 * multiple independent devices.
 *
 * Every request is serviced synchronously inside QueueNotify on the machine
 * coordinator, and the queue interrupt is raised inline, exactly like
 * virtio-blk. Guest-RAM DMA goes through phys_read/phys_write, which hold the
 * A6 memory guard and publish code-page epochs and exclusive-monitor
 * invalidation before every write, including the used-ring publication.
 *
 * Floe embedded restoration (security posture differs from upstream on
 * purpose; file-access scope comes only from native configuration):
 *
 *  - Containment is descriptor-based, not lexical. The share root is
 *    resolved once at create (realpath) and pinned with a root directory
 *    descriptor; every host operation is an *at() call on that descriptor,
 *    so the kernel can never resolve outside the registered root, and no
 *    host path string is ever built for file access.
 *  - Linux-wire open flags and errno are translated explicitly
 *    (virtio_9p_port.h); unsupported bits refuse with EOPNOTSUPP rather
 *    than degrade silently. See the port header for the exact tables.
 *  - Symlinks may be created, read and walked only while they resolve
 *    inside the share root. A walk stops at a link (lstat semantics, as
 *    upstream); an open that would follow a link first resolves the target
 *    lexically and refuses (EACCES) anything pointing outside the root;
 *    chains deeper than 8 refuse with ELOOP. Absolute targets must sit
 *    under the root realpath.
 *  - FIFOs and sockets are refused (EOPNOTSUPP) and device nodes are
 *    refused (EPERM), so a guest can never park a host slice on a blocking
 *    special file.
 *  - mknod/create-time failures clean up partial state; nothing calls
 *    exit(); create returns NULL and the machine reports an honest error.
 */
#include "../devices.h"
#include "virtio_9p_port.h"
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <dirent.h>
#include <limits.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#if defined(__linux__)
#include <sys/sysmacros.h>
#endif
#include <time.h>

/* ---- virtio-mmio transport constants (shared with blk/net) ---- */
#define VIRTIO_F_VERSION_1    (1ULL << 32)
#define VIRTIO_9P_MOUNT_TAG   (1ULL << 0)
#define FS_FEATURES           (VIRTIO_F_VERSION_1 | VIRTIO_9P_MOUNT_TAG)

#define VIRTQ_DESC_F_NEXT     1
#define VIRTQ_DESC_F_WRITE    2

#define QUEUE_NUM_MAX 256
#define VIRTQ_MAX     512          /* descriptor-chain walk bound */

/* Largest 9P message we support; also the size of the per-device gather/scatter
 * buffers. The negotiated msize (Tversion) is clamped to this. */
#define P9_MSIZE_MAX  (128 * 1024)

#define TAG_MAX 128

/* ---- 9P2000.L message types ---- */
enum {
    P9_RLERROR      = 7,
    P9_TSTATFS      = 8,  P9_RSTATFS      = 9,
    P9_TLOPEN       = 12, P9_RLOPEN       = 13,
    P9_TLCREATE     = 14, P9_RLCREATE     = 15,
    P9_TSYMLINK     = 16, P9_RSYMLINK     = 17,
    P9_TMKNOD       = 18, P9_RMKNOD       = 19,
    P9_TRENAME      = 20, P9_RRENAME      = 21,
    P9_TREADLINK    = 22, P9_RREADLINK    = 23,
    P9_TGETATTR     = 24, P9_RGETATTR     = 25,
    P9_TSETATTR     = 26, P9_RSETATTR     = 27,
    P9_TXATTRWALK   = 30, P9_RXATTRWALK   = 31,
    P9_TXATTRCREATE = 32, P9_RXATTRCREATE = 33,
    P9_TREADDIR     = 40, P9_RREADDIR     = 41,
    P9_TFSYNC       = 50, P9_RFSYNC       = 51,
    P9_TLOCK        = 52, P9_RLOCK        = 53,
    P9_TGETLOCK     = 54, P9_RGETLOCK     = 55,
    P9_TLINK        = 70, P9_RLINK        = 71,
    P9_TMKDIR       = 72, P9_RMKDIR       = 73,
    P9_TRENAMEAT    = 74, P9_RRENAMEAT    = 75,
    P9_TUNLINKAT    = 76, P9_RUNLINKAT    = 77,
    P9_TVERSION     = 100, P9_RVERSION    = 101,
    P9_TATTACH      = 104, P9_RATTACH     = 105,
    P9_TFLUSH       = 108, P9_RFLUSH      = 109,
    P9_TWALK        = 110, P9_RWALK       = 111,
    P9_TREAD        = 116, P9_RREAD       = 117,
    P9_TWRITE       = 118, P9_RWRITE      = 119,
    P9_TCLUNK       = 120, P9_RCLUNK      = 121,
    P9_TREMOVE      = 122, P9_RREMOVE     = 123,
};

/* qid.type */
#define P9_QTDIR     0x80
#define P9_QTSYMLINK 0x02
#define P9_QTFILE    0x00

/* Tgetattr / Rgetattr valid mask (subset we fill: mode..blocks, uid/gid, ino). */
#define P9_STATS_BASIC 0x000007ffULL

/* Tsetattr valid bits. */
#define P9_ATTR_MODE      (1u << 0)
#define P9_ATTR_UID       (1u << 1)
#define P9_ATTR_GID       (1u << 2)
#define P9_ATTR_SIZE      (1u << 3)
#define P9_ATTR_ATIME     (1u << 4)
#define P9_ATTR_MTIME     (1u << 5)
#define P9_ATTR_CTIME     (1u << 6)
#define P9_ATTR_ATIME_SET (1u << 7)
#define P9_ATTR_MTIME_SET (1u << 8)

#define P9_MAXWELEM 16            /* max walk elements per Twalk */
#define P9_NAME_MAX 512

/* Refuse link chains longer than this (kernel would give up too). */
#define P9_SYMLINK_MAX_DEPTH 8

#ifndef AT_REMOVEDIR
#define AT_REMOVEDIR 0x200
#endif

/* ---- fid table ---- */
#define FID_BUCKETS 1024
typedef struct P9Fid {
    u32   fid;
    struct P9Fid *next;
    int   fd;                     /* -1 unless opened as a file (Tlopen/Tlcreate) */
    DIR  *dir;                    /* non-NULL when opened as a directory */
    char  path[PATH_MAX];         /* ROOT-RELATIVE path; "" == share root */
} P9Fid;

typedef struct VirtIO9P {
    Machine *m; GIC *gic; int irq;

    int    rootfd;                /* pinned share root (O_RDONLY|O_DIRECTORY) */
    char   root[PATH_MAX]; size_t rootlen;   /* realpath'd root (diagnostics + link policy) */
    bool   ro;
    char   tag[TAG_MAX]; u16 tag_len;

    /* virtio-mmio state (single request queue) */
    u32 status, isr;
    u32 dev_feat_sel, drv_feat_sel; u64 drv_feat;
    u32 queue_sel;
    u32 q_num, q_ready;
    u64 q_desc, q_avail, q_used;
    u16 last_avail;

    u32 msize;                    /* negotiated in Tversion */
    u8 *req, *resp;               /* P9_MSIZE_MAX gather/scatter buffers */

    P9Fid *fids[FID_BUCKETS];
} VirtIO9P;

/* ---- stat field access (Darwin st_*timespec vs POSIX st_*tim) ---- */
#if defined(__APPLE__)
#define P9_STAT_ATIME_NS(st)  ((st)->st_atimespec.tv_nsec)
#define P9_STAT_MTIME_NS(st)  ((st)->st_mtimespec.tv_nsec)
#define P9_STAT_CTIME_NS(st)  ((st)->st_ctimespec.tv_nsec)
#else
#define P9_STAT_ATIME_NS(st)  ((st)->st_atim.tv_nsec)
#define P9_STAT_MTIME_NS(st)  ((st)->st_mtim.tv_nsec)
#define P9_STAT_CTIME_NS(st)  ((st)->st_ctim.tv_nsec)
#endif

/* ============================ marshalling ============================ */

typedef struct { u8 *b; u32 cap; u32 pos; bool err; } Cur;

static u8  c_u8 (Cur *c) { if (c->pos + 1 > c->cap) { c->err = true; return 0; } return c->b[c->pos++]; }
static u16 c_u16(Cur *c) { u16 v = c_u8(c); v |= (u16)c_u8(c) << 8; return v; }
static u32 c_u32(Cur *c) { u32 v = c_u16(c); v |= (u32)c_u16(c) << 16; return v; }
static u64 c_u64(Cur *c) { u64 v = c_u32(c); v |= (u64)c_u32(c) << 32; return v; }

/* Read a 9P string (u16 len + bytes) into a NUL-terminated buffer. Advances the
 * cursor by the full declared length even when the copy is truncated. */
static bool c_str(Cur *c, char *out, size_t outsz) {
    u16 len = c_u16(c);
    if (c->err) { if (outsz) out[0] = '\0'; return false; }
    if ((u64)c->pos + len > c->cap) { c->err = true; if (outsz) out[0] = '\0'; return false; }
    size_t n = len < outsz - 1 ? len : outsz - 1;
    memcpy(out, c->b + c->pos, n); out[n] = '\0';
    c->pos += len;
    return true;
}

static void p_u8 (Cur *c, u8  v) { if (c->pos + 1 > c->cap) { c->err = true; return; } c->b[c->pos++] = v; }
static void p_u16(Cur *c, u16 v) { p_u8(c, (u8)v); p_u8(c, (u8)(v >> 8)); }
static void p_u32(Cur *c, u32 v) { p_u16(c, (u16)v); p_u16(c, (u16)(v >> 16)); }
static void p_u64(Cur *c, u64 v) { p_u32(c, (u32)v); p_u32(c, (u32)(v >> 32)); }
static void p_str(Cur *c, const char *s) {
    size_t n = strlen(s); if (n > 0xffff) n = 0xffff;
    p_u16(c, (u16)n);
    if (c->pos + n > c->cap) { c->err = true; return; }
    memcpy(c->b + c->pos, s, n); c->pos += (u32)n;
}
static void p_qid(Cur *c, u8 type, u32 ver, u64 path) { p_u8(c, type); p_u32(c, ver); p_u64(c, path); }

/* Patch the 4-byte size prefix (LE) after a response is fully built. */
static void patch_size(u8 *buf, u32 sz) {
    buf[0] = (u8)sz; buf[1] = (u8)(sz >> 8); buf[2] = (u8)(sz >> 16); buf[3] = (u8)(sz >> 24);
}

/* Rlerror(ecode) — the 9P2000.L error reply; ecode is a Linux-wire errno. */
static u32 mk_lerror(VirtIO9P *v, u16 tag, int ec, u32 cap) {
    Cur c = { v->resp, cap < 11 ? 11 : cap, 0, false };
    p_u32(&c, 0); p_u8(&c, P9_RLERROR); p_u16(&c, tag); p_u32(&c, (u32)p9_err(ec));
    patch_size(v->resp, c.pos);
    return c.pos;
}

static Cur resp_begin(VirtIO9P *v, u8 type, u16 tag, u32 cap) {
    Cur c = { v->resp, cap, 0, false };
    p_u32(&c, 0); p_u8(&c, type); p_u16(&c, tag);
    return c;
}
static u32 resp_finish(Cur *o, VirtIO9P *v, u16 tag, u32 cap) {
    if (o->err) return mk_lerror(v, tag, EMSGSIZE, cap);
    patch_size(v->resp, o->pos);
    return o->pos;
}

/* ============================ qid / paths ============================ */

/* Stable 64-bit qid.path from (st_dev, st_ino). */
static u64 qid_mix(u64 dev, u64 ino) {
    u64 h = dev * 0x9E3779B97F4A7C15ULL;
    h ^= ino + 0x9E3779B97F4A7C15ULL + (h << 6) + (h >> 2);
    return h ? h : 1;
}
static u8 qid_type(mode_t mode) {
    if (S_ISDIR(mode))  return P9_QTDIR;
    if (S_ISLNK(mode))  return P9_QTSYMLINK;
    return P9_QTFILE;
}

/* Contained stat: the root descriptor pins the tree, so a root-relative path
 * can never name anything outside the share. */
static int p9_stat(VirtIO9P *v, const char *rel, struct stat *st) {
    if (rel[0] == '\0') return fstat(v->rootfd, st);
    return fstatat(v->rootfd, rel, st, AT_SYMLINK_NOFOLLOW);
}

static int qid_of(VirtIO9P *v, const char *rel, u8 *type, u32 *ver, u64 *qpath) {
    struct stat st;
    if (p9_stat(v, rel, &st)) return -1;
    *type = qid_type(st.st_mode);
    *ver = 0;
    *qpath = qid_mix((u64)st.st_dev, (u64)st.st_ino);
    return 0;
}

/* Lexically join a root-relative base directory and a relative symlink
 * target into a normalized root-relative path ('..' clamps at the root).
 * Returns true on success. */
static bool p9_lexjoin(const char *base, const char *rel, char *out, size_t outsz) {
    char tmp[PATH_MAX * 2];
    int n = snprintf(tmp, sizeof(tmp), "%s%s%s",
                     base, base[0] ? "/" : "", rel);
    if (n < 0 || (size_t)n >= sizeof(tmp) || (size_t)n >= outsz + PATH_MAX) return false;
    char result[PATH_MAX];
    result[0] = '\0';
    char *save = NULL;
    for (char *comp = strtok_r(tmp, "/", &save); comp; comp = strtok_r(NULL, "/", &save)) {
        char next[PATH_MAX];
        if (!p9_path_child(result, comp, next, sizeof(next))) return false;
        snprintf(result, sizeof(result), "%s", next);
    }
    if (strlen(result) + 1 > outsz) return false;
    snprintf(out, outsz, "%s", result);
    return true;
}

/* Resolve a root-relative path to its canonical root-relative form, following
 * symlink components whose targets stay inside the share root. Used wherever
 * the host would otherwise follow a link (walk accumulation past a link,
 * open/setattr of a link target). Returns 0 and fills out ("" == root), or
 * -1 with errno set: EACCES for a target outside the root, ELOOP past the
 * depth bound, or the failing component's errno. */
static int p9_resolve_rel(VirtIO9P *v, const char *rel, char *out, size_t outsz) {
    char work[PATH_MAX * 2];
    snprintf(work, sizeof(work), "%s", rel);
    for (int depth = 0;; depth++) {
        char cur[PATH_MAX];
        cur[0] = '\0';
        bool restart = false;
        char *p = work;
        while (*p) {
            char *slash = strchr(p, '/');
            size_t clen = slash ? (size_t)(slash - p) : strlen(p);
            if (clen == 0) { p = slash ? slash + 1 : p; if (!slash) break; continue; }
            if (clen > NAME_MAX) { errno = ENAMETOOLONG; return -1; }
            char comp[NAME_MAX + 1];
            memcpy(comp, p, clen); comp[clen] = '\0';
            if (!strcmp(comp, ".")) { p = slash ? slash + 1 : p + clen; if (!slash) break; continue; }
            if (!strcmp(comp, "..")) {
                char up[PATH_MAX];
                p9_path_child(cur, "..", up, sizeof(up));
                snprintf(cur, sizeof(cur), "%s", up);
                p = slash ? slash + 1 : p + clen;
                if (!slash) break;
                continue;
            }
            char cand[PATH_MAX];
            if (!p9_path_child(cur, comp, cand, sizeof(cand))) { errno = ENAMETOOLONG; return -1; }
            struct stat st;
            if (fstatat(v->rootfd, cand, &st, AT_SYMLINK_NOFOLLOW) != 0) return -1;
            if (S_ISLNK(st.st_mode)) {
                if (depth >= P9_SYMLINK_MAX_DEPTH) { errno = ELOOP; return -1; }
                char target[4096];
                ssize_t tn = readlinkat(v->rootfd, cand, target, sizeof(target) - 1);
                if (tn < 0) return -1;
                target[tn] = '\0';
                const char *sub;
                char subbuf[PATH_MAX];
                if (target[0] == '/') {
                    /* Absolute targets must sit under the root realpath. */
                    if (strncmp(target, v->root, v->rootlen) == 0 &&
                        (target[v->rootlen] == '/' || target[v->rootlen] == '\0')) {
                        sub = target + v->rootlen;
                        while (*sub == '/') sub++;
                    } else { errno = EACCES; return -1; }
                } else {
                    if (!p9_lexjoin(cur, target, subbuf, sizeof(subbuf))) { errno = ENAMETOOLONG; return -1; }
                    sub = subbuf;
                }
                const char *rest = slash ? slash + 1 : "";
                if (sub[0] && rest[0])
                    snprintf(work, sizeof(work), "%s/%s", sub, rest);
                else
                    snprintf(work, sizeof(work), "%s%s", sub, rest);
                restart = true;
                break;
            }
            snprintf(cur, sizeof(cur), "%s", cand);
            p = slash ? slash + 1 : p + clen;
            if (!slash) break;
        }
        if (!restart) {
            if (strlen(cur) + 1 > outsz) { errno = ENAMETOOLONG; return -1; }
            snprintf(out, outsz, "%s", cur);
            return 0;
        }
    }
}

/* Resolve a fid's path for an operation that follows links (open/setattr on
 * the final component). */
static int p9_resolve_fid_path(VirtIO9P *v, const char *rel, char *out, size_t outsz) {
    return p9_resolve_rel(v, rel, out, outsz);
}

/* Refuse anything that could block a slice or punch outside the file model. */
static bool p9_mode_blocked(mode_t mode) {
    return S_ISFIFO(mode) || S_ISSOCK(mode);
}

/* ============================ fid table ============================ */

static P9Fid *fid_find(VirtIO9P *v, u32 fid) {
    for (P9Fid *f = v->fids[fid & (FID_BUCKETS - 1)]; f; f = f->next)
        if (f->fid == fid) return f;
    return NULL;
}
static P9Fid *fid_new(VirtIO9P *v, u32 fid, const char *path) {
    P9Fid *f = fid_find(v, fid);
    if (f) {                                   /* reuse: drop any open handles */
        if (f->fd >= 0) close(f->fd);
        if (f->dir) closedir(f->dir);
        f->fd = -1; f->dir = NULL;
    } else {
        f = calloc(1, sizeof(*f));
        f->fid = fid; f->fd = -1;
        u32 b = fid & (FID_BUCKETS - 1);
        f->next = v->fids[b]; v->fids[b] = f;
    }
    snprintf(f->path, sizeof(f->path), "%s", path);
    return f;
}
static void fid_del(VirtIO9P *v, u32 fid) {
    P9Fid **pp = &v->fids[fid & (FID_BUCKETS - 1)];
    while (*pp) {
        if ((*pp)->fid == fid) {
            P9Fid *f = *pp; *pp = f->next;
            if (f->fd >= 0) close(f->fd);
            if (f->dir) closedir(f->dir);
            free(f);
            return;
        }
        pp = &(*pp)->next;
    }
}
static void fids_clear(VirtIO9P *v) {
    for (int i = 0; i < FID_BUCKETS; i++) {
        P9Fid *f = v->fids[i];
        while (f) { P9Fid *n = f->next; if (f->fd >= 0) close(f->fd); if (f->dir) closedir(f->dir); free(f); f = n; }
        v->fids[i] = NULL;
    }
}

/* ============================ handlers ============================ */

static u32 h_version(VirtIO9P *v, Cur *in, u16 tag, u32 cap) {
    u32 msz = c_u32(in);
    char ver[32]; c_str(in, ver, sizeof(ver));
    fids_clear(v);                             /* Tversion aborts all fids/IO */
    v->msize = msz < P9_MSIZE_MAX ? msz : P9_MSIZE_MAX;
    if (v->msize < 4096) v->msize = 4096;
    const char *rver = !strncmp(ver, "9P2000.L", 8) ? "9P2000.L" : "unknown";
    Cur o = resp_begin(v, P9_RVERSION, tag, cap);
    p_u32(&o, v->msize); p_str(&o, rver);
    return resp_finish(&o, v, tag, cap);
}

static u32 h_attach(VirtIO9P *v, Cur *in, u16 tag, u32 cap) {
    u32 fid = c_u32(in); (void)c_u32(in);      /* afid ignored */
    char uname[128], aname[256];
    c_str(in, uname, sizeof(uname)); c_str(in, aname, sizeof(aname));
    (void)c_u32(in);                           /* n_uname ignored */
    if (in->err) return mk_lerror(v, tag, EINVAL, cap);
    u8 qt; u32 qv; u64 qp;
    if (qid_of(v, "", &qt, &qv, &qp)) return mk_lerror(v, tag, errno, cap);
    fid_new(v, fid, "");
    Cur o = resp_begin(v, P9_RATTACH, tag, cap);
    p_qid(&o, qt, qv, qp);
    return resp_finish(&o, v, tag, cap);
}

static u32 h_walk(VirtIO9P *v, Cur *in, u16 tag, u32 cap) {
    u32 fid = c_u32(in), newfid = c_u32(in);
    u16 nw = c_u16(in);
    if (in->err || nw > P9_MAXWELEM) return mk_lerror(v, tag, EINVAL, cap);
    P9Fid *f = fid_find(v, fid);
    if (!f) return mk_lerror(v, tag, EBADF, cap);

    char names[P9_MAXWELEM][P9_NAME_MAX];
    for (u16 i = 0; i < nw; i++) c_str(in, names[i], sizeof(names[i]));
    if (in->err) return mk_lerror(v, tag, EINVAL, cap);

    char cur[PATH_MAX];
    snprintf(cur, sizeof(cur), "%s", f->path);
    u8 qt[P9_MAXWELEM]; u32 qv[P9_MAXWELEM]; u64 qp[P9_MAXWELEM];
    u16 nqid = 0;
    for (u16 i = 0; i < nw; i++) {
        /* '.' and '..' are legal walk elements (p9_path_child normalizes
         * them); everything else must be a plain single element. */
        if (!p9_name_ok(names[i]) && strcmp(names[i], ".") && strcmp(names[i], "..")) {
            if (i == 0) return mk_lerror(v, tag, EINVAL, cap);
            break;
        }
        char child[PATH_MAX];
        if (!p9_path_child(cur, names[i], child, sizeof(child))) {
            if (i == 0) return mk_lerror(v, tag, ENAMETOOLONG, cap);
            break;
        }
        /* Contain the accumulated path: a symlink component may redirect
         * only to a target inside the root; an escaping walk stops here. */
        char resolved[PATH_MAX];
        if (p9_resolve_rel(v, child, resolved, sizeof(resolved)) != 0) {
            if (i == 0) return mk_lerror(v, tag, errno, cap);
            break;
        }
        if (qid_of(v, resolved, &qt[i], &qv[i], &qp[i])) {
            if (i == 0) return mk_lerror(v, tag, errno, cap);
            break;
        }
        snprintf(cur, sizeof(cur), "%s", resolved);
        nqid++;
    }
    if (nqid == nw) {                          /* full walk: (re)assign newfid */
        if (newfid == fid) {
            if (f->fd >= 0) { close(f->fd); f->fd = -1; }
            if (f->dir) { closedir(f->dir); f->dir = NULL; }
            snprintf(f->path, sizeof(f->path), "%s", cur);
        } else {
            fid_new(v, newfid, cur);
        }
    }
    Cur o = resp_begin(v, P9_RWALK, tag, cap);
    p_u16(&o, nqid);
    for (u16 i = 0; i < nqid; i++) p_qid(&o, qt[i], qv[i], qp[i]);
    return resp_finish(&o, v, tag, cap);
}

static u32 h_getattr(VirtIO9P *v, Cur *in, u16 tag, u32 cap) {
    u32 fid = c_u32(in); (void)c_u64(in);      /* request_mask ignored */
    if (in->err) return mk_lerror(v, tag, EINVAL, cap);
    P9Fid *f = fid_find(v, fid);
    if (!f) return mk_lerror(v, tag, EBADF, cap);
    struct stat st;
    if (p9_stat(v, f->path, &st)) return mk_lerror(v, tag, errno, cap);
    Cur o = resp_begin(v, P9_RGETATTR, tag, cap);
    p_u64(&o, P9_STATS_BASIC);
    p_qid(&o, qid_type(st.st_mode), 0, qid_mix((u64)st.st_dev, (u64)st.st_ino));
    p_u32(&o, (u32)st.st_mode);
    p_u32(&o, (u32)st.st_uid);
    p_u32(&o, (u32)st.st_gid);
    p_u64(&o, (u64)st.st_nlink);
    p_u64(&o, (u64)st.st_rdev);
    p_u64(&o, (u64)st.st_size);
    p_u64(&o, (u64)st.st_blksize);
    p_u64(&o, (u64)st.st_blocks);
    p_u64(&o, (u64)st.st_atime); p_u64(&o, (u64)P9_STAT_ATIME_NS(&st));
    p_u64(&o, (u64)st.st_mtime); p_u64(&o, (u64)P9_STAT_MTIME_NS(&st));
    p_u64(&o, (u64)st.st_ctime); p_u64(&o, (u64)P9_STAT_CTIME_NS(&st));
    p_u64(&o, 0); p_u64(&o, 0);                /* btime */
    p_u64(&o, 0);                              /* gen */
    p_u64(&o, 0);                              /* data_version */
    return resp_finish(&o, v, tag, cap);
}

/* chmod on the link itself (never follows, whatever the host default). */
static int p9_chmod_link(VirtIO9P *v, const char *rel, mode_t mode) {
#if defined(__APPLE__)
    char abs[PATH_MAX];
    snprintf(abs, sizeof(abs), "%s%s%s", v->root, rel[0] ? "/" : "", rel);
    return lchmod(abs, mode);
#else
    return fchmodat(v->rootfd, rel[0] ? rel : ".", mode, AT_SYMLINK_NOFOLLOW);
#endif
}

static u32 h_setattr(VirtIO9P *v, Cur *in, u16 tag, u32 cap) {
    u32 fid = c_u32(in), valid = c_u32(in);
    u32 mode = c_u32(in), uid = c_u32(in), gid = c_u32(in);
    u64 size = c_u64(in);
    u64 at_s = c_u64(in), at_ns = c_u64(in), mt_s = c_u64(in), mt_ns = c_u64(in);
    if (in->err) return mk_lerror(v, tag, EINVAL, cap);
    if (v->ro) return mk_lerror(v, tag, EROFS, cap);
    P9Fid *f = fid_find(v, fid);
    if (!f) return mk_lerror(v, tag, EBADF, cap);

    /* Refuse attribute changes through a symlink: the fid names the link
     * itself after walk, and silently retargeting a host path would break
     * containment. chmod/chown below act on the link node intentionally. */
    struct stat lst;
    if (p9_stat(v, f->path, &lst)) return mk_lerror(v, tag, errno, cap);
    bool is_link = S_ISLNK(lst.st_mode);
    if (is_link && (valid & (P9_ATTR_SIZE | P9_ATTR_ATIME | P9_ATTR_MTIME | P9_ATTR_CTIME)))
        return mk_lerror(v, tag, EACCES, cap);

    if (valid & P9_ATTR_MODE)
        if (p9_chmod_link(v, f->path, (mode_t)(mode & 07777))) return mk_lerror(v, tag, errno, cap);
    if (valid & (P9_ATTR_UID | P9_ATTR_GID)) {
        uid_t u = (valid & P9_ATTR_UID) ? (uid_t)uid : (uid_t)-1;
        gid_t g = (valid & P9_ATTR_GID) ? (gid_t)gid : (gid_t)-1;
        /* lchown semantics on the link node, matching p9_stat. */
#if defined(__APPLE__)
        char abs[PATH_MAX];
        snprintf(abs, sizeof(abs), "%s%s%s", v->root, f->path[0] ? "/" : "", f->path);
        if (lchown(abs, u, g) && errno != EPERM) return mk_lerror(v, tag, errno, cap);
#else
        if (fchownat(v->rootfd, f->path[0] ? f->path : ".", u, g, AT_SYMLINK_NOFOLLOW) && errno != EPERM)
            return mk_lerror(v, tag, errno, cap);
#endif
    }
    if (valid & P9_ATTR_SIZE) {
        char resolved[PATH_MAX];
        if (p9_resolve_fid_path(v, f->path, resolved, sizeof(resolved)) != 0)
            return mk_lerror(v, tag, errno, cap);
        int fd = openat(v->rootfd, resolved[0] ? resolved : ".",
                        O_WRONLY | O_NOFOLLOW | O_CLOEXEC);
        if (fd < 0) return mk_lerror(v, tag, errno, cap);
        int r = ftruncate(fd, (off_t)size);
        int e = errno;
        close(fd);
        if (r) return mk_lerror(v, tag, e, cap);
    }
    if (valid & (P9_ATTR_ATIME | P9_ATTR_MTIME)) {
        struct timespec ts[2];
        if (valid & P9_ATTR_ATIME)
            ts[0] = (valid & P9_ATTR_ATIME_SET) ? (struct timespec){ (time_t)at_s, (long)at_ns }
                                                : (struct timespec){ 0, UTIME_NOW };
        else ts[0] = (struct timespec){ 0, UTIME_OMIT };
        if (valid & P9_ATTR_MTIME)
            ts[1] = (valid & P9_ATTR_MTIME_SET) ? (struct timespec){ (time_t)mt_s, (long)mt_ns }
                                                : (struct timespec){ 0, UTIME_NOW };
        else ts[1] = (struct timespec){ 0, UTIME_OMIT };
        if (utimensat(v->rootfd, f->path[0] ? f->path : ".", ts, AT_SYMLINK_NOFOLLOW))
            return mk_lerror(v, tag, errno, cap);
    }
    Cur o = resp_begin(v, P9_RSETATTR, tag, cap);
    return resp_finish(&o, v, tag, cap);
}

/* Open a directory fid for listing: fdopendir owns the descriptor. */
static DIR *p9_opendir(VirtIO9P *v, const char *rel) {
    int fd = openat(v->rootfd, rel[0] ? rel : ".",
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) return NULL;
    DIR *d = fdopendir(fd);
    if (!d) close(fd);
    return d;
}

static u32 h_readdir(VirtIO9P *v, Cur *in, u16 tag, u32 cap) {
    u32 fid = c_u32(in); u64 off = c_u64(in); u32 count = c_u32(in);
    if (in->err) return mk_lerror(v, tag, EINVAL, cap);
    P9Fid *f = fid_find(v, fid);
    if (!f) return mk_lerror(v, tag, EBADF, cap);
    if (!f->dir) { f->dir = p9_opendir(v, f->path); if (!f->dir) return mk_lerror(v, tag, errno, cap); }
    if (off == 0) rewinddir(f->dir); else seekdir(f->dir, (long)off);

    Cur o = resp_begin(v, P9_RREADDIR, tag, cap);
    u32 count_pos = o.pos; p_u32(&o, 0);       /* placeholder data count */
    u32 data_start = o.pos;

    bool any = false;
    for (;;) {
        long here = telldir(f->dir);
        errno = 0;
        struct dirent *de = readdir(f->dir);
        if (!de) break;
        const char *name = de->d_name;
        u32 esz = 13 + 8 + 1 + 2 + (u32)strlen(name);
        if ((o.pos - data_start) + esz > count || o.pos + esz > o.cap) {
            seekdir(f->dir, here);             /* doesn't fit: leave it for next call */
            /* If not even the first entry fits the client's requested count, an
             * empty Rreaddir would be read as end-of-directory and silently
             * truncate the listing. Report EINVAL so the client retries with a
             * larger count instead. (An empty directory never reaches here.) */
            if (!any && (o.pos - data_start) + esz > count)
                return mk_lerror(v, tag, EINVAL, cap);
            break;
        }
        any = true;
        u8 qt = P9_QTFILE, tbyte = de->d_type; u64 qp;
        char child[PATH_MAX]; struct stat st;
        int need = snprintf(child, sizeof(child), "%s%s%s",
                            f->path, f->path[0] ? "/" : "", name);
        if (need > 0 && (size_t)need < sizeof(child) && p9_stat(v, child, &st) == 0) {
            qt = qid_type(st.st_mode);
            qp = qid_mix((u64)st.st_dev, (u64)st.st_ino);
            tbyte = (u8)((st.st_mode & 0170000) >> 12);
        } else {
            qp = qid_mix(0, (u64)de->d_ino);
        }
        p_qid(&o, qt, 0, qp);
        p_u64(&o, (u64)telldir(f->dir));       /* offset to resume after this entry */
        p_u8(&o, tbyte);
        p_str(&o, name);
    }
    patch_size(v->resp + count_pos, o.pos - data_start);  /* backfill data count */
    return resp_finish(&o, v, tag, cap);
}

static u32 h_lopen(VirtIO9P *v, Cur *in, u16 tag, u32 cap) {
    u32 fid = c_u32(in), fl = c_u32(in);
    if (in->err) return mk_lerror(v, tag, EINVAL, cap);
    P9Fid *f = fid_find(v, fid);
    if (!f) return mk_lerror(v, tag, EBADF, cap);
    struct stat st;
    if (p9_stat(v, f->path, &st)) return mk_lerror(v, tag, errno, cap);
    if (v->ro && p9_dotl_wants_write(fl)) return mk_lerror(v, tag, EROFS, cap);
    if (p9_mode_blocked(st.st_mode)) return mk_lerror(v, tag, EOPNOTSUPP, cap);
    if (S_ISBLK(st.st_mode) || S_ISCHR(st.st_mode))
        return mk_lerror(v, tag, EPERM, cap);  /* device nodes: never from a share */

    if (S_ISDIR(st.st_mode)) {
        /* Directories list only; the guest's flag word is not trusted to
         * pick the host open mode for us. */
        DIR *d = p9_opendir(v, f->path);
        if (!d) return mk_lerror(v, tag, errno, cap);
        if (f->dir) closedir(f->dir);
        f->dir = d;
    } else {
        int err = 0;
        int host_flags = p9_dotl_to_host(fl, &err);
        if (host_flags < 0) return mk_lerror(v, tag, err, cap);
        /* Follow an in-root symlink final component; refuse escapes. */
        char resolved[PATH_MAX];
        const char *open_rel = f->path;
        if (S_ISLNK(st.st_mode) && !(fl & P9_O_NOFOLLOW)) {
            if (p9_resolve_fid_path(v, f->path, resolved, sizeof(resolved)) != 0)
                return mk_lerror(v, tag, errno, cap);
            open_rel = resolved;
            struct stat tst;
            if (fstatat(v->rootfd, open_rel, &tst, AT_SYMLINK_NOFOLLOW) != 0)
                return mk_lerror(v, tag, errno, cap);
            if (p9_mode_blocked(tst.st_mode) || S_ISBLK(tst.st_mode) || S_ISCHR(tst.st_mode))
                return mk_lerror(v, tag, EACCES, cap);
        }
        int fd = openat(v->rootfd, open_rel[0] ? open_rel : ".",
                        host_flags | O_CLOEXEC, 0666);
        if (fd < 0) return mk_lerror(v, tag, errno, cap);
        if (f->fd >= 0) close(f->fd);
        f->fd = fd;
    }
    Cur o = resp_begin(v, P9_RLOPEN, tag, cap);
    p_qid(&o, qid_type(st.st_mode), 0, qid_mix((u64)st.st_dev, (u64)st.st_ino));
    p_u32(&o, 0);                              /* iounit 0 => use msize */
    return resp_finish(&o, v, tag, cap);
}

/* Open a fid's own directory ("" names the share root) for name-based
 * create ops; the new entry is addressed by its single-element name. */
static int p9_open_dir_fd(VirtIO9P *v, const char *rel) {
    return openat(v->rootfd, rel[0] ? rel : ".",
                  O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
}

static bool p9_elem_ok(const char *name) {   /* create-name policy */
    return p9_name_ok(name);                 /* rejects empty, ".", "..", slashes */
}

static u32 h_lcreate(VirtIO9P *v, Cur *in, u16 tag, u32 cap) {
    u32 fid = c_u32(in);
    char name[P9_NAME_MAX]; c_str(in, name, sizeof(name));
    u32 fl = c_u32(in), mode = c_u32(in); (void)c_u32(in);  /* gid */
    if (in->err) return mk_lerror(v, tag, EINVAL, cap);
    if (v->ro) return mk_lerror(v, tag, EROFS, cap);
    P9Fid *f = fid_find(v, fid);
    if (!f) return mk_lerror(v, tag, EBADF, cap);
    if (!p9_elem_ok(name)) return mk_lerror(v, tag, EINVAL, cap);
    int err = 0;
    int host_flags = p9_dotl_to_host(fl, &err);
    if (host_flags < 0) return mk_lerror(v, tag, err, cap);
    int dfd = p9_open_dir_fd(v, f->path);
    if (dfd < 0) return mk_lerror(v, tag, errno, cap);
    int fd = openat(dfd, name, host_flags | O_CREAT | O_CLOEXEC, (mode_t)(mode & 07777));
    if (fd < 0) { int e = errno; close(dfd); return mk_lerror(v, tag, e, cap); }
    struct stat st;
    if (fstat(fd, &st) != 0) { int e = errno; close(fd); close(dfd); return mk_lerror(v, tag, e, cap); }
    if (p9_mode_blocked(st.st_mode)) { close(fd); close(dfd); return mk_lerror(v, tag, EOPNOTSUPP, cap); }
    close(dfd);
    if (f->fd >= 0) close(f->fd);
    if (f->dir) { closedir(f->dir); f->dir = NULL; }
    f->fd = fd;
    /* fid now refers to the new file under its creating directory. */
    char child[PATH_MAX];
    if (!p9_path_child(f->path, name, child, sizeof(child))) return mk_lerror(v, tag, ENAMETOOLONG, cap);
    snprintf(f->path, sizeof(f->path), "%s", child);
    Cur o = resp_begin(v, P9_RLCREATE, tag, cap);
    p_qid(&o, qid_type(st.st_mode), 0, qid_mix((u64)st.st_dev, (u64)st.st_ino));
    p_u32(&o, 0);
    return resp_finish(&o, v, tag, cap);
}

static u32 h_read(VirtIO9P *v, Cur *in, u16 tag, u32 cap) {
    u32 fid = c_u32(in); u64 off = c_u64(in); u32 count = c_u32(in);
    if (in->err) return mk_lerror(v, tag, EINVAL, cap);
    P9Fid *f = fid_find(v, fid);
    if (!f || f->fd < 0) return mk_lerror(v, tag, EBADF, cap);
    u32 room = cap > 11 ? cap - 11 : 0;        /* Rread header = size+type+tag+count = 11 */
    if (count > room) count = room;
    if (count > P9_MSIZE_MAX - 11) count = P9_MSIZE_MAX - 11;
    Cur o = resp_begin(v, P9_RREAD, tag, cap);
    u32 cnt_pos = o.pos; p_u32(&o, 0);
    ssize_t n = pread(f->fd, v->resp + o.pos, count, (off_t)off);
    if (n < 0) return mk_lerror(v, tag, errno, cap);
    o.pos += (u32)n;
    patch_size(v->resp + cnt_pos, (u32)n);
    return resp_finish(&o, v, tag, cap);
}

static u32 h_write(VirtIO9P *v, Cur *in, u16 tag, u32 cap) {
    u32 fid = c_u32(in); u64 off = c_u64(in); u32 count = c_u32(in);
    if (in->err) return mk_lerror(v, tag, EINVAL, cap);
    if (v->ro) return mk_lerror(v, tag, EROFS, cap);
    P9Fid *f = fid_find(v, fid);
    if (!f || f->fd < 0) return mk_lerror(v, tag, EBADF, cap);
    if (in->pos + count > in->cap) count = in->cap - in->pos;  /* clamp to gathered data */
    ssize_t n = pwrite(f->fd, v->req + in->pos, count, (off_t)off);
    if (n < 0) return mk_lerror(v, tag, errno, cap);
    Cur o = resp_begin(v, P9_RWRITE, tag, cap);
    p_u32(&o, (u32)n);
    return resp_finish(&o, v, tag, cap);
}

static u32 h_mkdir(VirtIO9P *v, Cur *in, u16 tag, u32 cap) {
    u32 dfid = c_u32(in);
    char name[P9_NAME_MAX]; c_str(in, name, sizeof(name));
    u32 mode = c_u32(in); (void)c_u32(in);     /* gid */
    if (in->err) return mk_lerror(v, tag, EINVAL, cap);
    if (v->ro) return mk_lerror(v, tag, EROFS, cap);
    P9Fid *f = fid_find(v, dfid);
    if (!f) return mk_lerror(v, tag, EBADF, cap);
    if (!p9_elem_ok(name)) return mk_lerror(v, tag, EINVAL, cap);
    int dfd = p9_open_dir_fd(v, f->path);
    if (dfd < 0) return mk_lerror(v, tag, errno, cap);
    if (mkdirat(dfd, name, (mode_t)(mode & 07777))) { int e = errno; close(dfd); return mk_lerror(v, tag, e, cap); }
    close(dfd);
    char child[PATH_MAX];
    if (!p9_path_child(f->path, name, child, sizeof(child))) return mk_lerror(v, tag, ENAMETOOLONG, cap);
    u8 qt; u32 qv; u64 qp;
    if (qid_of(v, child, &qt, &qv, &qp)) return mk_lerror(v, tag, errno, cap);
    Cur o = resp_begin(v, P9_RMKDIR, tag, cap);
    p_qid(&o, qt, qv, qp);
    return resp_finish(&o, v, tag, cap);
}

static u32 h_mknod(VirtIO9P *v, Cur *in, u16 tag, u32 cap) {
    u32 dfid = c_u32(in);
    char name[P9_NAME_MAX]; c_str(in, name, sizeof(name));
    u32 mode = c_u32(in), major = c_u32(in), minor = c_u32(in); (void)c_u32(in);  /* gid */
    if (in->err) return mk_lerror(v, tag, EINVAL, cap);
    if (v->ro) return mk_lerror(v, tag, EROFS, cap);
    P9Fid *f = fid_find(v, dfid);
    if (!f) return mk_lerror(v, tag, EBADF, cap);
    if (!p9_elem_ok(name)) return mk_lerror(v, tag, EINVAL, cap);
    /* Device nodes and FIFOs are never created inside a share: they could
     * block a host slice or punch a hole in the containment model. */
    switch (mode & S_IFMT) {
        case 0: case S_IFREG: break;             /* regular file below */
        default: return mk_lerror(v, tag, EPERM, cap);
    }
    (void)major; (void)minor;
    int dfd = p9_open_dir_fd(v, f->path);
    if (dfd < 0) return mk_lerror(v, tag, errno, cap);
    int fd = openat(dfd, name, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, (mode_t)(mode & 07777));
    if (fd < 0) { int e = errno; close(dfd); return mk_lerror(v, tag, e, cap); }
    close(fd);
    close(dfd);
    char child[PATH_MAX];
    if (!p9_path_child(f->path, name, child, sizeof(child))) return mk_lerror(v, tag, ENAMETOOLONG, cap);
    u8 qt; u32 qv; u64 qp;
    if (qid_of(v, child, &qt, &qv, &qp)) return mk_lerror(v, tag, errno, cap);
    Cur o = resp_begin(v, P9_RMKNOD, tag, cap);
    p_qid(&o, qt, qv, qp);
    return resp_finish(&o, v, tag, cap);
}

static u32 h_symlink(VirtIO9P *v, Cur *in, u16 tag, u32 cap) {
    u32 dfid = c_u32(in);
    char name[P9_NAME_MAX], target[PATH_MAX];
    c_str(in, name, sizeof(name)); c_str(in, target, sizeof(target));
    (void)c_u32(in);                           /* gid */
    if (in->err) return mk_lerror(v, tag, EINVAL, cap);
    if (v->ro) return mk_lerror(v, tag, EROFS, cap);
    P9Fid *f = fid_find(v, dfid);
    if (!f) return mk_lerror(v, tag, EBADF, cap);
    if (!p9_elem_ok(name)) return mk_lerror(v, tag, EINVAL, cap);
    int dfd = p9_open_dir_fd(v, f->path);
    if (dfd < 0) return mk_lerror(v, tag, errno, cap);
    if (symlinkat(target, dfd, name)) { int e = errno; close(dfd); return mk_lerror(v, tag, e, cap); }
    close(dfd);
    char child[PATH_MAX];
    if (!p9_path_child(f->path, name, child, sizeof(child))) return mk_lerror(v, tag, ENAMETOOLONG, cap);
    u8 qt; u32 qv; u64 qp;
    if (qid_of(v, child, &qt, &qv, &qp)) return mk_lerror(v, tag, errno, cap);
    Cur o = resp_begin(v, P9_RSYMLINK, tag, cap);
    p_qid(&o, qt, qv, qp);
    return resp_finish(&o, v, tag, cap);
}

static u32 h_readlink(VirtIO9P *v, Cur *in, u16 tag, u32 cap) {
    u32 fid = c_u32(in);
    if (in->err) return mk_lerror(v, tag, EINVAL, cap);
    P9Fid *f = fid_find(v, fid);
    if (!f) return mk_lerror(v, tag, EBADF, cap);
    char buf[4096];
    ssize_t n = readlinkat(v->rootfd, f->path[0] ? f->path : ".", buf, sizeof(buf) - 1);
    if (n < 0) return mk_lerror(v, tag, errno, cap);
    buf[n] = '\0';
    Cur o = resp_begin(v, P9_RREADLINK, tag, cap);
    p_str(&o, buf);
    return resp_finish(&o, v, tag, cap);
}

static u32 h_link(VirtIO9P *v, Cur *in, u16 tag, u32 cap) {
    u32 dfid = c_u32(in), fid = c_u32(in);
    char name[P9_NAME_MAX]; c_str(in, name, sizeof(name));
    if (in->err) return mk_lerror(v, tag, EINVAL, cap);
    if (v->ro) return mk_lerror(v, tag, EROFS, cap);
    P9Fid *df = fid_find(v, dfid), *sf = fid_find(v, fid);
    if (!df || !sf) return mk_lerror(v, tag, EBADF, cap);
    if (!p9_elem_ok(name)) return mk_lerror(v, tag, EINVAL, cap);
    int dfd = p9_open_dir_fd(v, df->path);
    if (dfd < 0) return mk_lerror(v, tag, errno, cap);
    /* linkat follows the source's final symlink, exactly like link(2). */
    if (linkat(v->rootfd, sf->path[0] ? sf->path : ".", dfd, name, 0)) {
        int e = errno; close(dfd); return mk_lerror(v, tag, e, cap);
    }
    close(dfd);
    Cur o = resp_begin(v, P9_RLINK, tag, cap);
    return resp_finish(&o, v, tag, cap);
}

static u32 h_rename(VirtIO9P *v, Cur *in, u16 tag, u32 cap) {
    u32 fid = c_u32(in), dfid = c_u32(in);
    char name[P9_NAME_MAX]; c_str(in, name, sizeof(name));
    if (in->err) return mk_lerror(v, tag, EINVAL, cap);
    if (v->ro) return mk_lerror(v, tag, EROFS, cap);
    P9Fid *f = fid_find(v, fid), *df = fid_find(v, dfid);
    if (!f || !df) return mk_lerror(v, tag, EBADF, cap);
    if (!p9_elem_ok(name)) return mk_lerror(v, tag, EINVAL, cap);
    char child[PATH_MAX];
    if (!p9_path_child(df->path, name, child, sizeof(child))) return mk_lerror(v, tag, ENAMETOOLONG, cap);
    /* Contain both ends on the pinned root descriptor. */
    if (renameat(v->rootfd, f->path[0] ? f->path : ".",
                 v->rootfd, child[0] ? child : "."))
        return mk_lerror(v, tag, errno, cap);
    snprintf(f->path, sizeof(f->path), "%s", child);   /* fid follows the file */
    Cur o = resp_begin(v, P9_RRENAME, tag, cap);
    return resp_finish(&o, v, tag, cap);
}

static u32 h_renameat(VirtIO9P *v, Cur *in, u16 tag, u32 cap) {
    u32 od = c_u32(in);
    char oldn[P9_NAME_MAX]; c_str(in, oldn, sizeof(oldn));
    u32 nd = c_u32(in);
    char newn[P9_NAME_MAX]; c_str(in, newn, sizeof(newn));
    if (in->err) return mk_lerror(v, tag, EINVAL, cap);
    if (v->ro) return mk_lerror(v, tag, EROFS, cap);
    P9Fid *of = fid_find(v, od), *nf = fid_find(v, nd);
    if (!of || !nf) return mk_lerror(v, tag, EBADF, cap);
    if (!p9_elem_ok(oldn) || !p9_elem_ok(newn)) return mk_lerror(v, tag, EINVAL, cap);
    char op[PATH_MAX], np[PATH_MAX];
    if (!p9_path_child(of->path, oldn, op, sizeof(op))) return mk_lerror(v, tag, ENAMETOOLONG, cap);
    if (!p9_path_child(nf->path, newn, np, sizeof(np))) return mk_lerror(v, tag, ENAMETOOLONG, cap);
    if (renameat(v->rootfd, op[0] ? op : ".", v->rootfd, np[0] ? np : "."))
        return mk_lerror(v, tag, errno, cap);
    Cur o = resp_begin(v, P9_RRENAMEAT, tag, cap);
    return resp_finish(&o, v, tag, cap);
}

static u32 h_unlinkat(VirtIO9P *v, Cur *in, u16 tag, u32 cap) {
    u32 dfid = c_u32(in);
    char name[P9_NAME_MAX]; c_str(in, name, sizeof(name));
    u32 flags = c_u32(in);
    if (in->err) return mk_lerror(v, tag, EINVAL, cap);
    if (v->ro) return mk_lerror(v, tag, EROFS, cap);
    P9Fid *f = fid_find(v, dfid);
    if (!f) return mk_lerror(v, tag, EBADF, cap);
    if (!p9_elem_ok(name)) return mk_lerror(v, tag, EINVAL, cap);
    char child[PATH_MAX];
    if (!p9_path_child(f->path, name, child, sizeof(child))) return mk_lerror(v, tag, ENAMETOOLONG, cap);
    int r = unlinkat(v->rootfd, child[0] ? child : ".", flags & AT_REMOVEDIR ? AT_REMOVEDIR : 0);
    if (r) return mk_lerror(v, tag, errno, cap);
    Cur o = resp_begin(v, P9_RUNLINKAT, tag, cap);
    return resp_finish(&o, v, tag, cap);
}

static u32 h_remove(VirtIO9P *v, Cur *in, u16 tag, u32 cap) {
    u32 fid = c_u32(in);
    if (in->err) return mk_lerror(v, tag, EINVAL, cap);
    P9Fid *f = fid_find(v, fid);
    if (!f) return mk_lerror(v, tag, EBADF, cap);
    if (v->ro) { fid_del(v, fid); return mk_lerror(v, tag, EROFS, cap); }
    struct stat st;
    int flags = 0;
    if (p9_stat(v, f->path, &st) == 0 && S_ISDIR(st.st_mode)) flags = AT_REMOVEDIR;
    int r = unlinkat(v->rootfd, f->path[0] ? f->path : ".", flags);
    int e = errno;
    fid_del(v, fid);                           /* Tremove clunks the fid regardless */
    if (r) return mk_lerror(v, tag, e, cap);
    Cur o = resp_begin(v, P9_RREMOVE, tag, cap);
    return resp_finish(&o, v, tag, cap);
}

static u32 h_clunk(VirtIO9P *v, Cur *in, u16 tag, u32 cap) {
    u32 fid = c_u32(in);
    if (in->err) return mk_lerror(v, tag, EINVAL, cap);
    fid_del(v, fid);
    Cur o = resp_begin(v, P9_RCLUNK, tag, cap);
    return resp_finish(&o, v, tag, cap);
}

static u32 h_fsync(VirtIO9P *v, Cur *in, u16 tag, u32 cap) {
    u32 fid = c_u32(in), datasync = c_u32(in);
    if (in->err) return mk_lerror(v, tag, EINVAL, cap);
    P9Fid *f = fid_find(v, fid);
    if (!f) return mk_lerror(v, tag, EBADF, cap);
    if (f->fd >= 0) {
#if defined(__APPLE__)
        (void)datasync;
        int r = fsync(f->fd); /* Darwin has no fdatasync; full sync is stronger. */
#else
        int r = datasync ? fdatasync(f->fd) : fsync(f->fd);
#endif
        if (r) return mk_lerror(v, tag, errno, cap);
    }
    Cur o = resp_begin(v, P9_RFSYNC, tag, cap);
    return resp_finish(&o, v, tag, cap);
}

static u32 h_statfs(VirtIO9P *v, Cur *in, u16 tag, u32 cap) {
    u32 fid = c_u32(in);
    if (in->err) return mk_lerror(v, tag, EINVAL, cap);
    P9Fid *f = fid_find(v, fid);
    if (!f) return mk_lerror(v, tag, EBADF, cap);
    char abs[PATH_MAX];
    snprintf(abs, sizeof(abs), "%s%s%s", v->root, f->path[0] ? "/" : "", f->path);
    struct statvfs sv;
    if (statvfs(abs, &sv)) return mk_lerror(v, tag, errno, cap);
    u64 fsid = 0; memcpy(&fsid, &sv.f_fsid, sizeof(fsid) < sizeof(sv.f_fsid) ? sizeof(fsid) : sizeof(sv.f_fsid));
    Cur o = resp_begin(v, P9_RSTATFS, tag, cap);
    p_u32(&o, 0);                          /* no portable fs magic over 9P */
    p_u32(&o, (u32)(sv.f_frsize ? sv.f_frsize : sv.f_bsize));
    p_u64(&o, (u64)sv.f_blocks);
    p_u64(&o, (u64)sv.f_bfree);
    p_u64(&o, (u64)sv.f_bavail);
    p_u64(&o, (u64)sv.f_files);
    p_u64(&o, (u64)sv.f_ffree);
    p_u64(&o, fsid);
    p_u32(&o, (u32)sv.f_namemax);
    return resp_finish(&o, v, tag, cap);
}

static u32 h_flush(VirtIO9P *v, Cur *in, u16 tag, u32 cap) {
    (void)c_u16(in);                           /* oldtag: nothing is outstanding */
    Cur o = resp_begin(v, P9_RFLUSH, tag, cap);
    return resp_finish(&o, v, tag, cap);
}

/* xattr is not backed; report "unsupported" so getfattr/setfattr fail cleanly. */
static u32 h_xattr_unsup(VirtIO9P *v, Cur *in, u16 tag, u32 cap) {
    (void)in; return mk_lerror(v, tag, EOPNOTSUPP, cap);
}

/* POSIX locks: single client, serviced synchronously — grant everything and
 * report no conflicts. */
static u32 h_lock(VirtIO9P *v, Cur *in, u16 tag, u32 cap) {
    (void)in;
    Cur o = resp_begin(v, P9_RLOCK, tag, cap);
    p_u8(&o, 0);                               /* P9_LOCK_SUCCESS */
    return resp_finish(&o, v, tag, cap);
}
static u32 h_getlock(VirtIO9P *v, Cur *in, u16 tag, u32 cap) {
    (void)c_u32(in); (void)c_u8(in);
    u64 start = c_u64(in), length = c_u64(in); u32 pid = c_u32(in);
    char cid[128]; c_str(in, cid, sizeof(cid));
    Cur o = resp_begin(v, P9_RGETLOCK, tag, cap);
    p_u8(&o, 2);                               /* F_UNLCK: no conflicting lock */
    p_u64(&o, start); p_u64(&o, length); p_u32(&o, pid); p_str(&o, cid);
    return resp_finish(&o, v, tag, cap);
}

/* ============================ dispatch ============================ */

static u32 p9_dispatch(VirtIO9P *v, u32 reqlen, u32 wcap) {
    u32 cap = wcap < P9_MSIZE_MAX ? wcap : P9_MSIZE_MAX;
    Cur in = { v->req, reqlen, 0, false };
    (void)c_u32(&in);                          /* size (use reqlen) */
    u8  type = c_u8(&in);
    u16 tag  = c_u16(&in);
    /* Truncated header: reply Rlerror instead of a zero-length message, which
     * would complete the descriptor with no R-message and hang the tag forever. */
    if (in.err) return mk_lerror(v, tag, EINVAL, cap);

    switch (type) {
        case P9_TVERSION:     return h_version(v, &in, tag, cap);
        case P9_TATTACH:      return h_attach(v, &in, tag, cap);
        case P9_TWALK:        return h_walk(v, &in, tag, cap);
        case P9_TGETATTR:     return h_getattr(v, &in, tag, cap);
        case P9_TSETATTR:     return h_setattr(v, &in, tag, cap);
        case P9_TREADDIR:     return h_readdir(v, &in, tag, cap);
        case P9_TLOPEN:       return h_lopen(v, &in, tag, cap);
        case P9_TLCREATE:     return h_lcreate(v, &in, tag, cap);
        case P9_TREAD:        return h_read(v, &in, tag, cap);
        case P9_TWRITE:       return h_write(v, &in, tag, cap);
        case P9_TMKDIR:       return h_mkdir(v, &in, tag, cap);
        case P9_TMKNOD:       return h_mknod(v, &in, tag, cap);
        case P9_TSYMLINK:     return h_symlink(v, &in, tag, cap);
        case P9_TREADLINK:    return h_readlink(v, &in, tag, cap);
        case P9_TLINK:        return h_link(v, &in, tag, cap);
        case P9_TRENAME:      return h_rename(v, &in, tag, cap);
        case P9_TRENAMEAT:    return h_renameat(v, &in, tag, cap);
        case P9_TUNLINKAT:    return h_unlinkat(v, &in, tag, cap);
        case P9_TREMOVE:      return h_remove(v, &in, tag, cap);
        case P9_TCLUNK:       return h_clunk(v, &in, tag, cap);
        case P9_TFSYNC:       return h_fsync(v, &in, tag, cap);
        case P9_TSTATFS:      return h_statfs(v, &in, tag, cap);
        case P9_TFLUSH:       return h_flush(v, &in, tag, cap);
        case P9_TXATTRWALK:
        case P9_TXATTRCREATE: return h_xattr_unsup(v, &in, tag, cap);
        case P9_TLOCK:        return h_lock(v, &in, tag, cap);
        case P9_TGETLOCK:     return h_getlock(v, &in, tag, cap);
        default:              return mk_lerror(v, tag, EOPNOTSUPP, cap);
    }
}

/* ============================ virtqueue ============================ */

/* The queue rings must live in guest RAM (same contract as virtio-blk). */
static bool fs_queue_spans(VirtIO9P *v) {
    return v->q_num && v->q_num <= VIRTQ_MAX &&
        ram_ptr(v->m, v->q_desc, (u64)v->q_num * 16) &&
        ram_ptr(v->m, v->q_avail, 6 + (u64)v->q_num * 2) &&
        ram_ptr(v->m, v->q_used, 6 + (u64)v->q_num * 8);
}

static void push_used(VirtIO9P *v, u32 id, u32 len) {
    Machine *m = v->m;
    u16 used_idx = (u16)phys_read(m, v->q_used + 2, 2);
    u64 e = v->q_used + 4 + (u64)(used_idx % v->q_num) * 8;
    phys_write(m, e + 0, 4, id);
    phys_write(m, e + 4, 4, len);
    phys_write(m, v->q_used + 2, 2, (u16)(used_idx + 1));
}

/* Service one request head: gather readable descriptors into the T-message
 * buffer, dispatch, then scatter the R-message across the writable descriptors. */
static void p9_handle(VirtIO9P *v, u32 head) {
    Machine *m = v->m;
    u64 raddr[VIRTQ_MAX]; u32 rlen[VIRTQ_MAX]; u32 n_r = 0;
    u64 waddr[VIRTQ_MAX]; u32 wlen[VIRTQ_MAX]; u32 n_w = 0;

    u32 idx = head, n = 0;
    for (;;) {
        if (n >= v->q_num || n >= VIRTQ_MAX) break;
        u64 d  = v->q_desc + (u64)idx * 16;
        u64 a  = phys_read(m, d + 0, 8);
        u32 l  = (u32)phys_read(m, d + 8, 4);
        u16 fl = (u16)phys_read(m, d + 12, 2);
        u16 nx = (u16)phys_read(m, d + 14, 2);
        if (machine_bus_status(m) != BUS_OK) { v->status |= 64; return; }
        if (fl & VIRTQ_DESC_F_WRITE) { if (n_w < VIRTQ_MAX) { waddr[n_w] = a; wlen[n_w] = l; n_w++; } }
        else                        { if (n_r < VIRTQ_MAX) { raddr[n_r] = a; rlen[n_r] = l; n_r++; } }
        n++;
        if (!(fl & VIRTQ_DESC_F_NEXT)) break;
        idx = nx;
    }

    u32 reqlen = 0;
    for (u32 i = 0; i < n_r && reqlen < P9_MSIZE_MAX; i++) {
        u32 take = rlen[i];
        if (reqlen + take > P9_MSIZE_MAX) take = P9_MSIZE_MAX - reqlen;
        phys_read_blk(m, raddr[i], v->req + reqlen, take);
        if (machine_bus_status(m) != BUS_OK) { v->status |= 64; return; }
        reqlen += take;
    }
    u32 wcap = 0; for (u32 i = 0; i < n_w; i++) wcap += wlen[i];

    u32 resplen = p9_dispatch(v, reqlen, wcap);

    u32 off = 0;
    for (u32 i = 0; i < n_w && off < resplen; i++) {
        u32 chunk = wlen[i];
        if (off + chunk > resplen) chunk = resplen - off;
        phys_write_blk(m, waddr[i], v->resp + off, chunk);
        if (machine_bus_status(m) != BUS_OK) { v->status |= 64; return; }
        off += chunk;
    }
    push_used(v, head, resplen);
}

static void virtio_9p_process(VirtIO9P *v) {
    Machine *m = v->m;
    if (!v->q_ready || v->q_num == 0) return;
    if (!fs_queue_spans(v)) { v->status |= 64; return; }
    u16 avail_idx = (u16)phys_read(m, v->q_avail + 2, 2);
    if (machine_bus_status(m) != BUS_OK) { v->status |= 64; return; }
    bool did = false;
    while (v->last_avail != avail_idx) {
        u16 hd = (u16)phys_read(m, v->q_avail + 4 + (u64)(v->last_avail % v->q_num) * 2, 2);
        if (machine_bus_status(m) != BUS_OK) { v->status |= 64; return; }
        p9_handle(v, hd);
        v->last_avail++;
        did = true;
    }
    if (did) {
        v->isr |= 1;
        gic_set_irq(v->gic, v->irq, 1);
    }
}

/* ============================ MMIO ============================ */

static void fs_reset(VirtIO9P *v) {
    v->status = 0; v->isr = 0;
    v->dev_feat_sel = v->drv_feat_sel = 0; v->drv_feat = 0;
    v->queue_sel = 0;
    v->q_num = 0; v->q_ready = 0;
    v->q_desc = v->q_avail = v->q_used = 0;
    v->last_avail = 0;
    v->msize = P9_MSIZE_MAX;
    fids_clear(v);
    gic_set_irq(v->gic, v->irq, 0);
}

/* struct virtio_9p_config { u16 tag_len; u8 tag[]; } */
static u64 fs_config_read(VirtIO9P *v, u64 off, unsigned size) {
    u8 cfg[2 + TAG_MAX];
    memset(cfg, 0, sizeof(cfg));
    cfg[0] = (u8)v->tag_len;
    cfg[1] = (u8)(v->tag_len >> 8);
    memcpy(cfg + 2, v->tag, v->tag_len);
    u64 r = 0;
    for (unsigned i = 0; i < size && off + i < sizeof(cfg); i++)
        r |= (u64)cfg[off + i] << (i * 8);
    return r;
}

static u64 fs_read(void *opaque, u64 off, unsigned size) {
    VirtIO9P *v = opaque;
    if (off >= 0x100) return fs_config_read(v, off - 0x100, size);
    switch (off) {
        case 0x000: return 0x74726976;               /* MagicValue "virt" */
        case 0x004: return 2;                        /* Version (modern)  */
        case 0x008: return 9;                        /* DeviceID = 9p     */
        case 0x00c: return 0x554d4551;               /* VendorID "QEMU"   */
        case 0x010:                                  /* DeviceFeatures    */
            return v->dev_feat_sel == 1 ? (u32)(FS_FEATURES >> 32)
                                        : (u32)(FS_FEATURES & 0xffffffff);
        case 0x034: return v->queue_sel == 0 ? QUEUE_NUM_MAX : 0;  /* QueueNumMax */
        case 0x044: return v->q_ready;               /* QueueReady        */
        case 0x060: return v->isr;                   /* InterruptStatus   */
        case 0x070: return v->status;                /* Status            */
        case 0x0fc: return 0;                        /* ConfigGeneration  */
        default:    return 0;
    }
}

static void fs_write(void *opaque, u64 off, unsigned size, u64 val) {
    VirtIO9P *v = opaque;
    u32 v32 = (u32)val;
    switch (off) {
        case 0x014: v->dev_feat_sel = v32; break;                   /* DeviceFeaturesSel */
        case 0x020:                                                 /* DriverFeatures    */
            if (v->drv_feat_sel == 1) v->drv_feat = (v->drv_feat & 0xffffffffULL) | ((u64)v32 << 32);
            else                      v->drv_feat = (v->drv_feat & ~0xffffffffULL) | v32;
            break;
        case 0x024: v->drv_feat_sel = v32; break;                   /* DriverFeaturesSel */
        case 0x030: v->queue_sel = v32; break;                      /* QueueSel          */
        case 0x038:                                                 /* QueueNum          */
            v->q_num = v32 > QUEUE_NUM_MAX ? QUEUE_NUM_MAX : v32;
            break;
        case 0x044: v->q_ready = v32; break;                        /* QueueReady        */
        case 0x050: if (v32 == 0) virtio_9p_process(v); break;      /* QueueNotify       */
        case 0x064:                                                 /* InterruptACK      */
            v->isr &= ~v32;
            if (v->isr == 0) gic_set_irq(v->gic, v->irq, 0);
            break;
        case 0x070:                                                 /* Status            */
            if (v32 == 0) fs_reset(v); else v->status = v32;
            break;
        case 0x080: v->q_desc  = (v->q_desc  & ~0xffffffffULL) | v32;             break;
        case 0x084: v->q_desc  = (v->q_desc  &  0xffffffffULL) | ((u64)v32 << 32); break;
        case 0x090: v->q_avail = (v->q_avail & ~0xffffffffULL) | v32;             break;
        case 0x094: v->q_avail = (v->q_avail &  0xffffffffULL) | ((u64)v32 << 32); break;
        case 0x0a0: v->q_used  = (v->q_used  & ~0xffffffffULL) | v32;             break;
        case 0x0a4: v->q_used  = (v->q_used  &  0xffffffffULL) | ((u64)v32 << 32); break;
        default: break;
    }
}

/* ============================ creation ============================ */

struct VirtIO9P *virtio_9p_create(Machine *m, GIC *gic, const char *root,
                                  const char *tag, bool ro, int slot) {
    /* Resolve the host directory ONCE at registration; from then on the
     * pinned root descriptor is the only handle the host sees. */
    char real[PATH_MAX];
    if (!realpath(root, real)) {
        fprintf(stderr, "[virtio-9p] cannot resolve %s: %s\n", root, strerror(errno));
        return NULL;
    }
    struct stat st;
    if (stat(real, &st) != 0 || !S_ISDIR(st.st_mode)) {
        fprintf(stderr, "[virtio-9p] %s is not a directory\n", root);
        return NULL;
    }
    int rootfd = open(real, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (rootfd < 0) {
        fprintf(stderr, "[virtio-9p] cannot pin %s: %s\n", real, strerror(errno));
        return NULL;
    }

    VirtIO9P *v = calloc(1, sizeof(*v));
    if (!v) { close(rootfd); return NULL; }
    v->rootfd = rootfd;
    v->m = m; v->gic = gic; v->irq = INTID_VIRTIO0 + slot; v->ro = ro;
    snprintf(v->root, sizeof(v->root), "%s", real);
    v->rootlen = strlen(v->root);
    size_t tl = strlen(tag); if (tl > TAG_MAX) tl = TAG_MAX;
    memcpy(v->tag, tag, tl); v->tag_len = (u16)tl;
    v->msize = P9_MSIZE_MAX;
    v->req  = malloc(P9_MSIZE_MAX);
    v->resp = malloc(P9_MSIZE_MAX);
    if (!v->req || !v->resp) {
        fprintf(stderr, "[virtio-9p] out of memory\n");
        close(v->rootfd);
        free(v->req); free(v->resp); free(v);
        return NULL;
    }

    u64 base = 0x0a000000ULL + (u64)slot * 0x200;
    machine_add_device(m, base, 0x200, fs_read, fs_write, v, "virtio-9p");
    m->fs[m->n_fs++] = v;
    fprintf(stderr, "[virtio-9p] slot %d: tag \"%s\" -> %s%s\n",
            slot, tag, v->root, ro ? " (ro)" : "");
    return v;
}

/* Full teardown after the machine is quiet: open fid handles, the gather /
 * scatter buffers, and the pinned root descriptor. */
void virtio_9p_destroy(VirtIO9P *v) {
    if (!v) return;
    fids_clear(v);
    if (v->rootfd >= 0) close(v->rootfd);
    v->rootfd = -1;
    free(v->req); v->req = NULL;
    free(v->resp); v->resp = NULL;
    free(v);
}
