/*
 * Filesystem on disk
 * 
 * Copyright (c) 2016 Fabrice Bellard
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
 * THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR
 * OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
 * ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
 * OTHER DEALINGS IN THE SOFTWARE.
 */
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <inttypes.h>
#include <assert.h>
#include <stdarg.h>
#include <sys/statfs.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <unistd.h>
#include <fcntl.h>
#include <dirent.h>
#include <errno.h>

#include "cutils.h"
#include "list.h"
#include "fs.h"

/* FLOE-EMBED: Apple SDKs (macOS/iOS) spell the stat timestamp members
 * st_atimespec/st_mtimespec/st_ctimespec. The Makefile qualification build
 * injects this mapping with -include on macOS; the SwiftPM C target cannot
 * force-include, so the vendored copy carries the mapping. */
#ifdef __APPLE__
#define st_atim st_atimespec
#define st_mtim st_mtimespec
#define st_ctim st_ctimespec
#endif

/* FLOE-EMBED (patch 0007): export-root containment is enforced on file
 * descriptors, not on path strings. The share pins its root directory on
 * root_fd (O_DIRECTORY|O_NOFOLLOW); every fid below it is either
 *  - a directory fid: dir_fd is an fd to that directory, name == NULL, or
 *  - a file/symlink fid: dir_fd is an fd to the containing directory and
 *    name is one single component inside it.
 * All guest-visible operations use *at() syscalls on those fds, so "..",
 * absolute paths, symlinks (absolute, relative or guest-created) and
 * renames can never name anything outside the export root. The path
 * strings kept in FSFile are diagnostics/readdir decoration only and are
 * never passed to a syscall that grants authority.
 */

typedef struct {
    FSDevice common;
    char *root_path;   /* diagnostics only */
    int root_fd;       /* pinned export root for the share lifetime */
} FSDeviceDisk;

static void fs_close(FSDevice *fs, FSFile *f);

struct FSFile {
    uint32_t uid;
    char *path; /* diagnostic path (root + walked components); no authority */
    int dir_fd; /* contained directory fd (see above); -1 if not opened */
    char *name; /* single component inside dir_fd, or NULL for a dir fid */
    BOOL is_opened;
    BOOL is_dir;
    union {
        int fd;
        DIR *dirp;
    } u;
};

/* a 9p name must be one non-empty component; ".." is always refused */
static BOOL fs_valid_name(const char *name)
{
    if (!name || name[0] == '\0')
        return FALSE;
    if (strchr(name, '/'))
        return FALSE;
    if (!strcmp(name, ".."))
        return FALSE;
    return TRUE;
}

static void fs_delete(FSDevice *fs, FSFile *f)
{
    if (f->is_opened)
        fs_close(fs, f);
    if (f->dir_fd >= 0)
        close(f->dir_fd);
    free(f->name);
    free(f->path);
    free(f);
}

/* warning: path belong to fid_create() */
static FSFile *fid_create(FSDevice *s1, char *path, uint32_t uid)
{
    FSFile *f;
    (void)s1;
    f = mallocz(sizeof(*f));
    if (!f) {
        free(path);
        return NULL;
    }
    f->path = path;
    f->uid = uid;
    f->dir_fd = -1;
    f->name = NULL;
    return f;
}

/* stat the fid itself; the final component is never followed, so a symlink
   fid reports the link (S_ISLNK) like upstream lstat() did */
static int fs_fid_stat(FSFile *f, struct stat *st)
{
    if (f->dir_fd < 0)
        return -1;
    return fstatat(f->dir_fd, f->name ? f->name : ".", st,
                   AT_SYMLINK_NOFOLLOW);
}

/* fd of the directory a fid refers to (for fs_mkdir/fs_create/...), or -1.
   The caller owns the returned fd. A file fid yields ENOTDIR. */
static int fs_fid_dirfd(FSFile *f)
{
    if (f->dir_fd < 0)
        return -1;
    if (f->name == NULL)
        return dup(f->dir_fd);
    return openat(f->dir_fd, f->name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
}

static int errno_table[][2] = {
    { P9_EPERM, EPERM },
    { P9_ENOENT, ENOENT },
    { P9_EIO, EIO },
    { P9_EEXIST, EEXIST },
    { P9_EINVAL, EINVAL },
    { P9_ENOSPC, ENOSPC },
    { P9_ENOTEMPTY, ENOTEMPTY },
    { P9_EPROTO, EPROTO },
    { P9_ENOTSUP, ENOTSUP },
};

static int errno_to_p9(int err)
{
    int i;
    if (err == 0)
        return 0;
    for(i = 0; i < countof(errno_table); i++) {
        if (err == errno_table[i][1])
            return errno_table[i][0];
    }
    return P9_EINVAL;
}

static int open_flags[][2] = {
    { P9_O_CREAT, O_CREAT },
    { P9_O_EXCL, O_EXCL },
    //    { P9_O_NOCTTY, O_NOCTTY },
    { P9_O_TRUNC, O_TRUNC },
    { P9_O_APPEND, O_APPEND },
    { P9_O_NONBLOCK, O_NONBLOCK },
    { P9_O_DSYNC, O_DSYNC },
    //    { P9_O_FASYNC, O_FASYNC },
    //    { P9_O_DIRECT, O_DIRECT },
    //    { P9_O_LARGEFILE, O_LARGEFILE },
    //    { P9_O_DIRECTORY, O_DIRECTORY },
    { P9_O_NOFOLLOW, O_NOFOLLOW },
    //    { P9_O_NOATIME, O_NOATIME },
    //    { P9_O_CLOEXEC, O_CLOEXEC },
    { P9_O_SYNC, O_SYNC },
};

static int p9_flags_to_host(int flags)
{
    int ret, i;

    ret = (flags & P9_O_NOACCESS);
    for(i = 0; i < countof(open_flags); i++) {
        if (flags & open_flags[i][0])
            ret |= open_flags[i][1];
    }
    return ret;
}

static void stat_to_qid(FSQID *qid, const struct stat *st)
{
    if (S_ISDIR(st->st_mode))
        qid->type = P9_QTDIR;
    else if (S_ISLNK(st->st_mode))
        qid->type = P9_QTSYMLINK;
    else
        qid->type = P9_QTFILE;
    qid->version = 0; /* no caching on client */
    qid->path = st->st_ino;
}

static void fs_statfs(FSDevice *fs1, FSStatFS *st)
{
    FSDeviceDisk *fs = (FSDeviceDisk *)fs1;
    struct statfs st1;
    if (fstatfs(fs->root_fd, &st1) != 0)
        return;
    st->f_bsize = st1.f_bsize;
    st->f_blocks = st1.f_blocks;
    st->f_bfree = st1.f_bfree;
    st->f_bavail = st1.f_bavail;
    st->f_files = st1.f_files;
    st->f_ffree = st1.f_ffree;
}

static char *compose_path(const char *path, const char *name)
{
    int path_len, name_len;
    char *d;

    path_len = strlen(path);
    name_len = strlen(name);
    d = malloc(path_len + 1 + name_len + 1);
    if (!d)
        return NULL;
    memcpy(d, path, path_len);
    d[path_len] = '/';
    memcpy(d + path_len + 1, name, name_len + 1);
    return d;
}

static int fs_attach(FSDevice *fs1, FSFile **pf,
                     FSQID *qid, uint32_t uid,
                     const char *uname, const char *aname)
{
    FSDeviceDisk *fs = (FSDeviceDisk *)fs1;
    struct stat st;
    FSFile *f;
    (void)uname; (void)aname;

    if (fstat(fs->root_fd, &st) != 0) {
        *pf = NULL;
        return -errno_to_p9(errno);
    }
    f = fid_create(fs1, strdup(fs->root_path), uid);
    if (!f) {
        *pf = NULL;
        return -P9_EIO;
    }
    f->dir_fd = dup(fs->root_fd); /* the root fid is contained by construction */
    if (f->dir_fd < 0) {
        int e = errno;
        fs_delete(fs1, f);
        *pf = NULL;
        return -errno_to_p9(e);
    }
    stat_to_qid(qid, &st);
    *pf = f;
    return 0;
}

static int fs_walk(FSDevice *fs, FSFile **pf, FSQID *qids,
                   FSFile *f, int n, char **names)
{
    char *path;
    char *name;
    struct stat st;
    int i, cur, nfd;

    *pf = NULL;
    if (f->dir_fd < 0)
        return -P9_EIO;
    path = strdup(f->path);
    name = f->name ? strdup(f->name) : NULL;
    cur = dup(f->dir_fd);
    if (!path || !cur) {
        free(path);
        free(name);
        if (cur >= 0)
            close(cur);
        return -P9_EIO;
    }
    /* a file/symlink fid has no children: upstream stopped at ENOTDIR, and
       a symlink must never be traversed as if it were a directory */
    if (f->name != NULL)
        n = 0;
    for(i = 0; i < n; i++) {
        char *path1, *name1;
        if (!fs_valid_name(names[i]))
            break;
        if (fstatat(cur, names[i], &st, AT_SYMLINK_NOFOLLOW) != 0)
            break;
        nfd = -1;
        if (S_ISDIR(st.st_mode)) {
            nfd = openat(cur, names[i], O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
            if (nfd < 0)
                break;
        }
        path1 = compose_path(path, names[i]);
        name1 = strdup(names[i]);
        if (!path1 || !name1) {
            free(path1);
            free(name1);
            if (nfd >= 0)
                close(nfd);
            break;
        }
        free(path);
        path = path1;
        free(name);
        name = name1;
        if (nfd >= 0) {
            /* the new fid owns the directory fd itself */
            close(cur);
            cur = nfd;
            free(name);
            name = NULL;
        }
        stat_to_qid(&qids[i], &st);
    }
    *pf = fid_create(fs, path, f->uid);
    if (!*pf) {
        free(name);
        close(cur);
        return -P9_EIO;
    }
    (*pf)->dir_fd = cur;
    (*pf)->name = name;
    return i;
}


static int fs_mkdir(FSDevice *fs, FSQID *qid, FSFile *f,
                    const char *name, uint32_t mode, uint32_t gid)
{
    struct stat st;
    int dfd, ret;
    (void)fs; (void)gid;

    if (!fs_valid_name(name))
        return -P9_EPERM;
    dfd = fs_fid_dirfd(f);
    if (dfd < 0)
        return -errno_to_p9(errno);
    if (mkdirat(dfd, name, mode) < 0) {
        ret = -errno_to_p9(errno);
    } else if (fstatat(dfd, name, &st, AT_SYMLINK_NOFOLLOW) != 0) {
        ret = -errno_to_p9(errno);
    } else {
        ret = 0;
    }
    close(dfd);
    if (ret)
        return ret;
    stat_to_qid(qid, &st);
    return 0;
}

static int fs_open(FSDevice *fs, FSQID *qid, FSFile *f, uint32_t flags,
                   FSOpenCompletionFunc *cb, void *opaque)
{
    struct stat st;
    (void)cb; (void)opaque;

    fs_close(fs, f);

    if (fs_fid_stat(f, &st) != 0)
        return -errno_to_p9(errno);
    /* FLOE-EMBED (patch 0007): export regular files, directories and
       symlink metadata only. A host FIFO or device node under the share
       must never be opened from the run thread: open() on a FIFO blocks
       until a peer appears, which would freeze the VM slice with no way
       for command cancellation to interrupt it. Such fids are reported as
       EOPNOTSUPP (truthful: this backend does not provide them). */
    if (!S_ISREG(st.st_mode) && !S_ISDIR(st.st_mode) && !S_ISLNK(st.st_mode))
        return -P9_ENOTSUP;
    stat_to_qid(qid, &st);

    if (flags & P9_O_DIRECTORY) {
        DIR *dirp;
        int dfd = fs_fid_dirfd(f);
        if (dfd < 0)
            return -errno_to_p9(errno);
        dirp = fdopendir(dfd);
        if (!dirp) {
            int e = errno;
            close(dfd);
            return -errno_to_p9(e);
        }
        f->is_opened = TRUE;
        f->is_dir = TRUE;
        f->u.dirp = dirp;
    } else {
        int fd;
        /* FLOE-EMBED: O_NOFOLLOW on every open, so a symlink (guest-made,
           or swapped in by a host rename race) can never redirect this
           open outside the already-contained parent directory. */
        fd = openat(f->dir_fd, f->name ? f->name : ".",
                    (p9_flags_to_host(flags) & ~O_CREAT) | O_NOFOLLOW);
        if (fd < 0)
            return -errno_to_p9(errno);
        f->is_opened = TRUE;
        f->is_dir = FALSE;
        f->u.fd = fd;
    }
    return 0;
}

static int fs_create(FSDevice *fs, FSQID *qid, FSFile *f, const char *name, 
                     uint32_t flags, uint32_t mode, uint32_t gid)
{
    struct stat st;
    char *path, *name1;
    int fd, dfd, e;
    (void)fs; (void)gid;

    if (!fs_valid_name(name))
        return -P9_EPERM;

    fs_close(fs, f);

    dfd = fs_fid_dirfd(f);
    if (dfd < 0)
        return -errno_to_p9(errno);

    path = compose_path(f->path, name);
    name1 = strdup(name);
    if (!path || !name1) {
        free(path);
        free(name1);
        close(dfd);
        return -P9_EIO;
    }

    /* FLOE-EMBED (patch 0007): creating/truncating over an existing FIFO
       or device node would open it, which can block forever (see
       fs_open). Refuse before the openat. */
    if (fstatat(dfd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 &&
        !S_ISREG(st.st_mode) && !S_ISDIR(st.st_mode) && !S_ISLNK(st.st_mode)) {
        free(path);
        free(name1);
        close(dfd);
        return -P9_ENOTSUP;
    }

    /* FLOE-EMBED: create below the contained dirfd with O_NOFOLLOW, so an
       existing symlink at `name` is an error (ELOOP) instead of a way to
       follow it and truncate an outside file (upstream open() followed). */
    fd = openat(dfd, name, p9_flags_to_host(flags) | O_CREAT | O_NOFOLLOW,
                mode);
    if (fd < 0) {
        e = errno;
        free(path);
        free(name1);
        close(dfd);
        return -errno_to_p9(e);
    }
    if (fstat(fd, &st) != 0) {
        e = errno;
        close(fd);
        free(path);
        free(name1);
        close(dfd);
        return -errno_to_p9(e);
    }
    /* the fid now denotes the created file, still inside dfd */
    if (f->dir_fd >= 0)
        close(f->dir_fd);
    free(f->name);
    free(f->path);
    f->path = path;
    f->name = name1;
    f->dir_fd = dfd;
    f->is_opened = TRUE;
    f->is_dir = FALSE;
    f->u.fd = fd;
    stat_to_qid(qid, &st);
    return 0;
}

static int fs_readdir(FSDevice *fs, FSFile *f, uint64_t offset,
                      uint8_t *buf, int count)
{
    struct dirent *de;
    int len, pos, name_len, type, d_type;
    (void)fs;

    if (!f->is_opened || !f->is_dir)
        return -P9_EPROTO;
    if (offset == 0)
        rewinddir(f->u.dirp);
    else
        seekdir(f->u.dirp, offset);
    pos = 0;
    for(;;) {
        de = readdir(f->u.dirp);
        if (de == NULL)
            break;
        name_len = strlen(de->d_name);
        len = 13 + 8 + 1 + 2 + name_len;
        if ((pos + len) > count)
            break;
        offset = telldir(f->u.dirp);
        d_type = de->d_type;
        if (d_type == DT_UNKNOWN) {
            /* FLOE-EMBED: resolve unknown types through the opened
               directory fd, never through a path string */
            struct stat st;
            if (fstatat(dirfd(f->u.dirp), de->d_name, &st,
                        AT_SYMLINK_NOFOLLOW) == 0) {
                d_type = st.st_mode >> 12;
            } else {
                d_type = DT_REG; /* default */
            }
        }
        if (d_type == DT_DIR)
            type = P9_QTDIR;
        else if (d_type == DT_LNK)
            type = P9_QTSYMLINK;
        else
            type = P9_QTFILE;
        buf[pos++] = type;
        put_le32(buf + pos, 0); /* version */
        pos += 4;
        put_le64(buf + pos, de->d_ino);
        pos += 8;
        put_le64(buf + pos, offset);
        pos += 8;
        buf[pos++] = d_type;
        put_le16(buf + pos, name_len);
        pos += 2;
        memcpy(buf + pos, de->d_name, name_len);
        pos += name_len;
    }
    return pos;
}

static int fs_read(FSDevice *fs, FSFile *f, uint64_t offset,
                   uint8_t *buf, int count)
{
    int ret;
    (void)fs;

    if (!f->is_opened || f->is_dir)
        return -P9_EPROTO;
    ret = pread(f->u.fd, buf, count, offset);
    if (ret < 0) 
        return -errno_to_p9(errno);
    else
        return ret;
}

static int fs_write(FSDevice *fs, FSFile *f, uint64_t offset,
                    const uint8_t *buf, int count)
{
    int ret;
    (void)fs;

    if (!f->is_opened || f->is_dir)
        return -P9_EPROTO;
    ret = pwrite(f->u.fd, buf, count, offset);
    if (ret < 0) 
        return -errno_to_p9(errno);
    else
        return ret;
}

static void fs_close(FSDevice *fs, FSFile *f)
{
    (void)fs;
    if (!f->is_opened)
        return;
    if (f->is_dir)
        closedir(f->u.dirp);
    else
        close(f->u.fd);
    f->is_opened = FALSE;
}

static int fs_stat(FSDevice *fs, FSFile *f, FSStat *st)
{
    struct stat st1;
    (void)fs;

    /* FLOE-EMBED: no path lookup; the fid's contained fd decides */
    if (fs_fid_stat(f, &st1) != 0)
        return -P9_ENOENT;
    stat_to_qid(&st->qid, &st1);
    st->st_mode = st1.st_mode;
    st->st_uid = st1.st_uid;
    st->st_gid = st1.st_gid;
    st->st_nlink = st1.st_nlink;
    st->st_rdev = st1.st_rdev;
    st->st_size = st1.st_size;
    st->st_blksize = st1.st_blksize;
    st->st_blocks = st1.st_blocks;
    st->st_atime_sec = st1.st_atim.tv_sec;
    st->st_atime_nsec = st1.st_atim.tv_nsec;
    st->st_mtime_sec = st1.st_mtim.tv_sec;
    st->st_mtime_nsec = st1.st_mtim.tv_nsec;
    st->st_ctime_sec = st1.st_ctim.tv_sec;
    st->st_ctime_nsec = st1.st_ctim.tv_nsec;
    return 0;
}

static int fs_setattr(FSDevice *fs, FSFile *f, uint32_t mask,
                      uint32_t mode, uint32_t uid, uint32_t gid,
                      uint64_t size, uint64_t atime_sec, uint64_t atime_nsec,
                      uint64_t mtime_sec, uint64_t mtime_nsec)
{
    const char *name = f->name ? f->name : ".";
    BOOL ctime_updated = FALSE;
    struct stat st;
    (void)fs;

    /* FLOE-EMBED: all setattr variants act on the contained fid. chmod and
       truncate refuse symlink fids: following them would modify an outside
       inode, and Linux has no lchmod/truncate-no-follow. chown/utimes use
       AT_SYMLINK_NOFOLLOW and are safe on links. */
    if (mask & (P9_SETATTR_MODE | P9_SETATTR_SIZE)) {
        if (fs_fid_stat(f, &st) != 0)
            return -errno_to_p9(errno);
    }
    if ((mask & (P9_SETATTR_UID | P9_SETATTR_GID))) {
        if (fchownat(f->dir_fd, name, (mask & P9_SETATTR_UID) ? uid : -1,
                     (mask & P9_SETATTR_GID) ? gid : -1,
                     AT_SYMLINK_NOFOLLOW) < 0)
            return -errno_to_p9(errno);
        ctime_updated = TRUE;
    }
    /* must be done after uid change for suid */
    if (mask & P9_SETATTR_MODE) {
        if (S_ISLNK(st.st_mode))
            return -P9_ENOTSUP;
        if (fchmodat(f->dir_fd, name, mode, 0) < 0)
            return -errno_to_p9(errno);
        ctime_updated = TRUE;
    }
    if (mask & P9_SETATTR_SIZE) {
        int fd;
        if (!S_ISREG(st.st_mode))
            return -P9_ENOTSUP; /* never open a FIFO/device to truncate it */
        fd = openat(f->dir_fd, name, O_WRONLY | O_NOFOLLOW);
        if (fd < 0)
            return -errno_to_p9(errno);
        if (ftruncate(fd, size) < 0) {
            int e = errno;
            close(fd);
            return -errno_to_p9(e);
        }
        close(fd);
        ctime_updated = TRUE;
    }
    if (mask & (P9_SETATTR_ATIME | P9_SETATTR_MTIME)) {
        struct timespec ts[2];
        if (mask & P9_SETATTR_ATIME) {
            if (mask & P9_SETATTR_ATIME_SET) {
                ts[0].tv_sec = atime_sec;
                ts[0].tv_nsec = atime_nsec;
            } else {
                ts[0].tv_sec = 0;
                ts[0].tv_nsec = UTIME_NOW;
            }
        } else {
            ts[0].tv_sec = 0;
            ts[0].tv_nsec = UTIME_OMIT;
        }
        if (mask & P9_SETATTR_MTIME) {
            if (mask & P9_SETATTR_MTIME_SET) {
                ts[1].tv_sec = mtime_sec;
                ts[1].tv_nsec = mtime_nsec;
            } else {
                ts[1].tv_sec = 0;
                ts[1].tv_nsec = UTIME_NOW;
            }
        } else {
            ts[1].tv_sec = 0;
            ts[1].tv_nsec = UTIME_OMIT;
        }
        if (utimensat(f->dir_fd, name, ts, AT_SYMLINK_NOFOLLOW) < 0)
            return -errno_to_p9(errno);
        ctime_updated = TRUE;
    }
    if ((mask & P9_SETATTR_CTIME) && !ctime_updated) {
        if (fchownat(f->dir_fd, name, -1, -1, AT_SYMLINK_NOFOLLOW) < 0)
            return -errno_to_p9(errno);
    }
    return 0;
}

static int fs_link(FSDevice *fs, FSFile *df, FSFile *f, const char *name)
{
    int dfd, ret;
    (void)fs;

    /* FLOE-EMBED: hard link by contained fds at both ends. linkat() without
       AT_SYMLINK_FOLLOW links the symlink itself (POSIX/Linux/Darwin), so
       an outside target can never be imported into the share. */
    if (!fs_valid_name(name) || f->name == NULL)
        return -P9_EPERM;
    dfd = fs_fid_dirfd(df);
    if (dfd < 0)
        return -errno_to_p9(errno);
    ret = linkat(f->dir_fd, f->name, dfd, name, 0) < 0 ? -errno_to_p9(errno)
                                                       : 0;
    close(dfd);
    return ret;
}

static int fs_symlink(FSDevice *fs, FSQID *qid,
                      FSFile *f, const char *name, const char *symgt, uint32_t gid)
{
    struct stat st;
    int dfd, ret;
    (void)fs; (void)gid;

    /* FLOE-EMBED: the target string is stored verbatim -- it may be
       absolute or contain ".." -- but it can never be followed outside the
       export root because every later resolution goes through contained
       fds with O_NOFOLLOW. A guest link to /etc or ../../ is inert. */
    if (!fs_valid_name(name))
        return -P9_EPERM;
    dfd = fs_fid_dirfd(f);
    if (dfd < 0)
        return -errno_to_p9(errno);
    if (symlinkat(symgt, dfd, name) < 0) {
        ret = -errno_to_p9(errno);
    } else if (fstatat(dfd, name, &st, AT_SYMLINK_NOFOLLOW) != 0) {
        ret = -errno_to_p9(errno);
    } else {
        ret = 0;
    }
    close(dfd);
    if (ret)
        return ret;
    stat_to_qid(qid, &st);
    return 0;
}

static int fs_mknod(FSDevice *fs, FSQID *qid,
             FSFile *f, const char *name, uint32_t mode, uint32_t major,
             uint32_t minor, uint32_t gid)
{
    struct stat st;
    int dfd, ret;
    (void)fs; (void)gid;

    if (!fs_valid_name(name))
        return -P9_EPERM;
    dfd = fs_fid_dirfd(f);
    if (dfd < 0)
        return -errno_to_p9(errno);
    if (mknodat(dfd, name, mode, makedev(major, minor)) < 0) {
        ret = -errno_to_p9(errno);
    } else if (fstatat(dfd, name, &st, AT_SYMLINK_NOFOLLOW) != 0) {
        ret = -errno_to_p9(errno);
    } else {
        ret = 0;
    }
    close(dfd);
    if (ret)
        return ret;
    stat_to_qid(qid, &st);
    return 0;
}

static int fs_readlink(FSDevice *fs, char *buf, int buf_size, FSFile *f)
{
    int ret;
    (void)fs;

    /* FLOE-EMBED: read the link relative to its contained parent dir; the
       returned string is data, never a path this backend resolves */
    if (f->name == NULL)
        return -P9_ENOENT;
    ret = readlinkat(f->dir_fd, f->name, buf, buf_size - 1);
    if (ret < 0)
        return -errno_to_p9(errno);
    buf[ret] = '\0';
    return 0;
}

static int fs_renameat(FSDevice *fs, FSFile *f, const char *name, 
                FSFile *new_f, const char *new_name)
{
    int dfd, new_dfd, ret;
    (void)fs;

    /* FLOE-EMBED: both ends are contained dirfds, so an inode can never be
       renamed across the export-root boundary */
    if (!fs_valid_name(name) || !fs_valid_name(new_name))
        return -P9_EPERM;
    dfd = fs_fid_dirfd(f);
    if (dfd < 0)
        return -errno_to_p9(errno);
    new_dfd = fs_fid_dirfd(new_f);
    if (new_dfd < 0) {
        ret = -errno_to_p9(errno);
        close(dfd);
        return ret;
    }
    ret = renameat(dfd, name, new_dfd, new_name) < 0 ? -errno_to_p9(errno)
                                                     : 0;
    close(dfd);
    close(new_dfd);
    return ret;
}

static int fs_unlinkat(FSDevice *fs, FSFile *f, const char *name)
{
    int dfd, ret;
    (void)fs;

    if (!fs_valid_name(name))
        return -P9_EPERM;
    dfd = fs_fid_dirfd(f);
    if (dfd < 0)
        return -errno_to_p9(errno);
    ret = unlinkat(dfd, name, 0);
    if (ret < 0 && errno == EISDIR)
        ret = unlinkat(dfd, name, AT_REMOVEDIR);
    if (ret < 0)
        ret = -errno_to_p9(errno);
    close(dfd);
    return ret;
}

static int fs_lock(FSDevice *fs, FSFile *f, const FSLock *lock)
{
    int ret;
    struct flock fl;
    (void)fs;
    
    /* XXX: lock directories too */
    if (!f->is_opened || f->is_dir)
        return -P9_EPROTO;

    fl.l_type = lock->type;
    fl.l_whence = SEEK_SET;
    fl.l_start = lock->start;
    fl.l_len = lock->length;
    
    ret = fcntl(f->u.fd, F_SETLK, &fl);
    if (ret == 0) {
        ret = P9_LOCK_SUCCESS;
    } else if (errno == EAGAIN || errno == EACCES) {
        ret = P9_LOCK_BLOCKED;
    } else {
        ret = -errno_to_p9(errno);
    }
    return ret;
}

static int fs_getlock(FSDevice *fs, FSFile *f, FSLock *lock)
{
    int ret;
    struct flock fl;
    (void)fs;
    
    /* XXX: lock directories too */
    if (!f->is_opened || f->is_dir)
        return -P9_EPROTO;

    fl.l_type = lock->type;
    fl.l_whence = SEEK_SET;
    fl.l_start = lock->start;
    fl.l_len = lock->length;

    ret = fcntl(f->u.fd, F_GETLK, &fl);
    if (ret < 0) {
        ret = -errno_to_p9(errno);
    } else {
        lock->type = fl.l_type;
        lock->start = fl.l_start;
        lock->length = fl.l_len;
    }
    return ret;
}

static void fs_disk_end(FSDevice *fs1)
{
    FSDeviceDisk *fs = (FSDeviceDisk *)fs1;
    if (fs->root_fd >= 0)
        close(fs->root_fd);
    free(fs->root_path);
}

FSDevice *fs_disk_init(const char *root_path)
{
    FSDeviceDisk *fs;
    struct stat st;

    /* FLOE-EMBED: pin the export root on an fd for the share lifetime and
       refuse symlink roots, so the diagnostics path and the fd authority
       always agree about what the root is */
    if (lstat(root_path, &st) != 0 || !S_ISDIR(st.st_mode))
        return NULL;

    fs = mallocz(sizeof(*fs));
    if (!fs)
        return NULL;
    fs->root_fd = open(root_path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
    if (fs->root_fd < 0) {
        free(fs);
        return NULL;
    }

    fs->common.fs_end = fs_disk_end;
    fs->common.fs_delete = fs_delete;
    fs->common.fs_statfs = fs_statfs;
    fs->common.fs_attach = fs_attach;
    fs->common.fs_walk = fs_walk;
    fs->common.fs_mkdir = fs_mkdir;
    fs->common.fs_open = fs_open;
    fs->common.fs_create = fs_create;
    fs->common.fs_stat = fs_stat;
    fs->common.fs_setattr = fs_setattr;
    fs->common.fs_close = fs_close;
    fs->common.fs_readdir = fs_readdir;
    fs->common.fs_read = fs_read;
    fs->common.fs_write = fs_write;
    fs->common.fs_link = fs_link;
    fs->common.fs_symlink = fs_symlink;
    fs->common.fs_mknod = fs_mknod;
    fs->common.fs_readlink = fs_readlink;
    fs->common.fs_renameat = fs_renameat;
    fs->common.fs_unlinkat = fs_unlinkat;
    fs->common.fs_lock = fs_lock;
    fs->common.fs_getlock = fs_getlock;
    
    fs->root_path = strdup(root_path);
    if (!fs->root_path) {
        close(fs->root_fd);
        free(fs);
        return NULL;
    }
    return (FSDevice *)fs;
}
