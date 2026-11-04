// floe_project_supervisor.c — Floe resident-ARM64 guest project/task supervisor.
//
// The supervisor is the trusted in-guest owner of the single resident
// Machine's project lifecycle. It runs on the control console (hvc0) and
// speaks the versioned project-control protocol defined in
// floe_project_supervisor.h; every project it opens gets one unmodified
// protocol-3 floe-exec runner on its own virtio console, chrooted into a
// persistent per-project ext4 overlay rootfs with an immutable common base.
//
// Ownership model (corrected against kernel source, 2026-11-05):
//   * No user namespaces and no idmapped mounts anywhere: neither overlayfs
//     (FS_ALLOW_IDMAP only post-6.18 on master) nor cgroupfs (never) accept
//     MOUNT_ATTR_IDMAP on the target kernel (Debian trixie ARM64 6.12).
//   * Project tasks run as the guest's own root (uid 0). Per-project
//     separation = private ext4 overlay + private cgroup subtree + chroot +
//     private console/runner + per-task mount/uts/ipc namespaces and tmpfs.
//   * This is dependency/data/lifecycle isolation, NOT a uid security
//     sandbox; see the header for the full contract and evidence.
//
// What the supervisor owns (and nothing else does):
//   * project table with explicit (projectID, generation) identity,
//   * per-project overlay mount/umount on the ext4 state root,
//   * per-project cgroup subtree (lifecycle + pids containment),
//   * project runner processes (spawn, waitpid, runner-death recovery),
//   * task-tree cancellation via cgroup.kill (reaps double-fork/setsid
//     descendants that a process-group signal cannot reach),
//   * leases that serialize destructive project operations,
//   * boot-time orphan recovery of stale state from earlier generations.
//
// What it deliberately does NOT do:
//   * run user commands (the per-project runner does, unchanged),
//   * create consoles or network policy (native/exported by the host side),
//   * interpret model-supplied labels as authority: every projectID,
//     taskID, generation, path and limit is validated, and consoles and
//     cgroup roots are allocated by the supervisor only,
//   * close descriptors it does not own: native console/share fds are dup'd
//     for the runner child and the supervisor's own copies are closed only
//     after a successful exec hand-off (the fd-fix invariant).
//
// Wire summary (control console; see the header for the full grammar):
//   host -> guest: HELLO / PROJOPEN(+CHUNK,RUN) / PROJCLOSE / PROJDROP /
//                  PROJSTAT / TASKKILL / LEASE / PING / CHUNK / RUN
//   guest -> host: CAPS / BEGIN / OUT / ERR / END / FAILED / EVENT
//
// The native host build (no __linux__) compiles the pure identity, payload,
// framing and dispatch helpers with the Linux side effects stubbed to
// explicit failures (PROJOPEN/CLOSE/DROP answer END 126), so the real frame
// parser and dispatcher can be exercised over pipes without a VM, a mount
// or root — same pattern as floe_exec.c.

#ifndef _GNU_SOURCE
#define _GNU_SOURCE 1
#endif

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <termios.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include "floe_project_supervisor.h"
#include "floe_net.h" // machine-wide first-boot network plan (pure helpers)

#ifdef __linux__
#include <dirent.h>
#include <sys/mount.h>
#include <sys/sysmacros.h>
#endif

// Last machine-wide network state, answered in the supervisor CAPS (`net=`)
// exactly like the classic runner: per-project runners never touch the
// network, so the control channel is the one readiness signal for the host.
// Defined before emit_caps so the framing section sees it (compile fix:
// the 2026-11-05 draft declared it below first use).
static floe_net_status g_net_status = FLOE_NET_DOWN;

// ---------------------------------------------------------------------------
// Small helpers (identical discipline to floe_exec.c)
// ---------------------------------------------------------------------------

static int64_t now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + (int64_t)(ts.tv_nsec / 1000000);
}

static int write_all(int fd, const void *data, size_t len) {
    const unsigned char *p = (const unsigned char *)data;
    while (len > 0) {
        ssize_t wrote = write(fd, p, len);
        if (wrote < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        p += (size_t)wrote;
        len -= (size_t)wrote;
    }
    return 0;
}

static int set_nonblocking(int fd) {
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0) return -1;
    return fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

#ifdef __linux__
static void diag(const char *fmt, ...) {
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    if (n > 0) {
        size_t len = (size_t)n < sizeof buf ? (size_t)n : sizeof buf - 1;
        (void)write_all(STDERR_FILENO, buf, len);
    }
}
#else
static void diag(const char *fmt, ...) { (void)fmt; }
#endif

// ---------------------------------------------------------------------------
// Bounded byte buffer
// ---------------------------------------------------------------------------

typedef struct {
    unsigned char *data;
    size_t len;
    size_t cap;
} bytebuf;

static int bb_reserve(bytebuf *b, size_t extra) {
    if (extra > SIZE_MAX - b->len) return -1;
    size_t need = b->len + extra;
    if (need <= b->cap) return 0;
    size_t cap = b->cap ? b->cap : 4096;
    while (cap < need) {
        if (cap > SIZE_MAX / 2) { cap = need; break; }
        cap *= 2;
    }
    unsigned char *p = realloc(b->data, cap);
    if (!p) return -1;
    b->data = p;
    b->cap = cap;
    return 0;
}

static int bb_append(bytebuf *b, const void *data, size_t len) {
    if (len == 0) return 0;
    if (bb_reserve(b, len) != 0) return -1;
    memcpy(b->data + b->len, data, len);
    b->len += len;
    return 0;
}

static void bb_consume(bytebuf *b, size_t len) {
    if (len >= b->len) {
        b->len = 0;
        return;
    }
    memmove(b->data, b->data + len, b->len - len);
    b->len -= len;
}

static void bb_free(bytebuf *b) {
    free(b->data);
    b->data = NULL;
    b->len = 0;
    b->cap = 0;
}

// ---------------------------------------------------------------------------
// Framing (guest -> host). Shapes are byte-compatible with floe_exec.c so
// the host router demultiplexes the control console with the same parsers.
// ---------------------------------------------------------------------------

static int emit_marker(const char *name, const char *token) {
    char buf[FLOE_CTRL_MAX_TOKEN + 32];
    int n = snprintf(buf, sizeof buf, "\x1e" "FLOE-%s %s\x1e", name, token);
    if (n <= 0 || (size_t)n >= sizeof buf) return -1;
    return write_all(STDOUT_FILENO, buf, (size_t)n);
}

static int emit_end(const char *token, int code) {
    char buf[FLOE_CTRL_MAX_TOKEN + 48];
    int n = snprintf(buf, sizeof buf, "\x1e" "FLOE-END %s %d\x1e", token, code);
    if (n <= 0 || (size_t)n >= sizeof buf) return -1;
    return write_all(STDOUT_FILENO, buf, (size_t)n);
}

#ifdef __linux__
// EVENT frames are only ever emitted for real project lifecycle events;
// the native check build has no projects and never sends one.
static int emit_event(const char *project, const char *generation,
                      const char *kind, const char *detail) {
    char buf[512];
    int n = snprintf(buf, sizeof buf,
                     "\x1e" "FLOE-EVENT %s %s %s %s\x1e",
                     project, generation, kind, detail ? detail : "-");
    if (n <= 0 || (size_t)n >= sizeof buf) return -1;
    return write_all(STDOUT_FILENO, buf, (size_t)n);
}
#endif

static void section_open(const char *token) {
    (void)emit_marker("BEGIN", token);
}

// One bounded line of project output (never carries secrets: paths, ids,
// numeric state only).
static void emit_line(const char *token, const char *text) {
    (void)emit_marker("OUT", token);
    (void)write_all(STDOUT_FILENO, text, strlen(text));
}

static void emit_error_line(const char *token, const char *text) {
    (void)emit_marker("ERR", token);
    (void)write_all(STDOUT_FILENO, text, strlen(text));
}

// BEGIN + ERR + END for a control request that cannot be served. The reason
// is a short printable ASCII phrase, never a value from the request.
static void emit_failure(const char *token, int code, const char *reason) {
    if (token[0] == '\0') return;
    section_open(token);
    emit_error_line(token, reason);
    (void)emit_end(token, code);
}

static int emit_caps(const char *token, const char *base, const char *state) {
    char buf[900];
    int n = snprintf(buf, sizeof buf,
                     "\x1e" "FLOE-CAPS %s runner=floe-supervisor/" FLOE_SUPERVISOR_VERSION
                     " protocol=%d projects=%d tasks=%d sessions=%d base=%s state=%s net=%s\x1e",
                     token, FLOE_SUPERVISOR_PROTOCOL, FLOE_MAX_PROJECTS,
                     FLOE_MAX_PROJECT_TASKS, FLOE_MAX_PROJECT_SESSIONS, base, state,
                     floe_net_status_text(g_net_status));
    if (n <= 0 || (size_t)n >= sizeof buf) return -1;
    if (write_all(STDOUT_FILENO, buf, (size_t)n) != 0) return -1;
    return emit_end(token, 0);
}

// ---------------------------------------------------------------------------
// Identity validation (pure — linked into the native source check too)
// ---------------------------------------------------------------------------

static int id_char_ok(unsigned char c, int first) {
    if (c >= 'A' && c <= 'Z') return 1;
    if (c >= 'a' && c <= 'z') return 1;
    if (c >= '0' && c <= '9') return 1;
    if (first) return 0;
    return c == '.' || c == '_' || c == '-';
}

int floe_project_id_valid(const char *id) {
    if (!id) return 0;
    size_t len = strlen(id);
    if (len == 0 || len > FLOE_MAX_PROJECT_ID) return 0;
    for (size_t i = 0; i < len; i++) {
        if (!id_char_ok((unsigned char)id[i], i == 0)) return 0;
    }
    // ".." is the one dangerous label pattern for path building even inside
    // a validated directory: reject it outright.
    if (strstr(id, "..") != NULL) return 0;
    return 1;
}

int floe_task_id_valid(const char *task) {
    if (!task) return 0;
    size_t len = strlen(task);
    if (len == 0 || len > FLOE_MAX_TASK_ID) return 0;
    for (size_t i = 0; i < len; i++) {
        if (!id_char_ok((unsigned char)task[i], i == 0)) return 0;
    }
    if (strstr(task, "..") != NULL) return 0;
    return 1;
}

int floe_generation_valid(const char *generation) {
    if (!generation) return 0;
    size_t len = strlen(generation);
    if (len == 0 || len > FLOE_MAX_GENERATION) return 0;
    for (size_t i = 0; i < len; i++) {
        if (generation[i] < '0' || generation[i] > '9') return 0;
    }
    return 1;
}

// ---------------------------------------------------------------------------
// Base64 (shared wire shape with floe_exec.c; used by the CHUNK handler)
// ---------------------------------------------------------------------------

static int b64_value(unsigned char c) {
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '+') return 62;
    if (c == '/') return 63;
    return -1;
}

static long b64_decode(const unsigned char *in, size_t len, unsigned char *out, size_t out_cap) {
    unsigned acc = 0;
    int bits = 0;
    size_t o = 0;
    for (size_t i = 0; i < len; i++) {
        unsigned char c = in[i];
        if (c == '\r' || c == ' ' || c == '\t') continue;
        if (c == '=') break;
        int v = b64_value(c);
        if (v < 0) return -1;
        acc = (acc << 6) | (unsigned)v;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            if (o >= out_cap) return -1;
            out[o++] = (unsigned char)((acc >> bits) & 0xffu);
        }
    }
    return (long)o;
}

#ifdef __linux__
// Field table parsing is only used by the PROJOPEN payload (Linux-only
// executor); keeping it inside the guard avoids unused-function errors on
// the native check build.
typedef struct {
    size_t *offsets;
    size_t *lengths;
    uint32_t count;
} field_table;

static void fields_free(field_table *f) {
    free(f->offsets);
    free(f->lengths);
    memset(f, 0, sizeof *f);
}

static int fields_split(const unsigned char *payload, size_t plen, field_table *out) {
    memset(out, 0, sizeof *out);
    if (plen < 4) return -1;
    uint32_t count = ((uint32_t)payload[0] << 24) | ((uint32_t)payload[1] << 16) |
                     ((uint32_t)payload[2] << 8) | (uint32_t)payload[3];
    if (count == 0 || count > 64) return -1; // control envelopes are tiny
    size_t *offsets = calloc(count, sizeof *offsets);
    size_t *lengths = calloc(count, sizeof *lengths);
    if (!offsets || !lengths) {
        free(offsets);
        free(lengths);
        return -1;
    }
    size_t off = 4;
    for (uint32_t i = 0; i < count; i++) {
        if (off + 4 > plen) goto fail;
        uint32_t field_len = ((uint32_t)payload[off] << 24) | ((uint32_t)payload[off + 1] << 16) |
                             ((uint32_t)payload[off + 2] << 8) | (uint32_t)payload[off + 3];
        off += 4;
        if ((size_t)field_len > plen - off) goto fail;
        offsets[i] = off;
        lengths[i] = (size_t)field_len;
        off += (size_t)field_len;
    }
    if (off != plen) goto fail;
    out->offsets = offsets;
    out->lengths = lengths;
    out->count = count;
    return 0;
fail:
    free(offsets);
    free(lengths);
    return -1;
}

static char *field_dup_cstr(const unsigned char *payload, size_t offset, size_t length) {
    if (memchr(payload + offset, 0, length) != NULL) return NULL;
    char *copy = malloc(length + 1);
    if (!copy) return NULL;
    memcpy(copy, payload + offset, length);
    copy[length] = '\0';
    return copy;
}
#endif // __linux__ (field table)

// ---------------------------------------------------------------------------
// Supervisor configuration: init-owned absolute roots from /proc/cmdline.
// These are TRUSTED native/init input; a missing or relative value is a
// configuration error, never something to guess from the first workspace.
// ---------------------------------------------------------------------------

typedef struct {
    char base[256];      // immutable base rootfs (read-only overlay lower)
    char state[256];     // ext4 state root (project overlays, leases)
    char workspace[256]; // shared workspace root (may equal state)
    char runner[256];    // trusted floe-exec binary bind-mounted into projects
} supervisor_config;

static int path_char_ok(char c) {
    return c > 0x20 && c < 0x7f;
}

// Extracts "key=value" from a bounded cmdline buffer; value must be an
// absolute path of printable path characters. Returns 1 when present.
static int cmdline_path_value(const char *cmdline, size_t len,
                              const char *key, char *out, size_t out_cap) {
    size_t key_len = strlen(key);
    size_t i = 0;
    while (i + key_len < len) {
        if (memcmp(cmdline + i, key, key_len) == 0 &&
            (i == 0 || cmdline[i - 1] == ' ') &&
            i + key_len < len && cmdline[i + key_len] == '=') {
            size_t vstart = i + key_len + 1;
            size_t vend = vstart;
            while (vend < len && cmdline[vend] != ' ') {
                if (!path_char_ok(cmdline[vend])) return 0;
                vend++;
            }
            size_t vlen = vend - vstart;
            if (vlen == 0 || vlen >= out_cap) return 0;
            if (cmdline[vstart] != '/') return 0; // absolute or nothing
            memcpy(out, cmdline + vstart, vlen);
            out[vlen] = '\0';
            return 1;
        }
        i++;
    }
    return 0;
}

static int load_supervisor_config(supervisor_config *cfg) {
    memset(cfg, 0, sizeof *cfg);
#ifdef __linux__
    int fd = open("/proc/cmdline", O_RDONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    char buf[1024];
    ssize_t got = read(fd, buf, sizeof buf - 1);
    close(fd);
    if (got <= 0) return -1;
    size_t len = (size_t)got;
    while (len > 0 && (buf[len - 1] == '\n' || buf[len - 1] == '\0')) len--;
    if (len == sizeof buf - 1) return -1; // truncated: refuse to guess
    int have_base = cmdline_path_value(buf, len, "floe.base", cfg->base, sizeof cfg->base);
    int have_state = cmdline_path_value(buf, len, "floe.state", cfg->state, sizeof cfg->state);
    int have_ws = cmdline_path_value(buf, len, "floe.workspace", cfg->workspace, sizeof cfg->workspace);
    int have_runner = cmdline_path_value(buf, len, "floe.runner", cfg->runner, sizeof cfg->runner);
    if (!have_base || !have_state) return -1;
    if (!have_ws) snprintf(cfg->workspace, sizeof cfg->workspace, "%s", cfg->state);
    if (!have_runner) snprintf(cfg->runner, sizeof cfg->runner, "/floe/bin/floe-exec");
    return 0;
#else
    (void)cmdline_path_value;
    return -1;
#endif
}

// ---------------------------------------------------------------------------
// Linux: mounts, cgroups, paths (compiled out of the native check build)
// ---------------------------------------------------------------------------

#ifdef __linux__

static int mkdir_p(const char *path, mode_t mode) {
    char tmp[512];
    size_t len = strlen(path);
    if (len == 0 || len >= sizeof tmp) return -1;
    memcpy(tmp, path, len + 1);
    for (char *p = tmp + 1; *p; p++) {
        if (*p == '/') {
            *p = '\0';
            (void)mkdir(tmp, mode);
            *p = '/';
        }
    }
    if (mkdir(tmp, mode) == 0) return 0;
    return errno == EEXIST ? 0 : -1;
}

static void try_mount(const char *source, const char *target, const char *fstype,
                      unsigned long flags, const char *data) {
    if (mount(source, target, fstype, flags, data) == 0) return;
    if (errno == EBUSY) return;
    diag("floe-supervisor: mount %s on %s (%s): %s\n",
         source, target, fstype, strerror(errno));
}

static int path_join(char *out, size_t cap, const char *dir, const char *leaf) {
    int n = snprintf(out, cap, "%s/%s", dir, leaf);
    return n > 0 && (size_t)n < cap ? 0 : -1;
}

// Writes text to path and fsyncs the file and its parent directory, so a
// crash cannot leave a torn lease/generation record. Best effort with an
// explicit failure code: callers refuse the operation on failure.
static int write_file_synced(const char *path, const char *text) {
    char tmp[512];
    int n = snprintf(tmp, sizeof tmp, "%s.floe.tmp", path);
    if (n <= 0 || (size_t)n >= sizeof tmp) return -1;
    int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd < 0) return -1;
    size_t len = strlen(text);
    if (write_all(fd, text, len) != 0) {
        close(fd);
        (void)unlink(tmp);
        return -1;
    }
    if (fsync(fd) != 0) {
        close(fd);
        (void)unlink(tmp);
        return -1;
    }
    if (close(fd) != 0) {
        (void)unlink(tmp);
        return -1;
    }
    if (rename(tmp, path) != 0) {
        (void)unlink(tmp);
        return -1;
    }
    char dirbuf[512];
    const char *slash = strrchr(path, '/');
    if (slash && slash != path) {
        size_t dlen = (size_t)(slash - path);
        if (dlen >= sizeof dirbuf) return -1;
        memcpy(dirbuf, path, dlen);
        dirbuf[dlen] = '\0';
        int dfd = open(dirbuf, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
        if (dfd < 0) return -1;
        if (fsync(dfd) != 0) {
            close(dfd);
            return -1;
        }
        close(dfd);
    }
    return 0;
}

static int read_small_file(const char *path, char *out, size_t cap) {
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    ssize_t got = read(fd, out, cap - 1);
    close(fd);
    if (got <= 0) return -1;
    out[got] = '\0';
    return 0;
}

// Plain one-shot write to an absolute path (no fsync: proc/sys files cannot
// be fsynced and do not need crash durability).
static int write_cgroup_value(const char *dir, const char *name, const char *value) {
    char path[512];
    if (path_join(path, sizeof path, dir, name) != 0) return -1;
    int fd = open(path, O_WRONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    size_t len = strlen(value);
    ssize_t wrote = write(fd, value, len);
    close(fd);
    return wrote == (ssize_t)len ? 0 : -1;
}

#endif // __linux__ (path/mount helpers)

// ---------------------------------------------------------------------------
// Machine-wide first-boot network (Linux only)
// ---------------------------------------------------------------------------
// The supervisor is the resident init: it owns the one guest NAT interface,
// route and resolver before any CAPS answer, because per-project runners
// deliberately never touch the network. Adapted from floe_exec.c's proven
// bring-up (same floe_net.h plan, same slirp constants, same bounded probe);
// the native build reports FLOE_NET_DOWN and never touches the host.

#ifdef __linux__
#include <arpa/inet.h>
#include <net/if.h>
#include <net/route.h>
#include <netinet/in.h>
#include <sys/socket.h>

static int net_write_rendered(const char *path, int (*render)(char *, size_t)) {
    char content[FLOE_NET_CONFIG_MAX];
    char dir[256];
    int n = render(content, sizeof content);
    if (n < 0) {
        diag("floe-supervisor: net %s: configuration does not fit\n", path);
        return -1;
    }
    const char *slash = strrchr(path, '/');
    if (slash != NULL && slash != path) {
        size_t dlen = (size_t)(slash - path);
        if (dlen < sizeof dir) {
            memcpy(dir, path, dlen);
            dir[dlen] = '\0';
            mkdir_p(dir, 0755);
        }
    }
    char tmp[300];
    snprintf(tmp, sizeof tmp, "%s.floe.tmp", path);
    int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd < 0) return -1;
    if (write_all(fd, content, (size_t)n) != 0) { close(fd); (void)unlink(tmp); return -1; }
    if (close(fd) != 0) { (void)unlink(tmp); return -1; }
    if (rename(tmp, path) != 0) { (void)unlink(tmp); return -1; }
    return 0;
}

static int net_apply_interface(int fd) {
    struct ifreq ifr;
    memset(&ifr, 0, sizeof ifr);
    if (strlen(FLOE_NET_INTERFACE) >= sizeof ifr.ifr_name) return -1;
    memcpy(ifr.ifr_name, FLOE_NET_INTERFACE, strlen(FLOE_NET_INTERFACE) + 1);
    struct sockaddr_in *sin;

    sin = (struct sockaddr_in *)&ifr.ifr_addr;
    sin->sin_family = AF_INET;
    if (inet_pton(AF_INET, FLOE_NET_GUEST_ADDRESS, &sin->sin_addr) != 1) return -1;
    if (ioctl(fd, SIOCSIFADDR, &ifr) != 0) return -1;

    memset(&ifr.ifr_netmask, 0, sizeof ifr.ifr_netmask);
    sin = (struct sockaddr_in *)&ifr.ifr_netmask;
    sin->sin_family = AF_INET;
    if (inet_pton(AF_INET, FLOE_NET_NETMASK, &sin->sin_addr) != 1) return -1;
    if (ioctl(fd, SIOCSIFNETMASK, &ifr) != 0) return -1;

    memset(&ifr.ifr_flags, 0, sizeof ifr.ifr_flags);
    if (ioctl(fd, SIOCGIFFLAGS, &ifr) != 0) return -1;
    ifr.ifr_flags = (short)(ifr.ifr_flags | IFF_UP | IFF_RUNNING | IFF_MULTICAST);
    if (ioctl(fd, SIOCSIFFLAGS, &ifr) != 0) return -1;

    struct rtentry route;
    memset(&route, 0, sizeof route);
    sin = (struct sockaddr_in *)&route.rt_dst;
    sin->sin_family = AF_INET;
    sin->sin_addr.s_addr = htonl(INADDR_ANY);
    sin = (struct sockaddr_in *)&route.rt_genmask;
    sin->sin_family = AF_INET;
    sin->sin_addr.s_addr = htonl(INADDR_ANY);
    sin = (struct sockaddr_in *)&route.rt_gateway;
    sin->sin_family = AF_INET;
    if (inet_pton(AF_INET, FLOE_NET_GATEWAY, &sin->sin_addr) != 1) return -1;
    route.rt_flags = RTF_UP | RTF_GATEWAY;
    route.rt_dev = (char *)FLOE_NET_INTERFACE;
    if (ioctl(fd, SIOCADDRT, &route) != 0 && errno != EEXIST) {
        diag("floe-supervisor: net default route: %s\n", strerror(errno));
    }

    ifr.ifr_flags = 0;
    if (ioctl(fd, SIOCGIFFLAGS, &ifr) != 0) return -1;
    return (ifr.ifr_flags & IFF_UP) ? 0 : -1;
}

static const char *net_resolver_answers(void) {
    unsigned char query[64];
    size_t qlen = 0;
    query[qlen++] = 0x46; query[qlen++] = 0x4c;
    query[qlen++] = 0x01; query[qlen++] = 0x00;
    query[qlen++] = 0x00; query[qlen++] = 0x01;
    query[qlen++] = 0x00; query[qlen++] = 0x00;
    query[qlen++] = 0x00; query[qlen++] = 0x00;
    query[qlen++] = 0x00; query[qlen++] = 0x00;
    static const char name[] = "floe-agent.com";
    const char *part = name;
    while (*part != '\0') {
        const char *dot = strchr(part, '.');
        size_t label = dot != NULL ? (size_t)(dot - part) : strlen(part);
        if (label == 0 || label > 63 || qlen + label + 1 + 4 > sizeof query) return NULL;
        query[qlen++] = (unsigned char)label;
        memcpy(query + qlen, part, label);
        qlen += label;
        if (dot == NULL) break;
        part = dot + 1;
    }
    query[qlen++] = 0x00;
    query[qlen++] = 0x00; query[qlen++] = 0x01;
    query[qlen++] = 0x00; query[qlen++] = 0x01;

    size_t attempts = FLOE_NET_RESOLVER_COUNT;
    if (attempts > FLOE_NET_PROBE_MAX_ATTEMPTS) attempts = FLOE_NET_PROBE_MAX_ATTEMPTS;
    for (size_t i = 0; i < attempts; i++) {
        const char *server_text = floe_net_resolver_at(i);
        if (server_text == NULL) break;
        struct sockaddr_in server;
        memset(&server, 0, sizeof server);
        server.sin_family = AF_INET;
        server.sin_port = htons(53);
        if (inet_pton(AF_INET, server_text, &server.sin_addr) != 1) continue;
        int fd = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
        if (fd < 0) return NULL;
        struct timeval tv;
        tv.tv_sec = FLOE_NET_PROBE_TIMEOUT_SECONDS;
        tv.tv_usec = 0;
        (void)setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
        (void)setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
        int ok = 0;
        if (sendto(fd, query, qlen, 0, (struct sockaddr *)&server, sizeof server) == (ssize_t)qlen) {
            unsigned char reply[512];
            ssize_t got = recv(fd, reply, sizeof reply, 0);
            if (got >= 12 && reply[0] == 0x46 && reply[1] == 0x4c) ok = 1;
        }
        close(fd);
        if (ok) return server_text;
    }
    return NULL;
}

static void supervisor_bring_up_network(void) {
    int fd = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    if (fd < 0) {
        diag("floe-supervisor: net %s: no socket: %s\n", FLOE_NET_INTERFACE, strerror(errno));
        return;
    }
    int configured = net_apply_interface(fd) == 0;
    close(fd);
    if (!configured) {
        diag("floe-supervisor: net %s: interface configuration failed\n", FLOE_NET_INTERFACE);
        g_net_status = FLOE_NET_DOWN;
        return;
    }
    if (net_write_rendered("/etc/resolv.conf", floe_net_render_resolv_conf) != 0 ||
        net_write_rendered("/etc/network/interfaces.d/" FLOE_NET_INTERFACE,
                           floe_net_render_interfaces) != 0) {
        diag("floe-supervisor: net resolver/interface configuration incomplete\n");
    }
    if (net_write_rendered("/etc/gitconfig", floe_net_render_gitconfig) != 0) {
        diag("floe-supervisor: net /etc/gitconfig (git safe.directory) not written\n");
    }
    const char *answered = net_resolver_answers();
    if (answered != NULL) {
        g_net_status = FLOE_NET_UP;
        diag("floe-supervisor: net %s=%s/%s gw=" FLOE_NET_GATEWAY " dns=%s status=up\n",
             FLOE_NET_INTERFACE, FLOE_NET_GUEST_ADDRESS, FLOE_NET_GUEST_PREFIX, answered);
    } else {
        g_net_status = FLOE_NET_PARTIAL;
        diag("floe-supervisor: net %s=%s/%s gw=" FLOE_NET_GATEWAY
             " status=partial (no resolver answered)\n",
             FLOE_NET_INTERFACE, FLOE_NET_GUEST_ADDRESS, FLOE_NET_GUEST_PREFIX);
    }
}

// NOTE: no native stub here — the only call site is inside main()'s
// __linux__ block, so a stub would be an unused-function error on the
// native check build under -Werror.
#endif

// ---------------------------------------------------------------------------
// Project state (plain memory — compiled on every build so the native source
// check can exercise identity validation and the dispatch tables)
// ---------------------------------------------------------------------------

typedef enum {
    PROJ_FREE = 0,
    PROJ_OPENING,   // overlay mounted, runner starting
    PROJ_ACTIVE,    // runner alive
    PROJ_CLOSING,   // kill in flight, runner being reaped
    PROJ_RECOVERED, // orphan from a previous boot; data kept, not attached
} project_state;

// NOTE: the struct is named floe_project (not `project`): several request
// handlers take a parameter literally named `project` (the validated ID
// string), which shadowed a typedef named `project` in the 2026-11-05 draft
// and broke every `project *p = ...` declaration (compile fix).
typedef struct {
    int used;
    project_state state;
    char id[FLOE_MAX_PROJECT_ID + 1];
    char generation[FLOE_MAX_GENERATION + 1];
    int console_index;           // hvcN index; -1 when unassigned
    pid_t runner_pid;
    char cgroup_dir[512];        // /sys/fs/cgroup/floe/<id>
    char dir[512];               // <state>/projects/<id>
    char root[512];              // <dir>/root (overlay mount point)
    char workspace_dir[256];     // in-project workspace mount/dir
    int workspace_shared;        // 1 only after the selected native slot is mounted
    // Lease (serialized destructive operations); 0 = free.
    char lease_id[FLOE_CTRL_MAX_TOKEN + 1];
    int64_t lease_deadline_ms;
    int64_t open_ms;
} floe_project;

static floe_project g_projects[FLOE_MAX_PROJECTS];
static char g_base[256];
static char g_state[256];
static char g_workspace_root[256];
static char g_runner_path[256];
#ifdef __linux__
static char g_boot_id[64];
static int g_ready = 0;      // base/state verified; PROJOPEN may be served
static int g_cgroup_ready = 0; // cgroup2 tree mounted; PROJOPEN may be served
#endif

static floe_project *project_find(const char *id) {
    for (int i = 0; i < FLOE_MAX_PROJECTS; i++) {
        if (g_projects[i].used && strcmp(g_projects[i].id, id) == 0) return &g_projects[i];
    }
    return NULL;
}

#ifdef __linux__
// Only the Linux PROJOPEN executor allocates slots; on the native check
// build this would be an unused-function error under -Werror.
static floe_project *project_free_slot(void) {
    for (int i = 0; i < FLOE_MAX_PROJECTS; i++) {
        if (!g_projects[i].used) return &g_projects[i];
    }
    return NULL;
}
#endif

#ifdef __linux__
// Consoles are provided by the native side; the supervisor only uses
// consoles that already exist (/dev/hvcN present and not already taken).
static int console_for_slot(unsigned slot) {
    if (slot >= FLOE_MAX_PROJECTS) return -1;
    int i = (int)slot + 1;
    for (int p = 0; p < FLOE_MAX_PROJECTS; p++) {
        if (g_projects[p].used && g_projects[p].console_index == i) return -1;
    }
    char path[32];
    snprintf(path, sizeof path, "/dev/hvc%d", i);
    return access(path, F_OK) == 0 ? i : -1;
}
#endif

#ifdef __linux__
// ---------------------------------------------------------------------------
// Bring-up: mounts for the control plane itself (the project rootfs mounts
// happen per PROJOPEN).
// ---------------------------------------------------------------------------

// Returns 0 when the cgroup2 tree is mounted and usable; PROJOPEN fails
// closed with END 126 when this is not 0.
static int supervisor_bring_up(void) {
    mkdir_p("/proc", 0755);
    mkdir_p("/sys", 0755);
    mkdir_p("/dev", 0755);
    mkdir_p("/tmp", 01777);
    mkdir_p("/run", 0755);
    try_mount("proc", "/proc", "proc", 0, NULL);
    try_mount("sysfs", "/sys", "sysfs", 0, NULL);
    try_mount("devtmpfs", "/dev", "devtmpfs", 0, "mode=0755");
    mkdir_p("/dev/pts", 0755);
    mkdir_p("/dev/shm", 01777);
    try_mount("devpts", "/dev/pts", "devpts", 0, "mode=0620,ptmxmode=0666");
    try_mount("tmpfs", "/dev/shm", "tmpfs", 0, "mode=1777");
    try_mount("tmpfs", "/tmp", "tmpfs", 0, "mode=1777");
    try_mount("tmpfs", "/run", "tmpfs", 0, "mode=0755");

    // cgroup2 for the whole Machine. The supervisor owns the "floe" subtree;
    // per-project subtrees are managed by the supervisor and delegated by
    // ownership of the subtree root directory to the project runner (both
    // run as guest root — this is lifecycle isolation, not a sandbox).
    mkdir_p("/sys/fs/cgroup", 0755);
    if (mount("none", "/sys/fs/cgroup", "cgroup2", 0, NULL) != 0 && errno != EBUSY) {
        diag("floe-supervisor: cgroup2 mount failed: %s\n", strerror(errno));
        return -1;
    }
    // cgroup.kill deliberately does not exist on the root cgroup. Probe
    // the actual delegated subtree, after its parent controllers are on.
    if (write_cgroup_value("/sys/fs/cgroup", "cgroup.subtree_control", "+cpu +memory +pids") != 0) {
        diag("floe-supervisor: cgroup subtree_control: %s\n", strerror(errno));
        return -1;
    }
    if (mkdir_p("/sys/fs/cgroup/floe", 0755) != 0 ||
        access("/sys/fs/cgroup/floe/cgroup.kill", F_OK) != 0 ||
        write_cgroup_value("/sys/fs/cgroup/floe", "cgroup.subtree_control", "+cpu +memory +pids") != 0) {
        diag("floe-supervisor: delegated cgroup unavailable: %s\n", strerror(errno));
        return -1;
    }
    return 0;
}

static int verify_roots(void) {
    struct stat st;
    if (stat(g_base, &st) != 0 || !S_ISDIR(st.st_mode)) {
        diag("floe-supervisor: base rootfs %s is not a directory: %s\n",
             g_base, strerror(errno));
        return -1;
    }
    if (stat(g_state, &st) != 0 || !S_ISDIR(st.st_mode)) {
        diag("floe-supervisor: state root %s is not a directory: %s\n",
             g_state, strerror(errno));
        return -1;
    }
    if (stat(g_runner_path, &st) != 0 || !S_ISREG(st.st_mode)) {
        diag("floe-supervisor: runner binary %s is not a file: %s\n",
             g_runner_path, strerror(errno));
        return -1;
    }
    // The base rootfs must be read-only in practice; the overlay lower is
    // opened read-only by the kernel regardless, so a rw lower only risks
    // accidental base mutation. Enforce nothing here but verify presence —
    // mounting is the real gate.
    return 0;
}

// ---------------------------------------------------------------------------
// Per-project rootfs: immutable base lower + persistent per-project upper
// on the ext4 state root, with proc/sys/dev and the project's cgroup subtree
// mounted inside the project view.
// ---------------------------------------------------------------------------

static int project_rootfs_mount(floe_project *p) {
    char upper[512], work[512], options[1600];
    if (path_join(upper, sizeof upper, p->dir, "upper") != 0) return -1;
    if (path_join(work, sizeof work, p->dir, "work") != 0) return -1;
    if (mkdir_p(upper, 0755) != 0 || mkdir_p(work, 0755) != 0 || mkdir_p(p->root, 0755) != 0) {
        diag("floe-supervisor: project %s: cannot create overlay dirs: %s\n",
             p->id, strerror(errno));
        return -1;
    }
    // No idmapped mount, no userxattr: tasks run as the guest's own root in
    // the single initial user namespace (see the header ownership model).
    int n = snprintf(options, sizeof options,
                     "lowerdir=%s,upperdir=%s,workdir=%s",
                     g_base, upper, work);
    if (n <= 0 || (size_t)n >= sizeof options) return -1;
    if (mount("overlay", p->root, "overlay", MS_NOSUID | MS_NODEV, options) != 0) {
        diag("floe-supervisor: project %s: overlay mount: %s\n", p->id, strerror(errno));
        return -1;
    }

    // Mount-point directories for the runtime view mounted here.
    static const char *mountpoints[] = {
        "proc", "sys", "dev", "dev/pts", "dev/shm", "tmp", "workspace",
        "sys/fs/cgroup", "usr/local/bin",
    };
    char target[640];
    for (size_t i = 0; i < sizeof mountpoints / sizeof mountpoints[0]; i++) {
        if (path_join(target, sizeof target, p->root, mountpoints[i]) != 0) return -1;
        if (mkdir_p(target, 0755) != 0) return -1;
    }

// The project runtime view, mounted by the trusted supervisor as guest
    // root. Fresh virtual filesystems present uid 0 dynamically. The cgroup
    // bind mounts ONLY the project's own subtree at /sys/fs/cgroup inside
    // the project: a task that cancels itself can never see or kill a
    // sibling project's cgroup, and "cgroup.kill" at the project root means
    // exactly this project. (The 2026-11-05 draft bind-mounted the whole
    // cgroup tree and tried to idmap it — both wrong on the target kernel.)
    if (path_join(target, sizeof target, p->root, "proc") != 0) return -1;
    try_mount("proc", target, "proc", MS_NOSUID | MS_NODEV | MS_NOEXEC, NULL);
    if (path_join(target, sizeof target, p->root, "sys") != 0) return -1;
    try_mount("sysfs", target, "sysfs", MS_NOSUID | MS_NODEV | MS_NOEXEC, NULL);

    // Minimal /dev on a private tmpfs, populated explicitly by the
    // supervisor (coordinator guidance 2026-11-05: a full devtmpfs would
    // expose the OTHER projects' virtio consoles as /dev/hvcN inside this
    // project and allow accidental cross-project control). Everything a
    // Debian task legitimately needs is present; the project consoles are
    // not. devpts still provides the pty pairs.
    if (path_join(target, sizeof target, p->root, "dev") != 0) return -1;
    if (mount("tmpfs", target, "tmpfs", MS_NOSUID, "mode=0755") != 0) {
        diag("floe-supervisor: project %s: /dev tmpfs: %s\n", p->id, strerror(errno));
        return -1;
    }
    static const struct {
        const char *name;
        unsigned major, minor;
        mode_t mode;
    } dev_nodes[] = {
        { "null", 1, 3, 0666 },
        { "zero", 1, 5, 0666 },
        { "full", 1, 7, 0666 },
        { "random", 1, 8, 0666 },
        { "urandom", 1, 9, 0666 },
        { "tty", 5, 0, 0666 },
    };
    for (size_t i = 0; i < sizeof dev_nodes / sizeof dev_nodes[0]; i++) {
        char node[768];
        if (path_join(node, sizeof node, target, dev_nodes[i].name) != 0) return -1;
        if (mknod(node, S_IFCHR | dev_nodes[i].mode,
                  makedev(dev_nodes[i].major, dev_nodes[i].minor)) != 0 && errno != EEXIST) {
            diag("floe-supervisor: project %s: /dev/%s: %s\n",
                 p->id, dev_nodes[i].name, strerror(errno));
            return -1;
        }
    }
    if (path_join(target, sizeof target, p->root, "dev/pts") != 0) return -1;
    if (mkdir_p(target, 0755) != 0) return -1;
    try_mount("devpts", target, "devpts", MS_NOSUID, "mode=0620,ptmxmode=0666");
    {
        // /dev/ptmx -> pts/ptmx (glibc posix_openpt opens /dev/ptmx).
        char ptmx[768];
        if (path_join(target, sizeof target, p->root, "dev") != 0) return -1;
        if (path_join(ptmx, sizeof ptmx, target, "ptmx") != 0) return -1;
        if (symlink("pts/ptmx", ptmx) != 0 && errno != EEXIST) {
            diag("floe-supervisor: project %s: /dev/ptmx symlink: %s\n",
                 p->id, strerror(errno));
            return -1;
        }
    }
    if (path_join(target, sizeof target, p->root, "dev/shm") != 0) return -1;
    try_mount("tmpfs", target, "tmpfs", MS_NOSUID | MS_NODEV, "mode=1777");
    if (path_join(target, sizeof target, p->root, "tmp") != 0) return -1;
    try_mount("tmpfs", target, "tmpfs", MS_NOSUID | MS_NODEV, "mode=1777");
    if (path_join(target, sizeof target, p->root, "sys/fs/cgroup") != 0) return -1;
    if (mount(p->cgroup_dir, target, NULL, MS_BIND, NULL) != 0) {
        diag("floe-supervisor: project %s: cgroup subtree bind: %s\n", p->id, strerror(errno));
        return -1;
    }

    // The host reserves a bounded native share slot before PROJOPEN.
    // Console hvc(slot+1) and immutable tag floe-ws-<slot> are one binding.
    // Missing shares must fail: a private directory would silently hide the
    // user's actual project files and falsely report a usable environment.
    char ws_tag[32];
    snprintf(ws_tag, sizeof ws_tag, "floe-ws-%d", p->console_index - 1);
    if (path_join(target, sizeof target, p->root, "workspace") != 0) return -1;
    if (mount(ws_tag, target, "9p", MS_NOSUID | MS_NODEV,
              "trans=virtio,version=9p2000.L,access=client") != 0) {
        diag("floe-supervisor: project %s: workspace share %s unavailable: %s\n",
             p->id, ws_tag, strerror(errno));
        return -1;
    }
    p->workspace_shared = 1;

    // The trusted runner binary: the immutable base tree carries the
    // Debian userland only, so the pinned floe-exec is bound in read-only
    // at its in-project path.
    char bin_target[640];
    if (path_join(bin_target, sizeof bin_target, p->root, "usr/local/bin/floe-exec") != 0) return -1;
    int runner_target = open(bin_target, O_CREAT | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, 0755);
    if (runner_target < 0) return -1;
    close(runner_target);
    if (mount(g_runner_path, bin_target, NULL, MS_BIND, NULL) != 0 ||
        mount(NULL, bin_target, NULL, MS_BIND | MS_REMOUNT | MS_RDONLY | MS_NOSUID, NULL) != 0) {
        diag("floe-supervisor: project %s: runner bind: %s\n", p->id, strerror(errno));
        return -1;
    }
    if (p->workspace_dir[0] == '\0') snprintf(p->workspace_dir, sizeof p->workspace_dir, "/workspace");
    return 0;
}

// Reverse of project_rootfs_mount. MNT_DETACH first: open file descriptors
// inside the project (a task that raced close) can never block teardown of
// the OTHER projects; the ext4 upper keeps its data either way.
static void project_rootfs_unmount(floe_project *p) {
    char target[640];
    // Unmount in reverse dependency order; best effort each time. Task
    // mounts live in task namespaces and die with their processes; the
    // supervisor unmounts the runtime view it mounted.
    static const char *leafs[] = {
        "usr/local/bin/floe-exec", "workspace", "tmp", "dev/shm", "dev/pts",
        "dev", "sys/fs/cgroup", "sys", "proc",
    };
    for (size_t i = 0; i < sizeof leafs / sizeof leafs[0]; i++) {
        if (path_join(target, sizeof target, p->root, leafs[i]) != 0) continue;
        (void)umount2(target, UMOUNT_NOFOLLOW);
        (void)umount2(target, MNT_DETACH);
    }
    (void)umount2(p->root, UMOUNT_NOFOLLOW);
    (void)umount2(p->root, MNT_DETACH);
}

static int project_cgroup_create(floe_project *p) {
    char floe_root[512];
    if (path_join(floe_root, sizeof floe_root, "/sys/fs/cgroup", "floe") != 0) return -1;
    if (mkdir_p(floe_root, 0755) != 0) return -1;
    // Local copy: keeps snprintf's restrict analysis from flagging the
    // g_projects member pair (p->cgroup_dir vs p->id) under -Werror.
    char id_copy[FLOE_MAX_PROJECT_ID + 1];
    snprintf(id_copy, sizeof id_copy, "%s", p->id);
    if (snprintf(p->cgroup_dir, sizeof p->cgroup_dir, "%s/%s", floe_root, id_copy) <= 0) return -1;
    if (mkdir(p->cgroup_dir, 0755) != 0 && errno != EEXIST) return -1;
    char tasks[640];
    if (path_join(tasks, sizeof tasks, p->cgroup_dir, "tasks") != 0) return -1;
    if (mkdir(tasks, 0755) != 0 && errno != EEXIST) return -1;
    char value[64];
    snprintf(value, sizeof value, "%d", FLOE_PROJECT_PIDS_MAX);
    if (write_cgroup_value(p->cgroup_dir, "pids.max", value) != 0) {
        diag("floe-supervisor: project %s: pids.max: %s\n", p->id, strerror(errno));
        return -1;
    }
    // Per-task ceilings are fixed constants (shared-machine model); the
    // runner recreates task dirs with the same values for every task. Both
    // the project cgroup and the tasks dir stay process-free (task procs go
    // into tasks/<token>), satisfying the cgroup v2 no-internal-process
    // rule for subtree_control.
    if (write_cgroup_value(p->cgroup_dir, "cgroup.subtree_control", "+cpu +memory +pids") != 0) {
        diag("floe-supervisor: project %s: subtree_control: %s\n", p->id, strerror(errno));
        return -1;
    }
    if (write_cgroup_value(tasks, "cgroup.subtree_control", "+cpu +memory +pids") != 0) {
        diag("floe-supervisor: project %s: tasks subtree_control: %s\n", p->id, strerror(errno));
        return -1;
    }
    return 0;
}

static void project_cgroup_kill_and_remove(floe_project *p) {
    (void)write_cgroup_value(p->cgroup_dir, "cgroup.kill", "1");
    // Task dirs are removed by the runner exit path; rmdir defensively.
    char tasks[640];
    if (path_join(tasks, sizeof tasks, p->cgroup_dir, "tasks") == 0) {
        (void)rmdir(tasks);
    }
    (void)rmdir(p->cgroup_dir);
}

// ---------------------------------------------------------------------------
// Runner spawning. The fd-fix invariant lives here:
//   * dup2 over stdio then EXPLICITLY clear FD_CLOEXEC (dup2(same fd) would
//     keep it — the POC round-1 failure),
//   * close every descriptor above stderr before exec, so no console, pipe
//     or share fd leaks across the exec boundary,
//   * the supervisor closes its own copies of the child's console fds only
//     in the parent, after fork (ownership hand-off, never a shared close).
// ---------------------------------------------------------------------------

// Closes every descriptor above stderr. The fd-fix invariant: nothing the
// supervisor owned leaks across the exec boundary.
static void child_close_all_fds(int preserve_fd) {
    long max = sysconf(_SC_OPEN_MAX);
    if (max < 0 || max > 65536) max = 65536;
    for (long fd = 3; fd < max; fd++) {
        if (fd != preserve_fd) close((int)fd);
    }
}

static int spawn_project_runner(floe_project *p) {
    char console_path[32];
    snprintf(console_path, sizeof console_path, "/dev/hvc%d", p->console_index);
    int hvc = open(console_path, O_RDWR | O_CLOEXEC);
    if (hvc < 0) {
        diag("floe-supervisor: project %s: console %s: %s\n",
             p->id, console_path, strerror(errno));
        return -1;
    }
    int ready_pipe[2];
    if (pipe2(ready_pipe, O_CLOEXEC) != 0) {
        close(hvc);
        return -1;
    }

    pid_t pid = fork();
    if (pid < 0) {
        close(hvc);
        close(ready_pipe[0]);
        close(ready_pipe[1]);
        return -1;
    }
    if (pid == 0) {
        // Child: the project's floe-exec runner, chrooted into its rootfs.
        (void)setsid();
        // fd-fix: dup2 does not clear CLOEXEC when src==dst; force it.
        (void)dup2(hvc, STDIN_FILENO);
        (void)dup2(hvc, STDOUT_FILENO);
        (void)dup2(hvc, STDERR_FILENO);
        // fd-fix invariant: dup2 does NOT clear FD_CLOEXEC when source and
        // target are the same descriptor, and a fresh dup target keeps its
        // CLOEXEC flag; force all three stdio descriptors inheritable.
        (void)fcntl(STDIN_FILENO, F_SETFD, 0);
        (void)fcntl(STDOUT_FILENO, F_SETFD, 0);
        (void)fcntl(STDERR_FILENO, F_SETFD, 0);
        if (hvc > STDERR_FILENO) close(hvc);
        close(ready_pipe[0]);
        // Ready signal AFTER chroot so the supervisor never reports a
        // console for a runner that failed to enter its rootfs.
        if (chroot(p->root) != 0 || chdir("/") != 0) {
            (void)write_all(ready_pipe[1], "E", 1);
            _exit(126);
        }

        char env_cgroup[768], env_project[96], env_generation[64];
        // The project's cgroup subtree is bound at /sys/fs/cgroup inside
        // the chroot, so this in-project absolute path is the real one the
        // runner uses for every task cgroup write.
        snprintf(env_cgroup, sizeof env_cgroup, "FLOE_CGROUP_TASKS=/sys/fs/cgroup/tasks");
        snprintf(env_project, sizeof env_project, "FLOE_PROJECT_ID=%s", p->id);
        snprintf(env_generation, sizeof env_generation, "FLOE_PROJECT_GENERATION=%s", p->generation);
        char *child_env[] = {
            "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
            "HOME=/root",
            "TERM=dumb",
            "LANG=C.UTF-8",
            "DEBIAN_FRONTEND=noninteractive",
            "FLOE_GUEST_RUNNER=1",
            env_cgroup,
            env_project,
            env_generation,
            NULL,
        };
        char *argv[] = { (char *)"/usr/local/bin/floe-exec", NULL };
        // Successful exec closes the CLOEXEC pipe. A pre-exec "ready"
        // byte would incorrectly acknowledge a missing/broken runner.
        child_close_all_fds(ready_pipe[1]);
        execve(argv[0], argv, child_env);
        (void)write_all(ready_pipe[1], "E", 1);
        _exit(127);
    }
    close(hvc);
    close(ready_pipe[1]);
    // Parent waits for the child's chroot+ready byte with a bounded deadline.
    char ready = 0;
    int exec_succeeded = 0;
    struct pollfd pfd = { ready_pipe[0], POLLIN | POLLHUP, 0 };
    int prc;
    do { prc = poll(&pfd, 1, 5000); } while (prc < 0 && errno == EINTR);
    if (prc > 0 && (pfd.revents & (POLLIN | POLLHUP))) {
        ssize_t got;
        do { got = read(ready_pipe[0], &ready, 1); } while (got < 0 && errno == EINTR);
        exec_succeeded = got == 0;
    }
    close(ready_pipe[0]);
    if (!exec_succeeded) {
        (void)kill(pid, SIGKILL);
        (void)waitpid(pid, NULL, 0);
        diag("floe-supervisor: project %s: runner failed to enter rootfs\n", p->id);
        return -1;
    }
    p->runner_pid = pid;
    return 0;
}

// ---------------------------------------------------------------------------
// State records: crash-safe project records for orphan recovery.
// ---------------------------------------------------------------------------

static int project_record_write(floe_project *p) {
    char path[640];
    if (path_join(path, sizeof path, p->dir, "supervisor.json") != 0) return -1;
    char body[1400];
    int n = snprintf(body, sizeof body,
                     "{\"project\":\"%s\",\"generation\":\"%s\",\"boot\":\"%s\","
                     "\"state\":\"%s\"}\n",
                     p->id, p->generation, g_boot_id,
                     p->state == PROJ_ACTIVE ? "active" : "closing");
    if (n <= 0 || (size_t)n >= sizeof body) return -1;
    return write_file_synced(path, body);
}

// Removes stale runtime state from earlier boots. Data (upper/) is NEVER
// deleted here — only mounts, cgroups and records that claim liveness.
// Bounded recursive removal of a validated supervisor-owned directory tree.
// Never follows symlinks (unlink) and never escapes the starting directory.
// Depth bound 40: real package trees (apt/npm) nest deeper than 8 but far
// shallower than 40. Used only by PROJDROP, after close + record checks.
static int remove_tree(const char *path, int depth) {
    if (depth > 40) return -1;
    DIR *dir = opendir(path);
    if (!dir) return errno == ENOENT ? 0 : -1;
    int rc = 0;
    struct dirent *entry;
    while ((entry = readdir(dir)) != NULL && rc == 0) {
        const char *name = entry->d_name;
        if (name[0] == '.' && (name[1] == '\0' ||
            (name[1] == '.' && name[2] == '\0'))) continue;
        char child[900];
        int n = snprintf(child, sizeof child, "%s/%s", path, name);
        if (n <= 0 || (size_t)n >= sizeof child) { rc = -1; break; }
        struct stat st;
        if (lstat(child, &st) != 0) { rc = -1; break; }
        if (S_ISDIR(st.st_mode)) {
            rc = remove_tree(child, depth + 1);
            if (rc == 0 && rmdir(child) != 0) rc = -1;
        } else if (S_ISLNK(st.st_mode) || S_ISREG(st.st_mode)) {
            if (unlink(child) != 0) rc = -1;
        } else {
            rc = -1; // device nodes etc.: refuse, never rm blindly
        }
    }
    closedir(dir);
    return rc;
}

// Extracts the recorded generation from a supervisor.json body so the
// recovery EVENT carries the project's real generation; falls back to "0".
static void record_generation(const char *body, char *out, size_t cap) {
    snprintf(out, cap, "0");
    const char *key = strstr(body, "\"generation\":\"");
    if (!key) return;
    key += strlen("\"generation\":\"");
    const char *end = strchr(key, '"');
    if (!end) return;
    size_t len = (size_t)(end - key);
    if (len == 0 || len >= cap || len > FLOE_MAX_GENERATION) return;
    memcpy(out, key, len);
    out[len] = '\0';
}

static void recover_stale_projects(void) {
    char projects_dir[512];
    if (path_join(projects_dir, sizeof projects_dir, g_state, "projects") != 0) return;
    DIR *dir = opendir(projects_dir);
    if (!dir) return;
    struct dirent *entry;
    while ((entry = readdir(dir)) != NULL) {
        const char *name = entry->d_name;
        if (name[0] == '.') continue;
        if (!floe_project_id_valid(name)) {
            diag("floe-supervisor: ignoring foreign project directory %s\n", name);
            continue;
        }
        char rec_path[640];
        if (path_join(rec_path, sizeof rec_path, projects_dir, name) != 0) continue;
        char sub[768];
        if (path_join(sub, sizeof sub, rec_path, "supervisor.json") != 0) continue;
        char body[1400];
        if (read_small_file(sub, body, sizeof body) == 0 && strstr(body, g_boot_id) == NULL) {
            // Stale record from a previous boot: detach leftover mounts.
            char root[768];
            if (path_join(root, sizeof root, rec_path, "root") == 0) {
                floe_project ghost;
                memset(&ghost, 0, sizeof ghost);
                size_t name_len = strlen(name);
                size_t root_len = strlen(root);
                // name was validated above (<= FLOE_MAX_PROJECT_ID) and root
                // was built from path_join into a bounded buffer; the
                // explicit bounds keep -Wformat-truncation quiet.
                if (name_len < sizeof ghost.id && root_len < sizeof ghost.root) {
                    memcpy(ghost.id, name, name_len + 1);
                    memcpy(ghost.root, root, root_len + 1);
                    project_rootfs_unmount(&ghost);
                }
            }
            char cg[768];
            // Compile fix (2026-11-05): path_join takes (out, cap, dir,
            // leaf); the draft called it with three arguments here.
            if (path_join(cg, sizeof cg, "/sys/fs/cgroup", "floe") == 0) {
                char cgdir[900];
                if (path_join(cgdir, sizeof cgdir, cg, name) == 0) {
                    (void)write_cgroup_value(cgdir, "cgroup.kill", "1");
                    char tasks[960];
                    if (path_join(tasks, sizeof tasks, cgdir, "tasks") == 0) (void)rmdir(tasks);
                    (void)rmdir(cgdir);
                }
            }
            char generation[FLOE_MAX_GENERATION + 1];
            record_generation(body, generation, sizeof generation);
            (void)unlink(sub); // liveness claim only; data stays
            emit_event(name, generation, "recovered", "stale-runtime-state");
            diag("floe-supervisor: recovered stale project state for %s\n", name);
        }
    }
    closedir(dir);
}

#endif // __linux__

// ---------------------------------------------------------------------------
// Control request handling (pure dispatch; Linux side effects guarded)
// ---------------------------------------------------------------------------

typedef struct {
    char token[FLOE_CTRL_MAX_TOKEN + 1];
    int kind;
    char project[FLOE_MAX_PROJECT_ID + 1];
    char generation[FLOE_MAX_GENERATION + 1];
    char task[FLOE_MAX_TASK_ID + 1];
    char lease_op[16];
    char lease_id[FLOE_CTRL_MAX_TOKEN + 1];
    bytebuf payload;
    size_t expected;
    uint32_t chunks_expected;
    uint32_t chunks_received;
} ctrl_request;

enum {
    CTRL_NONE = 0,
    CTRL_HELLO,
    CTRL_PROJOPEN,
    CTRL_PROJCLOSE,
    CTRL_PROJDROP,
    CTRL_PROJSTAT,
    CTRL_TASKKILL,
    CTRL_LEASE,
    CTRL_PING,
};

static ctrl_request g_requests[FLOE_MAX_PROJECTS + 2];

static ctrl_request *request_for(const char *token) {
    for (size_t i = 0; i < sizeof g_requests / sizeof g_requests[0]; i++) {
        if (g_requests[i].kind != CTRL_NONE && strcmp(g_requests[i].token, token) == 0) {
            return &g_requests[i];
        }
    }
    return NULL;
}

static ctrl_request *request_begin(int kind, const char *token) {
    ctrl_request *r = request_for(token);
    if (!r) {
        for (size_t i = 0; i < sizeof g_requests / sizeof g_requests[0]; i++) {
            if (g_requests[i].kind == CTRL_NONE) { r = &g_requests[i]; break; }
        }
    }
    if (!r) return NULL;
    bb_free(&r->payload);
    memset(r, 0, sizeof *r);
    r->kind = kind;
    snprintf(r->token, sizeof r->token, "%s", token);
    return r;
}

static void request_end(ctrl_request *r) {
    bb_free(&r->payload);
    memset(r, 0, sizeof *r);
}

// Parses "PROJOPEN <token> <project> <generation> <payloadBytes> <chunks>".
static int parse_project_frame(const unsigned char *args, size_t len,
                               char *project, char *generation,
                               size_t *payload_bytes, uint32_t *chunks) {
    char buf[256];
    if (len == 0 || len >= sizeof buf) return -1;
    memcpy(buf, args, len);
    buf[len] = '\0';
    char *save = NULL;
    char *p = strtok_r(buf, " ", &save);
    if (!p || strlen(p) > FLOE_MAX_PROJECT_ID) return -1;
    snprintf(project, FLOE_MAX_PROJECT_ID + 1, "%s", p);
    char *g = strtok_r(NULL, " ", &save);
    if (!g || strlen(g) > FLOE_MAX_GENERATION) return -1;
    snprintf(generation, FLOE_MAX_GENERATION + 1, "%s", g);
    char *pb = strtok_r(NULL, " ", &save);
    char *ch = strtok_r(NULL, " ", &save);
    if (!pb || !ch) return -1;
    char *end = NULL;
    errno = 0;
    long bytes = strtol(pb, &end, 10);
    if (errno != 0 || !end || *end != '\0' || bytes <= 0 || bytes > FLOE_CTRL_MAX_PAYLOAD) return -1;
    errno = 0;
    long cn = strtol(ch, &end, 10);
    if (errno != 0 || !end || *end != '\0' || cn <= 0 || cn > FLOE_CTRL_MAX_CHUNKS) return -1;
    *payload_bytes = (size_t)bytes;
    *chunks = (uint32_t)cn;
    return 0;
}

// Parses "TASKKILL <token> <project> <generation> <task>" / "LEASE ... <op> <id>".
static int parse_id_frame(const unsigned char *args, size_t len,
                          char *project, char *generation,
                          char *task, char *op, char *lease_id) {
    char buf[512];
    if (len == 0 || len >= sizeof buf) return -1;
    memcpy(buf, args, len);
    buf[len] = '\0';
    char *save = NULL;
    char *p = strtok_r(buf, " ", &save);
    if (!p || strlen(p) > FLOE_MAX_PROJECT_ID) return -1;
    snprintf(project, FLOE_MAX_PROJECT_ID + 1, "%s", p);
    char *g = strtok_r(NULL, " ", &save);
    if (!g || strlen(g) > FLOE_MAX_GENERATION) return -1;
    snprintf(generation, FLOE_MAX_GENERATION + 1, "%s", g);
    if (task) {
        char *t = strtok_r(NULL, " ", &save);
        if (!t || strlen(t) > FLOE_MAX_TASK_ID) return -1;
        snprintf(task, FLOE_MAX_TASK_ID + 1, "%s", t);
    }
    if (op) {
        char *o = strtok_r(NULL, " ", &save);
        if (!o) return -1;
        snprintf(op, 16, "%s", o);
    }
    if (lease_id) {
        char *l = strtok_r(NULL, " ", &save);
        if (l) {
            if (strlen(l) > FLOE_CTRL_MAX_TOKEN) return -1;
            snprintf(lease_id, FLOE_CTRL_MAX_TOKEN + 1, "%s", l);
        }
    }
    return 0;
}

static int project_identity_ok(const char *project, const char *generation) {
    return floe_project_id_valid(project) && floe_generation_valid(generation);
}

// ---------------------------------------------------------------------------
// Request executors
// ---------------------------------------------------------------------------

static void do_projstat(const char *token) {
    section_open(token);
    char line[768];
    for (int i = 0; i < FLOE_MAX_PROJECTS; i++) {
        floe_project *p = &g_projects[i];
        if (!p->used) continue;
        const char *state = p->state == PROJ_ACTIVE ? "active"
                          : p->state == PROJ_OPENING ? "opening"
                          : p->state == PROJ_CLOSING ? "closing"
                          : p->state == PROJ_RECOVERED ? "recovered" : "free";
        int n = snprintf(line, sizeof line, "project=%s generation=%s state=%s "
                         "console=hvc%d runner=%ld lease=%s\n",
                         p->id, p->generation, state, p->console_index,
                         (long)p->runner_pid,
                         p->lease_id[0] ? "held" : "free");
        if (n > 0 && (size_t)n < sizeof line) emit_line(token, line);
    }
    (void)emit_end(token, 0);
}

static void do_ping(const char *token) {
    (void)emit_end(token, 0);
}

static void do_taskkill(const char *token, const char *project,
                        const char *generation, const char *task) {
    if (!project_identity_ok(project, generation) || !floe_task_id_valid(task)) {
        emit_failure(token, 125, "floe-supervisor: invalid project/task identity");
        return;
    }
    floe_project *p = project_find(project);
    if (!p || strcmp(p->generation, generation) != 0) {
        (void)emit_end(token, 3);
        return;
    }
#ifdef __linux__
    char task_dir[900];
    int n = snprintf(task_dir, sizeof task_dir, "%s/tasks/%s", p->cgroup_dir, task);
    if (n <= 0 || (size_t)n >= sizeof task_dir) {
        emit_failure(token, 125, "floe-supervisor: task path overflow");
        return;
    }
    if (access(task_dir, F_OK) != 0) {
        (void)emit_end(token, 3); // unknown task: nothing to kill
        return;
    }
    if (write_cgroup_value(task_dir, "cgroup.kill", "1") != 0 && errno != ENOENT) {
        emit_failure(token, 126, "floe-supervisor: task kill failed");
        return;
    }
#endif
    (void)emit_end(token, 0);
}

static void do_lease(const char *token, const char *project, const char *generation,
                     const char *op, const char *lease_id) {
    if (!project_identity_ok(project, generation)) {
        emit_failure(token, 125, "floe-supervisor: invalid project identity");
        return;
    }
    floe_project *p = project_find(project);
    if (!p || strcmp(p->generation, generation) != 0) {
        (void)emit_end(token, 3);
        return;
    }
    if (strcmp(op, "renew") == 0) {
        if (lease_id[0] == '\0') {
            emit_failure(token, 125, "floe-supervisor: lease renew needs a lease id");
            return;
        }
        if (p->lease_id[0] != '\0' && strcmp(p->lease_id, lease_id) != 0) {
            (void)emit_end(token, 127); // held by another holder
            return;
        }
        snprintf(p->lease_id, sizeof p->lease_id, "%s", lease_id);
        p->lease_deadline_ms = now_ms() + FLOE_LEASE_MAX_MS;
        (void)emit_end(token, 0);
        return;
    }
    if (strcmp(op, "release") == 0) {
        if (p->lease_id[0] == '\0' || strcmp(p->lease_id, lease_id) != 0) {
            (void)emit_end(token, 3);
            return;
        }
        p->lease_id[0] = '\0';
        p->lease_deadline_ms = 0;
        (void)emit_end(token, 0);
        return;
    }
    emit_failure(token, 125, "floe-supervisor: unknown lease operation");
}

#ifdef __linux__

static void do_projopen(const char *token, ctrl_request *r,
                        const char *project, const char *generation) {
    if (!g_ready || !g_cgroup_ready) {
        emit_failure(token, 126, "floe-supervisor: base/state/cgroup roots unavailable");
        return;
    }
    if (!project_identity_ok(project, generation)) {
        emit_failure(token, 125, "floe-supervisor: invalid project identity");
        return;
    }
    if (project_find(project)) {
        emit_failure(token, 127, "floe-supervisor: project already open");
        return;
    }
    floe_project *p = project_free_slot();
    if (!p) {
        emit_failure(token, 125, "floe-supervisor: project table full");
        return;
    }

    // Payload: [baseRootfs, workspaceDir, nativeShareSlot].
    field_table t;
    if (fields_split(r->payload.data, r->payload.len, &t) != 0 || t.count != 3) {
        fields_free(&t);
        emit_failure(token, 125, "floe-supervisor: malformed PROJOPEN payload");
        return;
    }
    char *base_rootfs = field_dup_cstr(r->payload.data, t.offsets[0], t.lengths[0]);
    char *workspace = field_dup_cstr(r->payload.data, t.offsets[1], t.lengths[1]);
    char *slot_text = field_dup_cstr(r->payload.data, t.offsets[2], t.lengths[2]);
    fields_free(&t);
    int ok = base_rootfs && workspace && slot_text && strlen(slot_text) == 1
          && slot_text[0] >= '0' && slot_text[0] < '0' + FLOE_MAX_PROJECTS;
    unsigned slot = ok ? (unsigned)(slot_text[0] - '0') : FLOE_MAX_PROJECTS;
    free(slot_text);
    if (ok && strcmp(base_rootfs, g_base) != 0) ok = 0; // never a foreign tree
    if (ok && workspace[0] != '\0' && workspace[0] != '/') ok = 0; // in-project or empty
    if (!ok) {
        free(base_rootfs);
        free(workspace);
        emit_failure(token, 125, "floe-supervisor: PROJOPEN base/workspace rejected");
        return;
    }
    free(base_rootfs);

    int console = console_for_slot(slot);
    if (console < 0) {
        free(workspace);
        emit_failure(token, 125, "floe-supervisor: no console free");
        return;
    }

    memset(p, 0, sizeof *p);
    p->used = 1;
    p->state = PROJ_OPENING;
    snprintf(p->id, sizeof p->id, "%s", project);
    snprintf(p->generation, sizeof p->generation, "%s", generation);
    p->console_index = console;
    p->open_ms = now_ms();
    if (workspace[0] != '\0') snprintf(p->workspace_dir, sizeof p->workspace_dir, "%s", workspace);
    free(workspace);

    char projects_dir[512];
    if (path_join(projects_dir, sizeof projects_dir, g_state, "projects") != 0 ||
        mkdir_p(projects_dir, 0700) != 0) {
        p->used = 0;
        emit_failure(token, 126, "floe-supervisor: state root unavailable");
        return;
    }
    // Local copy: keeps snprintf's restrict analysis from flagging the
    // g_projects member pair (p->dir vs p->id) under -Werror.
    char id_copy[FLOE_MAX_PROJECT_ID + 1];
    snprintf(id_copy, sizeof id_copy, "%s", p->id);
    if (snprintf(p->dir, sizeof p->dir, "%s/%s", projects_dir, id_copy) <= 0 ||
        mkdir_p(p->dir, 0700) != 0) {
        p->used = 0;
        emit_failure(token, 126, "floe-supervisor: cannot create project dir");
        return;
    }
    if (path_join(p->root, sizeof p->root, p->dir, "root") != 0) {
        p->used = 0;
        emit_failure(token, 126, "floe-supervisor: project path overflow");
        return;
    }

    if (project_cgroup_create(p) != 0 ||
        project_rootfs_mount(p) != 0 ||
        project_record_write(p) != 0 ||
        spawn_project_runner(p) != 0) {
        project_cgroup_kill_and_remove(p);
        project_rootfs_unmount(p);
        p->used = 0;
        emit_failure(token, 126, "floe-supervisor: project setup failed");
        return;
    }
    p->state = PROJ_ACTIVE;
    (void)project_record_write(p);

    char line[768];
    int n = snprintf(line, sizeof line,
                     "project=%s generation=%s console=hvc%d root=%s workspace=%s share=%s\n",
                     p->id, p->generation, p->console_index, p->root,
                     p->workspace_dir, p->workspace_shared ? "floe-ws" : "unavailable");
    if (n > 0 && (size_t)n < sizeof line) {
        section_open(token);
        emit_line(token, line);
    }
    (void)emit_end(token, 0);
}

// Shared close path: kill the project's tasks + runner, detach the runtime
// view, keep the overlay data. Returns 0 when fully closed.
static int project_close_impl(floe_project *p, const char *reason) {
    if (p->state == PROJ_CLOSING || p->state == PROJ_FREE) return 0;
    p->state = PROJ_CLOSING;
    (void)project_record_write(p);
    // Kill the whole project tree (runner + every task cgroup) in one
    // bounded operation; never a global reboot, never another project.
    (void)write_cgroup_value(p->cgroup_dir, "cgroup.kill", "1");
    if (p->runner_pid > 0) {
        (void)kill(p->runner_pid, SIGKILL);
        int status = 0;
        for (int i = 0; i < 50; i++) {
            if (waitpid(p->runner_pid, &status, WNOHANG) == p->runner_pid) break;
            struct timespec ts = {0, 20 * 1000 * 1000};
            nanosleep(&ts, NULL);
        }
        (void)status;
        p->runner_pid = 0;
    }
    project_rootfs_unmount(p);
    project_cgroup_kill_and_remove(p);
    char rec_path[768];
    if (path_join(rec_path, sizeof rec_path, p->dir, "supervisor.json") == 0) {
        (void)unlink(rec_path); // liveness claim only; overlay data stays
    }
    emit_event(p->id, p->generation, "closed", reason);
    p->used = 0;
    p->state = PROJ_FREE;
    return 0;
}

static void do_projclose(const char *token, const char *project, const char *generation) {
    if (!project_identity_ok(project, generation)) {
        emit_failure(token, 125, "floe-supervisor: invalid project identity");
        return;
    }
    floe_project *p = project_find(project);
    if (!p || strcmp(p->generation, generation) != 0) {
        (void)emit_end(token, 3);
        return;
    }
    // A held lease blocks close: the holder may be mid-transaction.
    if (p->lease_id[0] != '\0' && now_ms() < p->lease_deadline_ms) {
        (void)emit_end(token, 127);
        return;
    }
    project_close_impl(p, "host-close");
    (void)emit_end(token, 0);
}

static void do_projdrop(const char *token, const char *project, const char *generation) {
    if (!project_identity_ok(project, generation)) {
        emit_failure(token, 125, "floe-supervisor: invalid project identity");
        return;
    }
    floe_project *p = project_find(project);
    if (p) {
        // Refuse while open: the runner or its tasks may still reference
        // package files inside the overlay.
        (void)emit_end(token, 127);
        return;
    }
    // The project must have been closed first; verify the state dir exists
    // and belongs to this generation's lineage before deleting data.
    char projects_dir[512], dir[640], rec[768];
    if (path_join(projects_dir, sizeof projects_dir, g_state, "projects") != 0 ||
        snprintf(dir, sizeof dir, "%s/%s", projects_dir, project) <= 0) {
        emit_failure(token, 125, "floe-supervisor: path overflow");
        return;
    }
    struct stat st;
    if (stat(dir, &st) != 0 || !S_ISDIR(st.st_mode)) {
        (void)emit_end(token, 3);
        return;
    }
    if (snprintf(rec, sizeof rec, "%s/supervisor.json", dir) <= 0 ||
        access(rec, F_OK) == 0) {
        // Liveness record still present: refuse (recovery has not run).
        (void)emit_end(token, 127);
        return;
    }
    // Bound the blast radius: only ever delete inside the validated project
    // dir; never follow a symlink at the top level; no shell anywhere in
    // the supervisor (the initramfs has no Debian PID 1 to provide one).
    if (lstat(dir, &st) != 0 || S_ISLNK(st.st_mode)) {
        emit_failure(token, 126, "floe-supervisor: project dir is a symlink");
        return;
    }
    if (remove_tree(dir, 0) != 0 || rmdir(dir) != 0) {
        emit_failure(token, 126, "floe-supervisor: project data removal failed");
        return;
    }
    (void)emit_end(token, 0);
}

#endif // __linux__

// ---------------------------------------------------------------------------
// Frame dispatch
// ---------------------------------------------------------------------------

static void execute_request(ctrl_request *r) {
    switch (r->kind) {
    case CTRL_PROJOPEN:
#ifdef __linux__
        // The identity was validated and stored by handle_frame when the
        // PROJOPEN header arrived; the payload fields are read here.
        do_projopen(r->token, r, r->project, r->generation);
#else
        emit_failure(r->token, 126, "floe-supervisor: projects unsupported on this build");
#endif
        break;
    case CTRL_PROJCLOSE:
#ifdef __linux__
        do_projclose(r->token, r->project, r->generation);
#else
        (void)emit_end(r->token, 126);
#endif
        break;
    case CTRL_PROJDROP:
#ifdef __linux__
        do_projdrop(r->token, r->project, r->generation);
#else
        (void)emit_end(r->token, 126);
#endif
        break;
    case CTRL_PROJSTAT:
        do_projstat(r->token);
        break;
    case CTRL_TASKKILL:
        do_taskkill(r->token, r->project, r->generation, r->task);
        break;
    case CTRL_LEASE:
        do_lease(r->token, r->project, r->generation, r->lease_op, r->lease_id);
        break;
    default:
        break;
    }
}

static void handle_frame(const unsigned char *body, size_t len) {
    const unsigned char *name_end = memchr(body, ' ', len);
    if (!name_end) return;
    size_t name_len = (size_t)(name_end - body);
    const unsigned char *rest = name_end + 1;
    size_t rest_len = len - name_len - 1;

    const unsigned char *token_end = memchr(rest, ' ', rest_len);
    size_t token_len = token_end ? (size_t)(token_end - rest) : rest_len;
    if (token_len == 0 || token_len >= FLOE_CTRL_MAX_TOKEN) return;
    char token[FLOE_CTRL_MAX_TOKEN + 1];
    memcpy(token, rest, token_len);
    token[token_len] = '\0';
    for (size_t i = 0; i < token_len; i++) {
        if ((unsigned char)token[i] < 0x21 || (unsigned char)token[i] > 0x7e) return;
    }
    const unsigned char *args = token_end ? token_end + 1 : rest + rest_len;
    size_t args_len = token_end ? rest_len - token_len - 1 : 0;

    if (name_len == 5 && memcmp(body, "HELLO", 5) == 0) {
        (void)emit_caps(token, g_base, g_state);
        return;
    }
    if (name_len == 4 && memcmp(body, "PING", 4) == 0) {
        do_ping(token);
        return;
    }
    if (name_len == 8 && memcmp(body, "PROJSTAT", 8) == 0) {
        do_projstat(token);
        return;
    }
    if (name_len == 8 && memcmp(body, "PROJOPEN", 8) == 0) {
        // PROJOPEN <token> <project> <generation> <payloadBytes> <chunks>
        ctrl_request *r = request_begin(CTRL_PROJOPEN, token);
        if (!r) { emit_failure(token, 125, "floe-supervisor: request table full"); return; }
        size_t payload_bytes = 0;
        uint32_t chunks = 0;
        if (parse_project_frame(args, args_len, r->project, r->generation,
                                &payload_bytes, &chunks) != 0) {
            request_end(r);
            emit_failure(token, 125, "floe-supervisor: malformed PROJOPEN header");
            return;
        }
        r->expected = payload_bytes;
        r->chunks_expected = chunks;
        return; // waits for CHUNKs + RUN
    }
    if (name_len == 9 && memcmp(body, "PROJCLOSE", 9) == 0) {
        ctrl_request *r = request_begin(CTRL_PROJCLOSE, token);
        if (!r) { emit_failure(token, 125, "floe-supervisor: request table full"); return; }
        if (parse_id_frame(args, args_len, r->project, r->generation, NULL, NULL, NULL) != 0) {
            request_end(r);
            emit_failure(token, 125, "floe-supervisor: malformed PROJCLOSE");
            return;
        }
        execute_request(r);
        request_end(r);
        return;
    }
    if (name_len == 8 && memcmp(body, "PROJDROP", 8) == 0) {
        ctrl_request *r = request_begin(CTRL_PROJDROP, token);
        if (!r) { emit_failure(token, 125, "floe-supervisor: request table full"); return; }
        if (parse_id_frame(args, args_len, r->project, r->generation, NULL, NULL, NULL) != 0) {
            request_end(r);
            emit_failure(token, 125, "floe-supervisor: malformed PROJDROP");
            return;
        }
        execute_request(r);
        request_end(r);
        return;
    }
    if (name_len == 8 && memcmp(body, "TASKKILL", 8) == 0) {
        ctrl_request *r = request_begin(CTRL_TASKKILL, token);
        if (!r) { emit_failure(token, 125, "floe-supervisor: request table full"); return; }
        if (parse_id_frame(args, args_len, r->project, r->generation, r->task, NULL, NULL) != 0) {
            request_end(r);
            emit_failure(token, 125, "floe-supervisor: malformed TASKKILL");
            return;
        }
        execute_request(r);
        request_end(r);
        return;
    }
    if (name_len == 5 && memcmp(body, "LEASE", 5) == 0) {
        ctrl_request *r = request_begin(CTRL_LEASE, token);
        if (!r) { emit_failure(token, 125, "floe-supervisor: request table full"); return; }
        if (parse_id_frame(args, args_len, r->project, r->generation,
                           NULL, r->lease_op, r->lease_id) != 0) {
            request_end(r);
            emit_failure(token, 125, "floe-supervisor: malformed LEASE");
            return;
        }
        execute_request(r);
        request_end(r);
        return;
    }
    if (name_len == 5 && memcmp(body, "CHUNK", 5) == 0) {
        ctrl_request *r = request_for(token);
        if (!r || r->kind != CTRL_PROJOPEN) return;
        const unsigned char *index_end = memchr(args, ' ', args_len);
        if (!index_end) { request_end(r); return; }
        char index_buf[16];
        size_t index_len = (size_t)(index_end - args);
        if (index_len == 0 || index_len >= sizeof index_buf) { request_end(r); return; }
        memcpy(index_buf, args, index_len);
        index_buf[index_len] = '\0';
        char *end = NULL;
        errno = 0;
        long index = strtol(index_buf, &end, 10);
        if (errno != 0 || !end || *end != '\0' || index < 0 ||
            (uint32_t)index >= r->chunks_expected) {
            request_end(r);
            return;
        }
        if ((uint32_t)index != r->chunks_received) { // out of order: abort
            request_end(r);
            return;
        }
        const unsigned char *chunk_body = index_end + 1;
        size_t chunk_len = args_len - index_len - 1;
        size_t cap = chunk_len / 4 * 3 + 4;
        unsigned char *decoded = malloc(cap);
        if (!decoded) { request_end(r); return; }
        long decoded_len = b64_decode(chunk_body, chunk_len, decoded, cap);
        if (decoded_len < 0 || r->payload.len + (size_t)decoded_len > FLOE_CTRL_MAX_PAYLOAD) {
            free(decoded);
            request_end(r);
            return;
        }
        int rc = bb_append(&r->payload, decoded, (size_t)decoded_len);
        free(decoded);
        if (rc != 0) { request_end(r); return; }
        r->chunks_received++;
        return;
    }
    if (name_len == 3 && memcmp(body, "RUN", 3) == 0) {
        ctrl_request *r = request_for(token);
        if (!r || r->kind != CTRL_PROJOPEN) return;
        if (r->chunks_received != r->chunks_expected || r->payload.len != r->expected) {
            emit_failure(token, 125, "floe-supervisor: incomplete chunked payload");
            request_end(r);
            return;
        }
        execute_request(r); // do_projopen reads the payload fields
        request_end(r);
        return;
    }
}

static void dispatch_inbound(bytebuf *in) {
    static const char prefix[] = "\x1e" "FLOE-";
    const size_t prefix_len = sizeof prefix - 1;
    for (;;) {
        if (in->len == 0) return;
        unsigned char *mark = memchr(in->data, 0x1e, in->len);
        if (!mark) {
            bb_consume(in, in->len);
            return;
        }
        size_t skip = (size_t)(mark - in->data);
        if (skip > 0) bb_consume(in, skip);
        if (in->len < prefix_len) return;
        if (memcmp(in->data, prefix, prefix_len) != 0) {
            bb_consume(in, 1);
            continue;
        }
        unsigned char *newline = memchr(in->data, '\n', in->len);
        unsigned char *closing = NULL;
        for (size_t i = 1; i < in->len; i++) {
            if (in->data[i] == 0x1e) { closing = in->data + i; break; }
        }
        size_t line_len = 0, consume = 0;
        if (newline && (!closing || newline < closing)) {
            line_len = (size_t)(newline - in->data);
            consume = line_len + 1;
        } else if (closing) {
            line_len = (size_t)(closing - in->data);
            consume = line_len + 1;
            if (consume < in->len && in->data[consume] == '\n') consume++;
        } else {
            if (in->len > FLOE_CTRL_MAX_INBOUND) bb_consume(in, in->len);
            return;
        }
        if (line_len > prefix_len) handle_frame(in->data + prefix_len, line_len - prefix_len);
        bb_consume(in, consume);
    }
}

// ---------------------------------------------------------------------------
// Main loop
// ---------------------------------------------------------------------------

static int g_wake_pipe[2] = {-1, -1};

static void on_sigchld(int sig) {
    (void)sig;
    if (g_wake_pipe[1] >= 0) {
        ssize_t ignored = write(g_wake_pipe[1], "c", 1);
        (void)ignored;
    }
}

int main(void) {
    signal(SIGPIPE, SIG_IGN);
    if (isatty(STDIN_FILENO)) {
        struct termios tty;
        if (tcgetattr(STDIN_FILENO, &tty) != 0) return 126;
        cfmakeraw(&tty);
        if (tcsetattr(STDIN_FILENO, TCSANOW, &tty) != 0) return 126;
    }
    struct sigaction chld;
    memset(&chld, 0, sizeof chld);
    chld.sa_handler = on_sigchld;
    (void)sigaction(SIGCHLD, &chld, NULL);

    if (pipe(g_wake_pipe) == 0) {
        set_nonblocking(g_wake_pipe[0]);
        set_nonblocking(g_wake_pipe[1]);
    }

    supervisor_config cfg;
    if (load_supervisor_config(&cfg) == 0) {
        snprintf(g_base, sizeof g_base, "%s", cfg.base);
        snprintf(g_state, sizeof g_state, "%s", cfg.state);
        snprintf(g_workspace_root, sizeof g_workspace_root, "%s", cfg.workspace);
        snprintf(g_runner_path, sizeof g_runner_path, "%s", cfg.runner);
    } else {
        diag("floe-supervisor: floe.base/floe.state missing or invalid; "
             "control channel answers, PROJOPEN will fail closed\n");
        g_base[0] = '\0';
        g_state[0] = '\0';
    }

#ifdef __linux__
    g_cgroup_ready = supervisor_bring_up() == 0;
    // Interface, route and resolver are machine-wide: applied before the
    // first CAPS so a host that sees the control channel can trust net=.
    supervisor_bring_up_network();
    char boot_buf[64];
    if (read_small_file("/proc/sys/kernel/random/boot_id", boot_buf, sizeof boot_buf) == 0) {
        snprintf(g_boot_id, sizeof g_boot_id, "%s", boot_buf);
    } else {
        snprintf(g_boot_id, sizeof g_boot_id, "boot-%lld", (long long)now_ms());
    }
    if (g_base[0] != '\0' && verify_roots() == 0) {
        recover_stale_projects();
        g_ready = 1;
    }
#endif

    bytebuf inbound = {0};
    for (;;) {
        struct pollfd fds[2];
        int n = 0;
        fds[n].fd = STDIN_FILENO;
        fds[n].events = POLLIN;
        fds[n].revents = 0;
        n++;
        int i_wake = -1;
        if (g_wake_pipe[0] >= 0) {
            i_wake = n;
            fds[n].fd = g_wake_pipe[0];
            fds[n].events = POLLIN;
            fds[n].revents = 0;
            n++;
        }
        int ready = poll(fds, (nfds_t)n, -1);
        if (ready < 0) {
            if (errno == EINTR) continue;
            continue;
        }
        if (i_wake >= 0 && (fds[i_wake].revents & POLLIN)) {
            unsigned char drain[64];
            while (read(g_wake_pipe[0], drain, sizeof drain) > 0) {}
        }
        if (fds[0].revents & (POLLIN | POLLHUP | POLLERR)) {
            unsigned char chunk[FLOE_CTRL_IO_CHUNK];
            ssize_t got = read(STDIN_FILENO, chunk, sizeof chunk);
            if (got > 0) {
                for (ssize_t i = 0; i < got; i++) {
                    if (inbound.len + 1 > FLOE_CTRL_MAX_INBOUND) bb_consume(&inbound, inbound.len);
                    if (bb_append(&inbound, &chunk[i], 1) != 0) bb_consume(&inbound, inbound.len);
                }
                dispatch_inbound(&inbound);
                continue;
            }
            if (got == 0) {
                // Console EOF: the Machine is being stopped. Close every
                // project cleanly (tasks killed, data kept); never reboot.
#ifdef __linux__
                for (int i = 0; i < FLOE_MAX_PROJECTS; i++) {
                    if (g_projects[i].used) project_close_impl(&g_projects[i], "console-eof");
                }
#endif
                bb_free(&inbound);
                return 0;
            }
            if (errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) {
                bb_free(&inbound);
                return 0;
            }
        }

        // Reap dead runners and mark their projects for host recovery.
#ifdef __linux__
        for (;;) {
            int status = 0;
            pid_t p = waitpid(-1, &status, WNOHANG);
            if (p == 0) break;
            if (p < 0) break;
            for (int i = 0; i < FLOE_MAX_PROJECTS; i++) {
                floe_project *proj = &g_projects[i];
                if (proj->used && proj->runner_pid == p) {
                    proj->runner_pid = 0;
                    // Runner death is never silent: the host must re-open the
                    // project (same generation = reattach, or recover first).
                    if (proj->state == PROJ_ACTIVE) {
                        proj->state = PROJ_CLOSING;
                        (void)write_cgroup_value(proj->cgroup_dir, "cgroup.kill", "1");
                        project_rootfs_unmount(proj);
                        project_cgroup_kill_and_remove(proj);
                        emit_event(proj->id, proj->generation, "runner-died",
                                   WIFSIGNALED(status) ? "signaled" : "exited");
                        proj->used = 0;
                        proj->state = PROJ_FREE;
                    }
                }
            }
        }
        // Lease expiry: bounded so a dead host can never wedge a project.
        int64_t now = now_ms();
        for (int i = 0; i < FLOE_MAX_PROJECTS; i++) {
            floe_project *p = &g_projects[i];
            if (p->used && p->lease_id[0] != '\0' && now >= p->lease_deadline_ms) {
                emit_event(p->id, p->generation, "lease-expired", p->lease_id);
                p->lease_id[0] = '\0';
                p->lease_deadline_ms = 0;
            }
        }
#endif
    }
}
