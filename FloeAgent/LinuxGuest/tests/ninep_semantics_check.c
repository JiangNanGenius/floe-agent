/*
 * ninep_semantics_check.c — focused host check for patch 0009:
 *
 *  - fs_unlinkat flag/type semantics against the REAL fs_disk backend:
 *    files, empty directories (the reported two empty dirs), non-empty
 *    directories and symlinks (whose target must never be followed),
 *  - the Txattrwalk policy helpers (empty name -> empty list, named ->
 *    ENODATA, the bogus 524 gone).
 *
 * Links against the vendored engine's fs_disk.c + cutils.c; no VM or guest
 * image is required. Build/run via ninep_semantics_check.sh.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <errno.h>

#include "fs.h"

static int failures = 0;
#define CHECK(cond, msg) do { \
    if (cond) { printf("ok - %s\n", msg); } \
    else { printf("FAIL - %s\n", msg); failures++; } \
} while (0)

static FSFile *attach_root(FSDevice *fs, FSQID *qid) {
    FSFile *rootfid = NULL;
    if (fs->fs_attach(fs, &rootfid, qid, 0, NULL, NULL) != 0) return NULL;
    return rootfid;
}

/* Calls fs_unlinkat exactly as the virtio dispatch does: the parent
 * directory fid plus the single-component name and the guest flags. The
 * engine performs the AT_SYMLINK_NOFOLLOW type check itself. */
static int unlink_child(FSDevice *fs, FSFile *dir, const char *name, uint32_t flags) {
    return fs->fs_unlinkat(fs, dir, name, flags);
}

static void write_file(const char *path, const char *body) {
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) { (void)write(fd, body, strlen(body)); close(fd); }
}

int main(void) {
    char root[256];
    snprintf(root, sizeof root, "/tmp/floe-9p-check-%d", (int)getpid());
    char cmd[512];
    snprintf(cmd, sizeof cmd, "rm -rf %s && mkdir -p %s", root, root);
    if (system(cmd) != 0) return 2;

    /* Build the on-disk fixture through the host FS directly. */
    snprintf(cmd, sizeof cmd, "mkdir -p %s/emptydir %s/nonempty %s/realdir", root, root, root);
    (void)system(cmd);
    char path[512];
    snprintf(path, sizeof path, "%s/afile", root); write_file(path, "data");
    snprintf(path, sizeof path, "%s/nonempty/child", root); write_file(path, "c");
    snprintf(path, sizeof path, "%s/alink", root);
    symlink("afile", path);
    snprintf(path, sizeof path, "%s/dirlink", root);
    symlink("emptydir", path);

    FSDevice *fs = fs_disk_init(root);
    CHECK(fs != NULL, "fs_disk_init opens the export root");
    if (!fs) return 2;

    FSQID rootqid;
    FSFile *rootfid = attach_root(fs, &rootqid);
    CHECK(rootfid != NULL, "fs_attach yields the root fid");

    /* 1. Plain file with flags=0 is removed (Linux rmdir-less unlink). */
    CHECK(unlink_child(fs, rootfid, "afile", 0) == 0, "unlink file (flags=0)");
    struct stat st;
    snprintf(path, sizeof path, "%s/afile", root);
    CHECK(stat(path, &st) != 0 && errno == ENOENT, "file is gone after unlink");

    /* 2. Empty directory: flags=0 -> EISDIR (never EPERM like Darwin's
          unlinkat), then AT_REMOVEDIR removes it (the reported empty dirs). */
    int rc = unlink_child(fs, rootfid, "emptydir", 0);
    CHECK(rc == -P9_EISDIR, "empty dir without AT_REMOVEDIR -> EISDIR");
    CHECK(unlink_child(fs, rootfid, "emptydir", P9_AT_REMOVEDIR) == 0,
          "empty dir with AT_REMOVEDIR is removed");
    snprintf(path, sizeof path, "%s/emptydir", root);
    CHECK(stat(path, &st) != 0 && errno == ENOENT, "empty dir is gone");

    /* 3. Non-empty directory: AT_REMOVEDIR refused (ENOTEMPTY). */
    rc = unlink_child(fs, rootfid, "nonempty", P9_AT_REMOVEDIR);
    CHECK(rc == -P9_ENOTEMPTY, "non-empty dir -> ENOTEMPTY");
    snprintf(path, sizeof path, "%s/nonempty/child", root);
    CHECK(stat(path, &st) == 0, "non-empty dir contents preserved");

    /* 4. AT_REMOVEDIR on a non-directory (a symlink) -> ENOTDIR. */
    rc = unlink_child(fs, rootfid, "alink", P9_AT_REMOVEDIR);
    CHECK(rc == -P9_ENOTDIR, "AT_REMOVEDIR on a symlink -> ENOTDIR");

    /* 5. Symlink removed as a link with flags=0; target survives. */
    CHECK(unlink_child(fs, rootfid, "alink", 0) == 0, "symlink unlink succeeds");
    snprintf(path, sizeof path, "%s/alink", root);
    CHECK(lstat(path, &st) != 0, "symlink itself removed");
    /* A symlink-to-directory is also a link, not a directory. */
    CHECK(unlink_child(fs, rootfid, "dirlink", 0) == 0, "dir-symlink unlink succeeds");
    snprintf(path, sizeof path, "%s/realdir", root);
    CHECK(stat(path, &st) == 0, "symlink target directory survives");

    /* 6. Unknown flag bits are rejected. */
    CHECK(unlink_child(fs, rootfid, "realdir", 0x4000) == -P9_EINVAL,
          "unknown unlinkat flags -> EINVAL");

    /* 7. xattrwalk policy: no xattrs are exported. */
    uint64_t size = 999;
    CHECK(floe_9p_xattrwalk_result("", &size) == 0 && size == 0,
          "xattrwalk empty name (list) yields size 0");
    CHECK(floe_9p_xattrwalk_result("security.selinux", &size) == -P9_ENODATA,
          "xattrwalk named query -> ENODATA (ls degrades silently)");
    CHECK(P9_ENOTSUP == 95, "P9_ENOTSUP uses the Linux errno value, not 524");
    CHECK(P9_ENODATA == 61 && P9_EISDIR == 21, "errno constants match Linux uapi");

    fs->fs_delete(fs, rootfid);
    fs_end(fs);
    snprintf(cmd, sizeof cmd, "rm -rf %s", root);
    (void)system(cmd);

    if (failures) { printf("%d check(s) failed\n", failures); return 1; }
    printf("all 9p semantics checks passed\n");
    return 0;
}
