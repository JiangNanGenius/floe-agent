/*
 * fid_stat_test.c — focused native check for patch 0021 (9p opened-fid
 * metadata after rename/unlink) against the real patched fs_disk.c
 * backend. No VM, no guest: the test drives the FSDevice/FSFile
 * operations the virtio-9p device would call.
 *
 * Background: apt's GetTempFile() cannot use O_TMPFILE through this
 * backend (fs_valid_name() rejects an empty component), so it falls back
 * to mkstemp()+immediate unlink and then stats the opened descriptor.
 * Upstream fs_fid_stat() re-resolved parent dir fd + stale name after the
 * unlink, returned ENOENT, and apt-get update exited 100. The repair
 * stats the already-open fd for opened regular-file fids.
 *
 * This test asserts:
 *   - open -> stat reports the live size (the diagnostic's size-5 case)
 *   - rename of an opened file -> stat on the OPEN fid still succeeds
 *   - unlink of an opened file -> stat + read on the OPEN fid still work
 *   - create (lcreate) fid -> rename -> unlink -> stat/read still work
 *   - an OPENED DIRECTORY fid keeps working after the host renames it
 *   - fail-closed behaviour is preserved: an UNOPENED fid of a deleted
 *     file still stats ENOENT, and symlink fids still report S_ISLNK
 *     (AT_SYMLINK_NOFOLLOW semantics unchanged)
 *
 * Copyright (c) 2026 Floe contributors
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Usage: fid_stat_test
 * Exit 0 = all checks passed; 1 = failure (each failure is printed).
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/stat.h>
#include <sys/types.h>

#include "fs.h"

static int failures;
static int checks;

#define CHECK(cond, ...) do {                                            \
        checks++;                                                        \
        if (!(cond)) {                                                   \
            failures++;                                                  \
            printf("FAIL: ");                                            \
            printf(__VA_ARGS__);                                         \
            printf("\n");                                                \
        }                                                                \
    } while (0)

static char root_dir[4096];
static char export_dir[4096];

static void path_join(char *dst, size_t n, const char *a, const char *b)
{
    snprintf(dst, n, "%s/%s", a, b);
}

static void write_file(const char *path, const char *data)
{
    FILE *f = fopen(path, "wb");
    if (!f || fwrite(data, 1, strlen(data), f) != strlen(data)) {
        printf("FAIL: cannot write fixture %s\n", path);
        exit(2);
    }
    fclose(f);
}

/* fs_walk with one component; returns components walked (0 or 1) */
static int walk1(FSDevice *fs, FSFile *f, const char *name, FSFile **out)
{
    FSQID qid;
    char *names = (char *)name;
    return fs->fs_walk(fs, out, &qid, f, 1, &names);
}

int main(void)
{
    FSDevice *fs;
    FSFile *root = NULL, *dirf = NULL, *ofile = NULL, *tmp = NULL;
    FSQID qid;
    FSStat st;
    char p[4096];
    int ret;

    printf("== 9p opened-fid metadata after rename/unlink (patch 0021) ==\n");

    /* ---------- fixtures ---------- */
    snprintf(root_dir, sizeof(root_dir), "/tmp/floe_fdstat_XXXXXX");
    if (!mkdtemp(root_dir)) {
        printf("FAIL: mkdtemp(%s): %s\n", root_dir, strerror(errno));
        return 2;
    }
    path_join(export_dir, sizeof(export_dir), root_dir, "export");
    mkdir(export_dir, 0700);
    path_join(p, sizeof(p), export_dir, "pkg.partial");
    write_file(p, "12345"); /* 5 bytes: the FD-REPORT.json probe size */
    path_join(p, sizeof(p), export_dir, "d1");
    mkdir(p, 0700);
    path_join(p, sizeof(p), export_dir, "d1/inner.txt");
    write_file(p, "INNER\n");
    path_join(p, sizeof(p), export_dir, "datalink");
    if (symlink("pkg.partial", p) != 0) { perror("symlink"); return 2; }

    fs = fs_disk_init(export_dir);
    if (!fs) {
        printf("FAIL: fs_disk_init(%s)\n", export_dir);
        return 2;
    }

    CHECK(fs->fs_attach(fs, &root, &qid, 0, "u", "a") == 0 && root != NULL,
          "attach failed");

    /* ---------- 1. open -> stat reports the live size (5 bytes) ------- */
    ret = walk1(fs, root, "pkg.partial", &ofile);
    CHECK(ret == 1 && ofile != NULL, "walk pkg.partial ret=%d", ret);
    CHECK(fs->fs_stat(fs, ofile, &st) == 0 && S_ISREG(st.st_mode) &&
          st.st_size == 5, "stat pkg.partial before open: mode/size "
          "(size=%llu)", (unsigned long long)st.st_size);
    CHECK(fs->fs_open(fs, &qid, ofile, P9_O_RDWR, NULL, NULL) == 0,
          "open pkg.partial");
    CHECK(fs->fs_stat(fs, ofile, &st) == 0 && S_ISREG(st.st_mode) &&
          st.st_size == 5, "stat OPEN pkg.partial: mode/size (size=%llu)",
          (unsigned long long)st.st_size);

    /* ---------- 2. rename of the opened file: OPEN fid must still stat - */
    CHECK(fs->fs_renameat(fs, root, "pkg.partial", root, "pkg.new") == 0,
          "rename pkg.partial -> pkg.new");
    CHECK(fs->fs_stat(fs, ofile, &st) == 0 && S_ISREG(st.st_mode) &&
          st.st_size == 5,
          "stat OPEN fid after rename failed (errno ENOENT regression): "
          "size=%llu", (unsigned long long)st.st_size);
    {
        char buf[16] = { 0 };
        int n = fs->fs_read(fs, ofile, 0, (uint8_t *)buf, sizeof(buf) - 1);
        CHECK(n == 5 && !memcmp(buf, "12345", 5),
              "read OPEN fid after rename -> %d '%s'", n, buf);
    }

    /* ---------- 3. unlink of the opened file: OPEN fid must still work - */
    CHECK(fs->fs_unlinkat(fs, root, "pkg.new", 0) == 0, "unlink pkg.new");
    CHECK(fs->fs_stat(fs, ofile, &st) == 0 && S_ISREG(st.st_mode) &&
          st.st_size == 5,
          "stat OPEN fid after unlink failed (apt fd-9 regression): "
          "size=%llu", (unsigned long long)st.st_size);
    {
        char buf[16] = { 0 };
        int n = fs->fs_read(fs, ofile, 0, (uint8_t *)buf, sizeof(buf) - 1);
        CHECK(n == 5 && !memcmp(buf, "12345", 5),
              "read OPEN fid after unlink -> %d '%s'", n, buf);
    }
    fs->fs_close(fs, ofile);
    fs->fs_delete(fs, ofile);
    ofile = NULL;

    /* ---------- 4. lcreate fid (apt GetTempFile shape): create -> rename
       -> unlink while the create fid stays open and usable ------------- */
    {
        FSFile *dirA = NULL, *dirB = NULL;
        ret = walk1(fs, root, "d1", &dirA);
        CHECK(ret == 1 && dirA != NULL, "walk d1 for lcreate ret=%d", ret);
        CHECK(fs->fs_create(fs, &qid, dirA, "dl.XXXXXX.tmp",
                            P9_O_RDWR | P9_O_CREAT | P9_O_EXCL, 0600, 0) == 0,
              "fs_create dl.XXXXXX.tmp");
        /* dirA now denotes the created file (lcreate semantics) */
        CHECK(fs->fs_write(fs, dirA, 0, (const uint8_t *)"abcde", 5) == 5,
              "write create-fid");
        CHECK(fs->fs_stat(fs, dirA, &st) == 0 && st.st_size == 5,
              "stat create-fid before rename (size=%llu)",
              (unsigned long long)st.st_size);
        /* rename by a SECOND directory fid, like a second apt helper fid;
           a file fid cannot act as a rename directory (ENOTDIR) */
        ret = walk1(fs, root, "d1", &dirB);
        CHECK(ret == 1 && dirB != NULL, "walk second d1 fid ret=%d", ret);
        CHECK(fs->fs_renameat(fs, dirB, "dl.XXXXXX.tmp", dirB, "dl.stale") == 0,
              "rename create-fid target by dir fid");
        CHECK(fs->fs_stat(fs, dirA, &st) == 0 && S_ISREG(st.st_mode) &&
              st.st_size == 5,
              "stat lcreate fid after rename failed: size=%llu",
              (unsigned long long)st.st_size);
        CHECK(fs->fs_unlinkat(fs, dirB, "dl.stale", 0) == 0,
              "unlink lcreate fid target");
        CHECK(fs->fs_stat(fs, dirA, &st) == 0 && S_ISREG(st.st_mode) &&
              st.st_size == 5,
              "stat lcreate fid after unlink failed (apt cache-stage fd-4 "
              "regression): size=%llu", (unsigned long long)st.st_size);
        {
            char buf[16] = { 0 };
            int n = fs->fs_read(fs, dirA, 0, (uint8_t *)buf, sizeof(buf) - 1);
            CHECK(n == 5 && !memcmp(buf, "abcde", 5),
                  "read lcreate fid after unlink -> %d '%s'", n, buf);
        }
        fs->fs_close(fs, dirA);
        fs->fs_delete(fs, dirA);
        fs->fs_delete(fs, dirB);
    }

    /* ---------- 5. OPENED DIRECTORY fid survives a host rename -------- */
    ret = walk1(fs, root, "d1", &dirf);
    CHECK(ret == 1 && dirf != NULL, "walk d1 for dir-open ret=%d", ret);
    CHECK(fs->fs_open(fs, &qid, dirf, P9_O_RDONLY | P9_O_DIRECTORY,
                      NULL, NULL) == 0, "open d1 as directory");
    /* host-side rename (outside the 9p ops) while the fid is open */
    path_join(p, sizeof(p), export_dir, "d1");
    {
        char p2[4096];
        path_join(p2, sizeof(p2), export_dir, "d1moved");
        CHECK(rename(p, p2) == 0, "host rename of open directory");
    }
    CHECK(fs->fs_stat(fs, dirf, &st) == 0 && S_ISDIR(st.st_mode),
          "stat OPEN dir fid after host rename");
    {
        uint8_t buf[4096];
        int n = fs->fs_readdir(fs, dirf, 0, buf, sizeof(buf));
        CHECK(n > 0, "readdir OPEN dir fid after host rename -> %d", n);
    }
    fs->fs_close(fs, dirf);
    fs->fs_delete(fs, dirf);
    dirf = NULL;

    /* ---------- 6. fail-closed behaviour is preserved ------------------ */
    /* an UNOPENED fid of a deleted file still stats ENOENT (name lookup
       semantics for unopened fids unchanged) */
    path_join(p, sizeof(p), export_dir, "gone.txt");
    write_file(p, "GONE\n");
    ret = walk1(fs, root, "gone.txt", &tmp);
    CHECK(ret == 1 && tmp != NULL, "walk gone.txt ret=%d", ret);
    CHECK(fs->fs_unlinkat(fs, root, "gone.txt", 0) == 0, "unlink gone.txt");
    ret = fs->fs_stat(fs, tmp, &st);
    CHECK(ret == -P9_ENOENT,
          "stat UNOPENED fid of deleted file -> %d (want ENOENT)", ret);
    fs->fs_delete(fs, tmp);
    tmp = NULL;
    /* symlink fid still reports the link itself (NOFOLLOW unchanged) */
    ret = walk1(fs, root, "datalink", &tmp);
    CHECK(ret == 1 && tmp != NULL, "walk datalink ret=%d", ret);
    CHECK(fs->fs_stat(fs, tmp, &st) == 0 && S_ISLNK(st.st_mode),
          "stat datalink is not a symlink (NOFOLLOW changed?)");
    fs->fs_delete(fs, tmp);
    tmp = NULL;
    /* reading through the symlink still refuses to follow it */
    ret = walk1(fs, root, "datalink", &tmp);
    CHECK(ret == 1 && tmp != NULL, "re-walk datalink ret=%d", ret);
    CHECK(fs->fs_open(fs, &qid, tmp, P9_O_RDONLY, NULL, NULL) < 0,
          "open(datalink) followed the symlink");
    fs->fs_delete(fs, tmp);
    tmp = NULL;
    /* rename cannot move an opened file's name outside the export */
    ret = walk1(fs, root, "d1moved", &dirf);
    CHECK(ret == 1 && dirf != NULL, "walk d1moved ret=%d", ret);
    CHECK(fs->fs_renameat(fs, dirf, "inner.txt", root, "..") < 0,
          "renameat to '..' accepted");
    fs->fs_delete(fs, dirf);
    dirf = NULL;

    if (root)
        fs->fs_delete(fs, root);
    fs->fs_end(fs);

    printf("checks: %d, failures: %d\n", checks, failures);
    printf("%s\n", failures ? "FID_STAT_FAIL" : "FID_STAT_OK");
    return failures ? 1 : 0;
}
