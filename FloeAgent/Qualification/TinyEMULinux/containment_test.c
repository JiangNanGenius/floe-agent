/*
 * containment_test.c — focused native check for patch 0007 (9p export-root
 * containment) against the real patched fs_disk.c backend. No VM, no guest:
 * the test drives the FSDevice/FSFile operations the virtio-9p device would
 * call and asserts that guest-shaped names (symlinks, "..", "/", absolute
 * targets) can never name anything outside the export root.
 *
 * Copyright (c) 2026 Floe contributors
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Usage: containment_test
 * Exit 0 = all checks passed; 1 = failure (each failure is printed).
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <time.h>
#include <sys/stat.h>
#include <sys/types.h>

#include "fs.h"

static double now_s(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

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
static char outside_dir[4096];
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

static char *read_host_file(const char *path)
{
    static char buf[4096];
    FILE *f = fopen(path, "rb");
    size_t n;
    if (!f)
        return NULL;
    n = fread(buf, 1, sizeof(buf) - 1, f);
    fclose(f);
    buf[n] = 0;
    return buf;
}

/* fs_walk with one component; returns components walked (0 or 1) and the
   new fid (never NULL on 0/1; NULL only on backend error) */
static int walk1(FSDevice *fs, FSFile *f, const char *name, FSFile **out)
{
    FSQID qid;
    char *names = (char *)name;
    return fs->fs_walk(fs, out, &qid, f, 1, &names);
}

/* fs_walk with a literal array of names */
static int walkn(FSDevice *fs, FSFile *f, int n, char **names, FSFile **out)
{
    FSQID qids[8];
    return fs->fs_walk(fs, out, qids, f, n, names);
}

int main(void)
{
    FSDevice *fs;
    FSFile *root = NULL, *f1 = NULL, *f2 = NULL, *sym = NULL, *dirf = NULL;
    FSQID qid;
    FSStat st;
    char p[4096], p2[4096];
    char linkbuf[1024];
    char *names[2];
    int ret;

    printf("== 9p export-root containment (patch 0007) ==\n");

    /* ---------- fixtures ---------- */
    snprintf(root_dir, sizeof(root_dir), "/tmp/floe_contain_XXXXXX");
    if (!mkdtemp(root_dir)) {
        printf("FAIL: mkdtemp(%s): %s\n", root_dir, strerror(errno));
        return 2;
    }
    path_join(outside_dir, sizeof(outside_dir), root_dir, "outside");
    path_join(export_dir, sizeof(export_dir), root_dir, "export");
    mkdir(outside_dir, 0700);
    mkdir(export_dir, 0700);
    path_join(p, sizeof(p), outside_dir, "secret.txt");
    write_file(p, "SECRET-OUTSIDE\n");
    path_join(p, sizeof(p), export_dir, "inside.txt");
    write_file(p, "INSIDE-OK\n");
    path_join(p, sizeof(p), export_dir, "dir1");
    mkdir(p, 0700);
    path_join(p2, sizeof(p2), p, "sub");
    mkdir(p2, 0700);
    path_join(p2, sizeof(p2), p, "f1.txt");
    write_file(p2, "F1-OK\n");
    /* guest-visible escape material created by the host fixture */
    path_join(p, sizeof(p), export_dir, "link_rel");
    if (symlink("../outside/secret.txt", p) != 0) { perror("symlink rel"); return 2; }
    path_join(p, sizeof(p), export_dir, "link_abs");
    snprintf(p, sizeof(p), "%s/link_abs", export_dir);
    snprintf(p2, sizeof(p2), "%s/outside/secret.txt", root_dir);
    if (symlink(p2, p) != 0) { perror("symlink abs"); return 2; }
    snprintf(p, sizeof(p), "%s/dir_link", export_dir);
    if (symlink("../outside", p) != 0) { perror("symlink dir"); return 2; }

    fs = fs_disk_init(export_dir);
    if (!fs) {
        printf("FAIL: fs_disk_init(%s)\n", export_dir);
        return 2;
    }

    /* ---------- attach + honest path ---------- */
    CHECK(fs->fs_attach(fs, &root, &qid, 0, "u", "a") == 0 && root != NULL,
          "attach failed");
    CHECK(qid.type == P9_QTDIR, "attach qid type %d != dir", qid.type);

    ret = walk1(fs, root, "inside.txt", &f1);
    CHECK(ret == 1 && f1 != NULL, "walk inside.txt ret=%d", ret);
    CHECK(fs->fs_stat(fs, f1, &st) == 0 && S_ISREG(st.st_mode),
          "stat inside.txt is not a regular file");
    CHECK(fs->fs_open(fs, &qid, f1, P9_O_RDONLY, NULL, NULL) == 0,
          "open inside.txt");
    {
        char buf[64];
        int n = fs->fs_read(fs, f1, 0, (uint8_t *)buf, sizeof(buf) - 1);
        if (n > 0)
            buf[n] = 0;
        CHECK(n > 0 && !strcmp(buf, "INSIDE-OK\n"),
              "read inside.txt -> %d %s", n, n > 0 ? buf : "");
        fs->fs_close(fs, f1);
    }
    fs->fs_delete(fs, f1);
    f1 = NULL;

    /* ---------- ".." and "/" names are refused ---------- */
    ret = walk1(fs, root, "..", &f1);
    CHECK(ret == 0 && f1 != NULL, "walk '..' ret=%d (must be 0)", ret);
    if (f1) { fs->fs_delete(fs, f1); f1 = NULL; }
    ret = walk1(fs, root, "dir1/../../outside", &f1);
    CHECK(ret == 0, "walk 'dir1/../../outside' ret=%d (must be 0)", ret);
    if (f1) { fs->fs_delete(fs, f1); f1 = NULL; }
    ret = walk1(fs, root, "/etc/passwd", &f1);
    CHECK(ret == 0, "walk '/etc/passwd' ret=%d (must be 0)", ret);
    if (f1) { fs->fs_delete(fs, f1); f1 = NULL; }

    /* ---------- symlinks are returned as links, never traversed ---------- */
    ret = walk1(fs, root, "link_rel", &sym);
    CHECK(ret == 1 && sym != NULL, "walk link_rel ret=%d", ret);
    CHECK(fs->fs_stat(fs, sym, &st) == 0 && S_ISLNK(st.st_mode),
          "stat link_rel is not a symlink");
    memset(linkbuf, 0, sizeof(linkbuf));
    CHECK(fs->fs_readlink(fs, linkbuf, sizeof(linkbuf), sym) == 0 &&
          !strcmp(linkbuf, "../outside/secret.txt"),
          "readlink link_rel -> '%s'", linkbuf);
    /* the classic escape: walk through the link into the outside file */
    names[0] = "secret.txt";
    ret = walkn(fs, sym, 1, names, &f2);
    CHECK(ret == 0, "walk through link_rel/secret.txt ret=%d (must be 0)", ret);
    if (f2) { fs->fs_delete(fs, f2); f2 = NULL; }
    /* opening the link itself must not follow it either */
    CHECK(fs->fs_open(fs, &qid, sym, P9_O_RDONLY, NULL, NULL) < 0,
          "open(link_rel) unexpectedly succeeded (followed the link)");
    f2 = NULL;
    fs->fs_delete(fs, sym);
    sym = NULL;

    ret = walk1(fs, root, "link_abs", &sym);
    CHECK(ret == 1 && sym != NULL, "walk link_abs ret=%d", ret);
    memset(linkbuf, 0, sizeof(linkbuf));
    CHECK(fs->fs_readlink(fs, linkbuf, sizeof(linkbuf), sym) == 0 &&
          linkbuf[0] == '/',
          "readlink link_abs -> '%s'", linkbuf);
    names[0] = "anything";
    ret = walkn(fs, sym, 1, names, &f2);
    CHECK(ret == 0, "walk through absolute link ret=%d (must be 0)", ret);
    if (f2) { fs->fs_delete(fs, f2); f2 = NULL; }
    fs->fs_delete(fs, sym);
    sym = NULL;

    ret = walk1(fs, root, "dir_link", &sym);
    CHECK(ret == 1 && sym != NULL, "walk dir_link ret=%d", ret);
    names[0] = "secret.txt";
    ret = walkn(fs, sym, 1, names, &f2);
    CHECK(ret == 0, "walk through directory symlink ret=%d (must be 0)", ret);
    if (f2) { fs->fs_delete(fs, f2); f2 = NULL; }
    fs->fs_delete(fs, sym);
    sym = NULL;

    /* ---------- guest-created symlink is inert ---------- */
    CHECK(fs->fs_symlink(fs, &qid, root, "guest_esc",
                         "../../outside/secret.txt", 0) == 0,
          "fs_symlink guest_esc failed");
    ret = walk1(fs, root, "guest_esc", &sym);
    CHECK(ret == 1 && sym != NULL, "walk guest_esc ret=%d", ret);
    memset(linkbuf, 0, sizeof(linkbuf));
    CHECK(fs->fs_readlink(fs, linkbuf, sizeof(linkbuf), sym) == 0 &&
          !strcmp(linkbuf, "../../outside/secret.txt"),
          "readlink guest_esc -> '%s'", linkbuf);
    names[0] = "secret.txt";
    ret = walkn(fs, sym, 1, names, &f2);
    CHECK(ret == 0, "walk through guest_esc ret=%d (must be 0)", ret);
    if (f2) { fs->fs_delete(fs, f2); f2 = NULL; }
    CHECK(fs->fs_open(fs, &qid, sym, P9_O_RDONLY, NULL, NULL) < 0,
          "open(guest_esc) followed the guest symlink");
    fs->fs_delete(fs, sym);
    sym = NULL;

    /* ---------- mutation names are validated before any syscall ---------- */
    CHECK(fs->fs_create(fs, &qid, root, "..", P9_O_RDWR | P9_O_CREAT,
                        0644, 0) < 0, "fs_create '..' accepted");
    CHECK(fs->fs_create(fs, &qid, root, "dir1/../evil", P9_O_RDWR | P9_O_CREAT,
                        0644, 0) < 0, "fs_create 'dir1/../evil' accepted");
    CHECK(fs->fs_mkdir(fs, &qid, root, "..", 0700, 0) < 0,
          "fs_mkdir '..' accepted");
    CHECK(fs->fs_symlink(fs, &qid, root, "..", "/etc", 0) < 0,
          "fs_symlink name '..' accepted");
    CHECK(fs->fs_mknod(fs, &qid, root, "..", S_IFREG | 0600, 0, 0, 0) < 0,
          "fs_mknod '..' accepted");
    CHECK(fs->fs_unlinkat(fs, root, "..") < 0, "fs_unlinkat '..' accepted");
    CHECK(fs->fs_unlinkat(fs, root, "../outside/secret.txt") < 0,
          "fs_unlinkat traversal accepted");
    CHECK(fs->fs_renameat(fs, root, "inside.txt", root, "..") < 0,
          "fs_renameat to '..' accepted");
    CHECK(fs->fs_renameat(fs, root, "..", root, "x") < 0,
          "fs_renameat from '..' accepted");
    {
        FSFile *file = NULL;
        ret = walk1(fs, root, "inside.txt", &file);
        CHECK(ret == 1 && file != NULL, "walk inside.txt for link test");
        if (file) {
            CHECK(fs->fs_link(fs, root, file, "..") < 0,
                  "fs_link name '..' accepted");
            CHECK(fs->fs_link(fs, root, file, "dir1/../evil") < 0,
                  "fs_link traversal name accepted");
            CHECK(fs->fs_link(fs, root, file, "hardlink.txt") == 0,
                  "legitimate hard link refused");
            CHECK(fs->fs_unlinkat(fs, root, "hardlink.txt") == 0,
                  "unlink of hard link failed");
            fs->fs_delete(fs, file);
        }
    }

    /* ---------- a file fid has no children (no sibling resolution) ------- */
    {
        FSFile *file = NULL, *child = NULL;
        ret = walk1(fs, root, "inside.txt", &file);
        CHECK(ret == 1 && file != NULL, "walk inside.txt (2)");
        if (file) {
            ret = walk1(fs, file, "dir1", &child);
            CHECK(ret == 0, "walk from a file fid ret=%d (must be 0)", ret);
            if (child) { fs->fs_delete(fs, child); child = NULL; }
            fs->fs_delete(fs, file);
        }
    }

    /* ---------- legitimate in-share create/write/rename/unlink ---------- */
    ret = walk1(fs, root, "dir1", &dirf);
    CHECK(ret == 1 && dirf != NULL, "walk dir1 ret=%d", ret);
    if (dirf) {
        const char *created = "created.txt";
        const char *renamed = "renamed.txt";
        static const char data[] = "hello-9p";
        int n;
        /* 9p lcreate semantics: the fid now denotes the created file, so
           it is deleted (clunked) and the directory re-walked below. */
        CHECK(fs->fs_create(fs, &qid, dirf, created,
                            P9_O_RDWR | P9_O_CREAT, 0644, 0) == 0,
              "fs_create dir1/created.txt");
        n = fs->fs_write(fs, dirf, 0, (const uint8_t *)data, sizeof(data) - 1);
        CHECK(n == (int)sizeof(data) - 1, "fs_write -> %d", n);
        fs->fs_close(fs, dirf);
        fs->fs_delete(fs, dirf);
        dirf = NULL;
        path_join(p, sizeof(p), export_dir, "dir1");
        path_join(p2, sizeof(p2), p, created);
        {
            char *host = read_host_file(p2);
            CHECK(host && !strcmp(host, data), "host file content '%s'",
                  host ? host : "(missing)");
        }
        ret = walk1(fs, root, "dir1", &dirf);
        CHECK(ret == 1 && dirf != NULL, "re-walk dir1 ret=%d", ret);
    }
    if (dirf) {
        const char *created = "created.txt";
        const char *renamed = "renamed.txt";
        CHECK(fs->fs_renameat(fs, dirf, created, dirf, renamed) == 0,
              "fs_renameat in dir1");
        path_join(p, sizeof(p), export_dir, "dir1/renamed.txt");
        CHECK(access(p, F_OK) == 0, "renamed host file missing");
        CHECK(fs->fs_unlinkat(fs, dirf, renamed) == 0, "fs_unlinkat renamed");
        CHECK(access(p, F_OK) != 0, "unlinked host file still present");
        /* rename cannot move the root itself or an entry outside */
        CHECK(fs->fs_renameat(fs, dirf, "sub", root, "..") < 0,
              "nested rename to '..' accepted");
        fs->fs_delete(fs, dirf);
        dirf = NULL;
    }

    /* ---------- special files are metadata-only, never opened ---------- */
    /* A host FIFO under the share would block open() until a peer appears,
       freezing the VM slice with no way to interrupt it; the backend must
       answer EOPNOTSUPP instead. */
    {
        double t0, dt;
        path_join(p, sizeof(p), export_dir, "fifo");
        CHECK(mkfifo(p, 0600) == 0, "mkfifo fixture");
        ret = walk1(fs, root, "fifo", &sym);
        CHECK(ret == 1 && sym != NULL, "walk fifo ret=%d", ret);
        if (sym) {
            t0 = now_s();
            CHECK(fs->fs_open(fs, &qid, sym, P9_O_WRONLY, NULL, NULL) ==
                  -P9_ENOTSUP, "open(fifo) was not refused with EOPNOTSUPP");
            dt = now_s() - t0;
            CHECK(dt < 1.0, "open(fifo) took %.2fs (blocked on the FIFO)",
                  dt);
            CHECK(fs->fs_open(fs, &qid, sym, P9_O_RDONLY, NULL, NULL) ==
                  -P9_ENOTSUP, "read-open(fifo) was not refused");
            {
                FSStat fst;
                CHECK(fs->fs_stat(fs, sym, &fst) == 0,
                      "stat(fifo) metadata must still work");
            }
            t0 = now_s();
            CHECK(fs->fs_setattr(fs, sym, P9_SETATTR_SIZE, 0, 0, 0, 0,
                                 0, 0, 0, 0) == -P9_ENOTSUP,
                  "setattr/size on fifo was not refused");
            dt = now_s() - t0;
            CHECK(dt < 1.0, "setattr/size on fifo took %.2fs", dt);
            fs->fs_delete(fs, sym);
            sym = NULL;
        }
        CHECK(fs->fs_create(fs, &qid, root, "fifo", P9_O_WRONLY | P9_O_CREAT,
                            0644, 0) == -P9_ENOTSUP,
              "create over the existing fifo was not refused");
        CHECK(fs->fs_unlinkat(fs, root, "fifo") == 0, "unlink fifo");
    }

    /* ---------- nothing escaped to the host ---------- */
    {
        FILE *f;
        path_join(p, sizeof(p), root_dir, "evil");
        CHECK(access(p, F_OK) != 0, "escape file '%s' was created", p);
        path_join(p, sizeof(p), outside_dir, "secret.txt");
        f = fopen(p, "rb");
        CHECK(f != NULL, "outside fixture disappeared");
        if (f) {
            char buf[64] = { 0 };
            size_t n = fread(buf, 1, sizeof(buf) - 1, f);
            fclose(f);
            CHECK(n == strlen("SECRET-OUTSIDE\n") &&
                  !strcmp(buf, "SECRET-OUTSIDE\n"),
                  "outside file was modified: '%s'", buf);
        }
    }

    /* ---------- readdir still reports entries ---------- */
    CHECK(fs->fs_open(fs, &qid, root, P9_O_RDONLY | P9_O_DIRECTORY,
                      NULL, NULL) == 0, "open root as directory");
    {
        uint8_t buf[4096];
        int n = fs->fs_readdir(fs, root, 0, buf, sizeof(buf));
        CHECK(n > 0, "readdir root -> %d", n);
        fs->fs_close(fs, root);
    }

    if (root)
        fs->fs_delete(fs, root);
    fs->fs_end(fs);

    printf("checks: %d, failures: %d\n", checks, failures);
    printf("%s\n", failures ? "CONTAINMENT_FAIL" : "CONTAINMENT_OK");
    return failures ? 1 : 0;
}
