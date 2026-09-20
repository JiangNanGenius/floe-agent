// floe_exec.c — Floe Linux guest command runner.
//
// The Floe app runs one long-lived runner on the guest's virtio console
// (hvc0). The host speaks a line-framed protocol; every host→guest frame
// starts with 0x1e "FLOE-" and ends at the first newline or, when the body
// contains no 0x1e of its own, at a closing 0x1e (plus an optional newline).
// The guest answers on the same console with
//
//   \x1eFLOE-BEGIN <token>\x1e
//   \x1eFLOE-OUT <token>\x1e <stdout bytes until the next marker>
//   \x1eFLOE-ERR <token>\x1e <stderr bytes until the next marker>
//   \x1eFLOE-END <token> <exit code>\x1e
//
// One-shot commands
// -----------------
// Inline (small envelopes, so one tty line stays under 4 kB):
//
//   \x1eFLOE-EXEC <token> <base64 payload>\n
//
// Chunked (canonical, large envelopes):
//
//   \x1eFLOE-EXEC <token> <payloadBytes> <chunkCount>\x1e\n
//   \x1eFLOE-CHUNK <token> <index> <base64>\x1e\n      (index 0..chunkCount-1)
//   \x1eFLOE-RUN <token>\x1e\n
//
// payload: u32 fieldCount, then per field u32 byteCount + raw bytes,
//          field order = [cwd, stdin, argv0, argv1, ...]
//
// OPEN/SPAWN use the same chunked envelope with a different field layout and
// the frame name OPEN or SPAWN in place of EXEC.
//
// Interactive PTY session
// -----------------------
//   OPEN payload fields = [mode="pty", cwd, cols, rows, argv0, argv1, ...]
//   host input:  \x1eFLOE-IN <token> <base64>\n
//   signals:     \x1eFLOE-SIGNAL <token> INT|TERM|WINCH <rows> <cols>\x1e
//   close:       \x1eFLOE-CLOSE <token>\x1e
//   guest: BEGIN, OUT stream (pty merged output), END with the real status
//   (130/143 when the host initiated INT/TERM).
//
// Background services
// -------------------
//   SPAWN payload fields = [cwd, logPath, argv0, argv1, ...]
//   guest: \x1eFLOE-PID <token> <pid>\x1e + \x1eFLOE-END <token> 0\x1e (never
//   waits for the process); stdout/stderr are appended to logPath.
//   \x1eFLOE-KILL <token> <pid>\x1e  -> END 0 (owned pid) or END 3 (unknown)
//   \x1eFLOE-ALIVE <token> <pid>\x1e -> END 0 (owned/alive) or END 3
// Only pids this runner spawned are ever signalled (bounded table).
//
// It is the guest half of FloeExecution/Linux/LinuxGuestCommandChannel.swift;
// the byte format is a contract, not a security boundary. argv is executed
// verbatim with execvp (never through a shell), stdin is the decoded `stdin`
// field followed by EOF, stdout and stderr are streamed as separate framed
// sections, and the exit code is the child's real wait status (128+signal
// when it dies from a signal).
//
// Cancellation: the host writes a raw 0x03 byte (the console is in raw mode,
// so it is a byte, not SIGINT). The runner kills only its own current
// command's process group (SIGTERM, then SIGKILL after a grace period), reaps
// it and reports exit 130. Processes that do not belong to the current
// command or to a pid this runner spawned are never signalled. A child that
// cannot be killed within a hard deadline is abandoned (it stays an orphan
// that PID 1 reaps later) so the channel can never hang.
//
// Console discipline: nothing unframed is written between frames. Boot-time
// diagnostics (mount failures) go to stderr and are discarded by the host
// parser before the first BEGIN.
//
// The runner is written in POSIX C so it can be compiled natively on the
// developer host for protocol checks (mounts are Linux-only and compiled
// out). The guest build is a static riscv64 binary (see Makefile).

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
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

#ifdef __linux__
#include <sys/mount.h>
#include <sys/sysmacros.h>
#endif

#define FLOE_MARK 0x1e
#define FLOE_CANCEL 0x03

// Bound on unconsumed console input. The host command envelope is capped at
// LinuxGuestLimits.maxCommandBytes (32 KiB) by the app; this is far above it.
#define MAX_INBOUND (256 * 1024)
// Bound on one decoded envelope (inline or reassembled chunks).
#define MAX_PAYLOAD (256 * 1024)
// Sanity bound on the field table inside one envelope.
#define MAX_FIELDS 4096
// Sanity bound on the chunk count of one envelope.
#define MAX_CHUNKS 4096
// Longest accepted token (UUIDs are 36 bytes).
#define MAX_TOKEN 96
// Per-read chunk.
#define IO_CHUNK 32768
// Forwarded bytes per stream, after which output is drained and dropped. The
// host caps what it keeps at LinuxGuestLimits.maxOutputBytes (1 MiB).
#define FORWARD_CAP (4 * 1024 * 1024)
// SIGTERM -> SIGKILL grace after a cancel or session close.
#define CANCEL_GRACE_MS 750
// If a cancelled child cannot be killed within this window, abandon it so the
// channel keeps serving (PID 1 reaps it when it finally dies).
#define CANCEL_ABANDON_MS 5000
// After a child is reaped, keep draining pipes until they are quiet for this
// long (a grandchild may still hold them open).
#define DRAIN_QUIET_MS 400
#define POLL_SLICE_MS 20
// Buffered host input for one PTY session (base64 FLOE-IN frames).
#define SESSION_INPUT_CAP (1024 * 1024)
// Background service bookkeeping.
#define MAX_SPAWNED 32
#define MAX_PENDING_KILLS 32
#define KILL_ESCALATE_MS 750

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

static int64_t now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + (int64_t)(ts.tv_nsec / 1000000);
}

static void sleep_ms(int ms) {
    struct timespec ts;
    ts.tv_sec = ms / 1000;
    ts.tv_nsec = (long)(ms % 1000) * 1000000L;
    nanosleep(&ts, NULL);
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

static void set_nonblocking(int fd) {
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags >= 0) (void)fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

#ifdef __linux__
// Boot/mount diagnostics. Between frames the runner stays silent; these are
// emitted before the first BEGIN (mount setup) and dropped by the host parser.
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
// Framing (guest -> host)
// ---------------------------------------------------------------------------

static int emit_marker(const char *name, const char *token) {
    char buf[MAX_TOKEN + 32];
    int n = snprintf(buf, sizeof buf, "\x1e" "FLOE-%s %s\x1e", name, token);
    if (n <= 0 || (size_t)n >= sizeof buf) return -1;
    return write_all(STDOUT_FILENO, buf, (size_t)n);
}

static int emit_end(const char *token, int code) {
    char buf[MAX_TOKEN + 48];
    int n = snprintf(buf, sizeof buf, "\x1e" "FLOE-END %s %d\x1e", token, code);
    if (n <= 0 || (size_t)n >= sizeof buf) return -1;
    return write_all(STDOUT_FILENO, buf, (size_t)n);
}

// BEGIN + ERR + END, used when a frame cannot be served (busy guest,
// malformed payload, failed setup). `begin` is only set for EXEC, whose host
// parser ignores everything before BEGIN.
static void emit_failure(const char *token, int begin, int code, const char *message) {
    if (begin && token[0] != '\0') (void)emit_marker("BEGIN", token);
    if (token[0] != '\0') (void)emit_marker("ERR", token);
    if (message && message[0] != '\0') {
        size_t len = strlen(message);
        (void)write_all(STDOUT_FILENO, message, len);
        if (message[len - 1] != '\n') (void)write_all(STDOUT_FILENO, "\n", 1);
    }
    if (token[0] != '\0') (void)emit_end(token, code);
}

// ---------------------------------------------------------------------------
// Base64
// ---------------------------------------------------------------------------

static int b64_value(unsigned char c) {
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '+') return 62;
    if (c == '/') return 63;
    return -1;
}

// Standard base64 with padding. Returns decoded length, or -1 on invalid
// input or overflow.
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

// ---------------------------------------------------------------------------
// Field table (shared by EXEC/OPEN/SPAWN payloads)
// ---------------------------------------------------------------------------

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

// Splits a decoded payload into fields. The offsets point into `payload`,
// which the caller keeps alive.
static int fields_split(const unsigned char *payload, size_t plen, field_table *out) {
    memset(out, 0, sizeof *out);
    if (plen < 4) return -1;
    uint32_t count = ((uint32_t)payload[0] << 24) | ((uint32_t)payload[1] << 16) |
                     ((uint32_t)payload[2] << 8) | (uint32_t)payload[3];
    if (count == 0 || count > MAX_FIELDS) return -1;
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

static unsigned char *field_dup_bytes(const unsigned char *payload, size_t offset, size_t length) {
    if (length == 0) return NULL;
    unsigned char *copy = malloc(length);
    if (!copy) return NULL;
    memcpy(copy, payload + offset, length);
    return copy;
}

// Builds a NULL-terminated argv from fields [first, count).
static char **fields_to_argv(const unsigned char *payload, const field_table *t, uint32_t first, int *argc_out) {
    if (first >= t->count) return NULL;
    int argc = (int)(t->count - first);
    char **argv = calloc((size_t)argc + 1, sizeof *argv);
    if (!argv) return NULL;
    for (int i = 0; i < argc; i++) {
        uint32_t idx = first + (uint32_t)i;
        argv[i] = field_dup_cstr(payload, t->offsets[idx], t->lengths[idx]);
        if (!argv[i]) {
            for (int j = 0; j < i; j++) free(argv[j]);
            free(argv);
            return NULL;
        }
    }
    *argc_out = argc;
    return argv;
}

static void free_argv(char **argv, int argc) {
    if (!argv) return;
    for (int i = 0; i < argc; i++) free(argv[i]);
    free(argv);
}

// ---------------------------------------------------------------------------
// Requests
// ---------------------------------------------------------------------------

typedef struct {
    char *cwd;
    unsigned char *input;
    size_t input_len;
    int argc;
    char **argv;
} exec_request;

static void exec_request_free(exec_request *r) {
    free(r->cwd);
    free(r->input);
    free_argv(r->argv, r->argc);
    memset(r, 0, sizeof *r);
}

static int exec_request_parse(const unsigned char *payload, size_t plen, exec_request *out) {
    memset(out, 0, sizeof *out);
    field_table t;
    if (fields_split(payload, plen, &t) != 0) return -1;
    if (t.count < 3) {
        fields_free(&t);
        return -1;
    }
    out->cwd = field_dup_cstr(payload, t.offsets[0], t.lengths[0]);
    if (!out->cwd) goto fail;
    out->input = field_dup_bytes(payload, t.offsets[1], t.lengths[1]);
    out->input_len = t.lengths[1];
    if (t.lengths[1] > 0 && !out->input) goto fail;
    out->argv = fields_to_argv(payload, &t, 2, &out->argc);
    if (!out->argv) goto fail;
    fields_free(&t);
    return 0;
fail:
    fields_free(&t);
    exec_request_free(out);
    return -1;
}

typedef struct {
    char *mode;
    char *cwd;
    int cols;
    int rows;
    int argc;
    char **argv;
} open_request;

static void open_request_free(open_request *r) {
    free(r->mode);
    free(r->cwd);
    free_argv(r->argv, r->argc);
    memset(r, 0, sizeof *r);
}

static int parse_decimal(const char *text, long *out) {
    if (!text || !*text) return -1;
    char *end = NULL;
    errno = 0;
    long value = strtol(text, &end, 10);
    if (errno != 0 || !end || *end != '\0' || value < 0 || value > (1 << 20)) return -1;
    *out = value;
    return 0;
}

static int open_request_parse(const unsigned char *payload, size_t plen, open_request *out) {
    memset(out, 0, sizeof *out);
    field_table t;
    if (fields_split(payload, plen, &t) != 0) return -1;
    if (t.count < 5) { // [mode, cwd, cols, rows, argv0...]
        fields_free(&t);
        return -1;
    }
    out->mode = field_dup_cstr(payload, t.offsets[0], t.lengths[0]);
    out->cwd = field_dup_cstr(payload, t.offsets[1], t.lengths[1]);
    char *cols = field_dup_cstr(payload, t.offsets[2], t.lengths[2]);
    char *rows = field_dup_cstr(payload, t.offsets[3], t.lengths[3]);
    long cols_value = 0, rows_value = 0;
    int ok = out->mode && out->cwd && cols && rows &&
             parse_decimal(cols, &cols_value) == 0 && parse_decimal(rows, &rows_value) == 0;
    free(cols);
    free(rows);
    if (ok) {
        out->cols = (int)cols_value;
        out->rows = (int)rows_value;
        out->argv = fields_to_argv(payload, &t, 4, &out->argc);
        if (!out->argv) ok = 0;
    }
    fields_free(&t);
    if (!ok) {
        open_request_free(out);
        return -1;
    }
    return 0;
}

typedef struct {
    char *cwd;
    char *log_path;
    int argc;
    char **argv;
} spawn_request;

static void spawn_request_free(spawn_request *r) {
    free(r->cwd);
    free(r->log_path);
    free_argv(r->argv, r->argc);
    memset(r, 0, sizeof *r);
}

static int spawn_request_parse(const unsigned char *payload, size_t plen, spawn_request *out) {
    memset(out, 0, sizeof *out);
    field_table t;
    if (fields_split(payload, plen, &t) != 0) return -1;
    if (t.count < 4) {
        fields_free(&t);
        return -1;
    }
    out->cwd = field_dup_cstr(payload, t.offsets[0], t.lengths[0]);
    out->log_path = field_dup_cstr(payload, t.offsets[1], t.lengths[1]);
    int ok = out->cwd && out->log_path && out->log_path[0] != '\0';
    if (ok) {
        out->argv = fields_to_argv(payload, &t, 2, &out->argc);
        if (!out->argv) ok = 0;
    }
    fields_free(&t);
    if (!ok) {
        spawn_request_free(out);
        return -1;
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Chunked envelope assembly
// ---------------------------------------------------------------------------

enum {
    ASM_NONE = 0,
    ASM_EXEC,
    ASM_OPEN,
    ASM_SPAWN,
};

typedef struct {
    int kind;
    char token[MAX_TOKEN];
    size_t expected;
    uint32_t chunks_expected;
    uint32_t chunks_received;
    bytebuf payload;
} assembly;

static void asm_reset(assembly *a) {
    bb_free(&a->payload);
    memset(a, 0, sizeof *a);
}

static void asm_begin(assembly *a, int kind, const char *token, size_t expected, uint32_t chunks) {
    asm_reset(a);
    a->kind = kind;
    snprintf(a->token, sizeof a->token, "%s", token);
    a->expected = expected;
    a->chunks_expected = chunks;
}

static int asm_chunk(assembly *a, const char *token, uint32_t index, const unsigned char *body, size_t body_len) {
    if (a->kind == ASM_NONE || strcmp(a->token, token) != 0) return -1;
    if (index >= a->chunks_expected) return -1;
    if (index < a->chunks_received) return 0; // duplicate chunk: ignore
    if (index != a->chunks_received) return -1; // out of order: abort
    if (body_len > (2 * MAX_PAYLOAD) / 3 + 8) return -1;
    size_t cap = body_len / 4 * 3 + 4;
    unsigned char *decoded = malloc(cap);
    if (!decoded) return -1;
    long decoded_len = b64_decode(body, body_len, decoded, cap);
    if (decoded_len < 0 || a->payload.len + (size_t)decoded_len > MAX_PAYLOAD) {
        free(decoded);
        return -1;
    }
    int rc = bb_append(&a->payload, decoded, (size_t)decoded_len);
    free(decoded);
    if (rc != 0) return -1;
    a->chunks_received++;
    return 0;
}

// ---------------------------------------------------------------------------
// Command state (one-shot EXEC)
// ---------------------------------------------------------------------------

typedef struct {
    int active;
    pid_t pid;
    pid_t pgid;
    exec_request req;
    int in_fd, out_fd, err_fd;
    int stdin_open, out_open, err_open;
    size_t stdin_off;
    size_t out_sent, err_sent;
    int section; // 0 = none, 1 = stdout, 2 = stderr
    int cancel_requested;
    int sigkill_sent;
    int abandon_deadline_set;
    int64_t cancel_deadline;
    int64_t abandon_deadline;
    int64_t last_data;
    int exited;
    int exit_code;
    char token[MAX_TOKEN];
} command_state;

static int emit_section(command_state *c, int section) {
    if (c->section == section) return 0;
    const char *name = section == 2 ? "ERR" : "OUT";
    if (emit_marker(name, c->token) != 0) return -1;
    c->section = section;
    return 0;
}

static void close_stream(int *fd, int *open) {
    if (*open && *fd >= 0) close(*fd);
    *fd = -1;
    *open = 0;
}

static void forward_stream(command_state *c, int which) {
    int fd = which == 2 ? c->err_fd : c->out_fd;
    int *open = which == 2 ? &c->err_open : &c->out_open;
    size_t *sent = which == 2 ? &c->err_sent : &c->out_sent;
    unsigned char buf[IO_CHUNK];
    for (;;) {
        ssize_t got = read(fd, buf, sizeof buf);
        if (got > 0) {
            c->last_data = now_ms();
            if (*sent < FORWARD_CAP) {
                size_t room = FORWARD_CAP - *sent;
                size_t n = (size_t)got < room ? (size_t)got : room;
                if (n > 0) {
                    if (emit_section(c, which == 2 ? 2 : 1) == 0) {
                        (void)write_all(STDOUT_FILENO, buf, n);
                    }
                    *sent += n;
                }
            }
            continue; // drain the non-blocking pipe before polling again
        }
        if (got == 0) {
            close_stream(&fd, open);
            if (which == 2) c->err_fd = -1; else c->out_fd = -1;
            return;
        }
        if (errno == EINTR) continue;
        if (errno == EAGAIN || errno == EWOULDBLOCK) return;
        close_stream(&fd, open);
        if (which == 2) c->err_fd = -1; else c->out_fd = -1;
        return;
    }
}

static void feed_stdin(command_state *c) {
    if (!c->stdin_open) return;
    for (;;) {
        if (c->stdin_off >= c->req.input_len) {
            close_stream(&c->in_fd, &c->stdin_open);
            return;
        }
        size_t left = c->req.input_len - c->stdin_off;
        ssize_t wrote = write(c->in_fd, c->req.input + c->stdin_off, left);
        if (wrote > 0) {
            c->stdin_off += (size_t)wrote;
            continue;
        }
        if (wrote < 0 && errno == EINTR) continue;
        if (wrote < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return;
        // EPIPE or another write error: the child does not want more input.
        close_stream(&c->in_fd, &c->stdin_open);
        return;
    }
}

// Kills only this command's process group (and its direct child, in case it
// left the group). Never signals anything else.
static void signal_command(command_state *c, int sig) {
    if (c->pgid > 0) kill(-c->pgid, sig);
    if (c->pid > 0) kill(c->pid, sig);
}

static void request_cancel(command_state *c) {
    if (!c->active || c->cancel_requested || c->exited) return;
    c->cancel_requested = 1;
    c->cancel_deadline = now_ms() + CANCEL_GRACE_MS;
    c->abandon_deadline = now_ms() + CANCEL_ABANDON_MS;
    c->abandon_deadline_set = 1;
    signal_command(c, SIGTERM);
}

static void enforce_cancel(command_state *c) {
    if (!c->active || !c->cancel_requested || c->exited) return;
    if (!c->sigkill_sent && now_ms() >= c->cancel_deadline) {
        c->sigkill_sent = 1;
        signal_command(c, SIGKILL);
    }
}

// ---------------------------------------------------------------------------
// PTY session
// ---------------------------------------------------------------------------

typedef struct {
    int active;
    char token[MAX_TOKEN];
    pid_t pid;
    pid_t pgid;
    int master_fd;
    unsigned char *input;
    size_t input_len;
    size_t input_off;
    size_t input_cap;
    size_t forwarded;
    int exited;
    int exit_code;
    int killed_signal; // first signal the host asked for (128+N semantics)
    int64_t last_data;
    int kill_deadline_set;
    int64_t kill_deadline;
    int sigkill_sent;
    int abandon_deadline_set;
    int64_t abandon_deadline;
} pty_session;

static void session_close_master(pty_session *s) {
    if (s->master_fd >= 0) close(s->master_fd);
    s->master_fd = -1;
}

static void session_free(pty_session *s) {
    session_close_master(s);
    free(s->input);
    memset(s, 0, sizeof *s);
    s->master_fd = -1;
}

static void session_signal(pty_session *s, int sig) {
    if (s->pgid > 0) kill(-s->pgid, sig);
    if (s->pid > 0) kill(s->pid, sig);
}

static void session_forward_output(pty_session *s) {
    unsigned char buf[IO_CHUNK];
    for (;;) {
        ssize_t got = read(s->master_fd, buf, sizeof buf);
        if (got > 0) {
            s->last_data = now_ms();
            if (s->forwarded < FORWARD_CAP) {
                size_t room = FORWARD_CAP - s->forwarded;
                size_t n = (size_t)got < room ? (size_t)got : room;
                if (n > 0) {
                    (void)emit_marker("OUT", s->token);
                    (void)write_all(STDOUT_FILENO, buf, n);
                    s->forwarded += n;
                }
            }
            continue;
        }
        if (got == 0) { session_close_master(s); return; }
        if (errno == EINTR) continue;
        if (errno == EAGAIN || errno == EWOULDBLOCK) return;
        // EIO is how a Linux pty master reports that the slave side closed.
        session_close_master(s);
        return;
    }
}

// Queues host input for the session; drops the excess beyond SESSION_INPUT_CAP
// rather than growing without bound.
static void session_queue_input(pty_session *s, const unsigned char *data, size_t len) {
    if (len == 0) return;
    if (s->input_off >= s->input_len) {
        s->input_len = 0;
        s->input_off = 0;
    }
    if (s->input_len - s->input_off + len > SESSION_INPUT_CAP) return;
    size_t used = s->input_len - s->input_off;
    if (used > 0 && s->input_off > 0) {
        memmove(s->input, s->input + s->input_off, used);
    }
    s->input_len = used;
    s->input_off = 0;
    size_t need = used + len;
    if (need > s->input_cap) {
        size_t cap = s->input_cap ? s->input_cap : 4096;
        while (cap < need) cap *= 2;
        unsigned char *grown = realloc(s->input, cap);
        if (!grown) return;
        s->input = grown;
        s->input_cap = cap;
    }
    memcpy(s->input + used, data, len);
    s->input_len = need;
}

static void session_feed_input(pty_session *s) {
    if (s->master_fd < 0 || s->input_len <= s->input_off) {
        s->input_len = 0;
        s->input_off = 0;
        return;
    }
    size_t left = s->input_len - s->input_off;
    ssize_t wrote = write(s->master_fd, s->input + s->input_off, left);
    if (wrote > 0) {
        s->input_off += (size_t)wrote;
        if (s->input_off >= s->input_len) {
            s->input_len = 0;
            s->input_off = 0;
        }
        return;
    }
    if (wrote < 0 && errno == EINTR) return;
    if (wrote < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return;
    // Input channel is gone; drop the pending bytes.
    s->input_len = 0;
    s->input_off = 0;
}

static void session_request_kill(pty_session *s, int sig) {
    if (!s->active) return;
    if (s->killed_signal == 0) s->killed_signal = sig;
    if (s->kill_deadline_set) return;
    s->kill_deadline_set = 1;
    s->kill_deadline = now_ms() + CANCEL_GRACE_MS;
    s->abandon_deadline_set = 1;
    s->abandon_deadline = now_ms() + CANCEL_ABANDON_MS;
    session_signal(s, sig);
}

static void session_enforce_kill(pty_session *s) {
    if (!s->active || !s->kill_deadline_set || s->exited || s->sigkill_sent) return;
    if (now_ms() < s->kill_deadline) return;
    s->sigkill_sent = 1;
    session_signal(s, SIGKILL);
}

static int session_done(const pty_session *s) {
    if (!s->exited) return 0;
    if (s->master_fd < 0) return 1;
    return now_ms() - s->last_data >= DRAIN_QUIET_MS;
}

// ---------------------------------------------------------------------------
// Background services (SPAWN/KILL/ALIVE)
// ---------------------------------------------------------------------------

typedef struct {
    int used;
    pid_t pid;
} spawned_slot;

typedef struct {
    int used;
    pid_t pid;
    int sigkill_sent;
    int64_t deadline;
} pending_kill;

static spawned_slot g_spawned[MAX_SPAWNED];
static pending_kill g_kills[MAX_PENDING_KILLS];

static int spawned_record(pid_t pid) {
    for (int i = 0; i < MAX_SPAWNED; i++) {
        if (!g_spawned[i].used) {
            g_spawned[i].used = 1;
            g_spawned[i].pid = pid;
            return 0;
        }
    }
    return -1;
}

static int spawned_contains(pid_t pid) {
    for (int i = 0; i < MAX_SPAWNED; i++) {
        if (g_spawned[i].used && g_spawned[i].pid == pid) return 1;
    }
    return 0;
}

static void spawned_forget(pid_t pid) {
    for (int i = 0; i < MAX_SPAWNED; i++) {
        if (g_spawned[i].used && g_spawned[i].pid == pid) g_spawned[i].used = 0;
    }
    for (int i = 0; i < MAX_PENDING_KILLS; i++) {
        if (g_kills[i].used && g_kills[i].pid == pid) g_kills[i].used = 0;
    }
}

static int kills_schedule(pid_t pid) {
    for (int i = 0; i < MAX_PENDING_KILLS; i++) {
        if (!g_kills[i].used) {
            g_kills[i].used = 1;
            g_kills[i].pid = pid;
            g_kills[i].sigkill_sent = 0;
            g_kills[i].deadline = now_ms() + KILL_ESCALATE_MS;
            return 0;
        }
    }
    return -1;
}

static void kills_enforce(void) {
    int64_t now = now_ms();
    for (int i = 0; i < MAX_PENDING_KILLS; i++) {
        if (!g_kills[i].used || g_kills[i].sigkill_sent) continue;
        if (now < g_kills[i].deadline) continue;
        g_kills[i].sigkill_sent = 1;
        g_kills[i].deadline = now + CANCEL_ABANDON_MS;
        kill(-g_kills[i].pid, SIGKILL);
        kill(g_kills[i].pid, SIGKILL);
    }
}

// ---------------------------------------------------------------------------
// Child helpers
// ---------------------------------------------------------------------------

static void child_message(const char *fmt, ...) {
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

static void child_reset_signals(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = SIG_DFL;
    (void)sigaction(SIGINT, &sa, NULL);
    (void)sigaction(SIGTERM, &sa, NULL);
    (void)sigaction(SIGHUP, &sa, NULL);
    (void)sigaction(SIGQUIT, &sa, NULL);
    (void)sigaction(SIGPIPE, &sa, NULL);
    (void)sigaction(SIGCHLD, &sa, NULL);
}

// The runner wakes from poll() when SIGCHLD arrives so background services
// are reaped promptly even while the channel is idle.
static int g_wake_pipe[2] = {-1, -1};

static void on_sigchld(int sig) {
    (void)sig;
    if (g_wake_pipe[1] >= 0) {
        ssize_t ignored = write(g_wake_pipe[1], "c", 1);
        (void)ignored;
    }
}

static void child_close_wake_pipe(void) {
    if (g_wake_pipe[0] > 2) close(g_wake_pipe[0]);
    if (g_wake_pipe[1] > 2) close(g_wake_pipe[1]);
}

// ---------------------------------------------------------------------------
// Process spawning
// ---------------------------------------------------------------------------

// The child gets its stdio from the three pipe ends and must not keep any
// other copy of the six pipe fds: a leftover write end of the child's own
// stdin pipe would keep the pipe open after the runner closes its copy, so
// the child would never see EOF.
static pid_t spawn_command_child(
    const exec_request *req,
    const char *cwd,
    int in_read,
    int in_write,
    int out_read,
    int out_write,
    int err_read,
    int err_write
) {
    pid_t pid = fork();
    if (pid < 0) return -1;
    if (pid == 0) {
        (void)setpgid(0, 0);
        child_reset_signals();
        (void)dup2(in_read, STDIN_FILENO);
        (void)dup2(out_write, STDOUT_FILENO);
        (void)dup2(err_write, STDERR_FILENO);
        close(in_read);
        close(in_write);
        close(out_read);
        close(out_write);
        close(err_read);
        close(err_write);
        child_close_wake_pipe();
        if (cwd && cwd[0] != '\0' && chdir(cwd) != 0) {
            child_message("floe-exec: chdir '%s' failed: %s\n", cwd, strerror(errno));
            _exit(126);
        }
        if (req->argc > 0 && req->argv[0][0] != '\0') {
            execvp(req->argv[0], req->argv);
            int saved = errno;
            if (saved == ENOENT) {
                child_message("floe-exec: %s: command not found\n", req->argv[0]);
            } else {
                child_message("floe-exec: %s: %s\n", req->argv[0], strerror(saved));
            }
            _exit(saved == ENOENT ? 127 : 126);
        }
        child_message("floe-exec: empty argv\n");
        _exit(127);
    }
    return pid;
}

// ---------------------------------------------------------------------------
// Mounts / environment (Linux guest bring-up)
// ---------------------------------------------------------------------------

static void set_console_raw(int fd) {
    struct termios tio;
    if (tcgetattr(fd, &tio) != 0) return; // not a tty (host tests use pipes)
    cfmakeraw(&tio);
    tio.c_cc[VMIN] = 1;
    tio.c_cc[VTIME] = 0;
    (void)tcsetattr(fd, TCSANOW, &tio);
}

static void mkdir_parents(const char *path, mode_t mode) {
    char tmp[512];
    size_t len = strlen(path);
    if (len == 0 || len >= sizeof tmp) return;
    memcpy(tmp, path, len + 1);
    for (char *p = tmp + 1; *p; p++) {
        if (*p == '/') {
            *p = '\0';
            (void)mkdir(tmp, mode);
            *p = '/';
        }
    }
}

#ifdef __linux__
static void mkdir_p(const char *path, mode_t mode) {
    mkdir_parents(path, mode);
    (void)mkdir(path, mode);
}

static void try_mount(const char *source, const char *target, const char *fstype, const char *data) {
    if (mount(source, target, fstype, 0, data) == 0) return;
    if (errno == EBUSY || errno == EPERM || errno == ENODEV || errno == ENOSYS) return;
    diag("floe-exec: mount %s on %s (%s): %s\n", source, target, fstype, strerror(errno));
}

// The kernel gives PID 1 (init=) the console as stdio and nothing else
// mounted. Everything here is best effort: a missing share or pseudo-fs must
// not stop the command channel.
static void guest_bring_up(void) {
    mkdir_p("/proc", 0755);
    mkdir_p("/sys", 0755);
    mkdir_p("/dev", 0755);
    mkdir_p("/tmp", 01777);
    mkdir_p("/run", 0755);
    try_mount("proc", "/proc", "proc", NULL);
    try_mount("sysfs", "/sys", "sysfs", NULL);
    try_mount("devtmpfs", "/dev", "devtmpfs", "mode=0755");
    mkdir_p("/dev/pts", 0755);
    mkdir_p("/dev/shm", 01777);
    try_mount("devpts", "/dev/pts", "devpts", "mode=0620,ptmxmode=0666");
    try_mount("tmpfs", "/dev/shm", "tmpfs", "mode=1777");
    try_mount("tmpfs", "/tmp", "tmpfs", "mode=1777");
    try_mount("tmpfs", "/run", "tmpfs", "mode=0755");

    struct share {
        const char *tag;
        const char *target;
    };
    static const struct share shares[] = {
        {"floe", "/floe"},
        {"floe-env", "/floe/env"},
        {"workspace", "/workspace"},
    };
    for (size_t i = 0; i < sizeof shares / sizeof shares[0]; i++) {
        mkdir_p(shares[i].target, 0755);
        try_mount(shares[i].tag, shares[i].target, "9p", "trans=virtio,version=9p2000.L");
    }
}
#else
static void guest_bring_up(void) {}
#endif

static const char *default_cwd(void) {
    const char *env = getenv("FLOE_GUEST_CWD");
    if (env && env[0] == '/' && access(env, X_OK) == 0) return env;
    if (access("/workspace", X_OK) == 0) return "/workspace";
    if (access("/floe/env", X_OK) == 0) return "/floe/env";
    if (access("/root", X_OK) == 0) return "/root";
    return "/";
}

static void set_default_environment(void) {
    const char *path = getenv("PATH");
    if (!path || path[0] == '\0') {
        setenv("PATH", "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", 1);
    }
    const char *home = getenv("HOME");
    if (!home || home[0] == '\0' || strcmp(home, "/") == 0) {
        setenv("HOME", "/root", 1);
    }
    setenv("TERM", "dumb", 0);
    setenv("TMPDIR", "/tmp", 0);
    setenv("LANG", "C.UTF-8", 0);
    setenv("DEBIAN_FRONTEND", "noninteractive", 0);
    setenv("FLOE_GUEST_RUNNER", "1", 1);
    if (access("/floe", X_OK) == 0) setenv("FLOE_SHARE_DIR", "/floe", 1);
    if (access("/floe/env", X_OK) == 0) setenv("FLOE_ENV_DIR", "/floe/env", 1);
    if (access("/workspace", X_OK) == 0) setenv("FLOE_WORKSPACE_DIR", "/workspace", 1);
#ifdef __linux__
    if (access("/root", F_OK) != 0) (void)mkdir("/root", 0700);
#endif
}

static void install_signal_handlers(void) {
    // The channel's cancel path is the 0x03 byte (raw console), never a
    // signal; keep the runner alive across console/init signals. SIGCHLD is
    // only a wake-up so reaping stays prompt.
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = SIG_IGN;
    (void)sigaction(SIGINT, &sa, NULL);
    (void)sigaction(SIGTERM, &sa, NULL);
    (void)sigaction(SIGHUP, &sa, NULL);
    (void)sigaction(SIGPIPE, &sa, NULL);

    struct sigaction chld;
    memset(&chld, 0, sizeof chld);
    chld.sa_handler = on_sigchld;
    (void)sigaction(SIGCHLD, &chld, NULL);
}

// ---------------------------------------------------------------------------
// Reaping
// ---------------------------------------------------------------------------

static void record_command_exit(command_state *c, int status) {
    c->exited = 1;
    int code;
    if (WIFEXITED(status)) code = WEXITSTATUS(status);
    else if (WIFSIGNALED(status)) code = 128 + WTERMSIG(status);
    else code = 128;
    c->exit_code = c->cancel_requested ? 130 : code;
    c->last_data = now_ms();
    close_stream(&c->in_fd, &c->stdin_open);
}

static void record_session_exit(pty_session *s, int status) {
    s->exited = 1;
    int code;
    if (WIFEXITED(status)) code = WEXITSTATUS(status);
    else if (WIFSIGNALED(status)) code = 128 + WTERMSIG(status);
    else code = 128;
    s->exit_code = code;
    s->last_data = now_ms();
    s->kill_deadline_set = 0;
}

static void reap_all(command_state *cmd, pty_session *sess) {
    for (;;) {
        int status = 0;
        pid_t p = waitpid(-1, &status, WNOHANG);
        if (p == 0) return;
        if (p < 0) {
            if (errno == EINTR) continue;
            if (errno == ECHILD) {
                if (cmd->active && !cmd->exited && cmd->pid > 0) {
                    cmd->exited = 1;
                    cmd->exit_code = cmd->cancel_requested ? 130 : 128;
                    cmd->last_data = now_ms();
                    close_stream(&cmd->in_fd, &cmd->stdin_open);
                }
                if (sess->active && !sess->exited && sess->pid > 0) {
                    sess->exited = 1;
                    sess->exit_code = 128;
                    sess->last_data = now_ms();
                }
            }
            return;
        }
        if (cmd->active && !cmd->exited && p == cmd->pid) {
            record_command_exit(cmd, status);
        } else if (sess->active && !sess->exited && p == sess->pid) {
            record_session_exit(sess, status);
        } else {
            // A background service (or an orphaned grandchild): reap it and
            // drop it from the SPAWN table so ALIVE answers honestly.
            spawned_forget(p);
        }
    }
}

// ---------------------------------------------------------------------------
// One-shot command lifecycle
// ---------------------------------------------------------------------------

static void clear_command(command_state *c) {
    close_stream(&c->in_fd, &c->stdin_open);
    close_stream(&c->out_fd, &c->out_open);
    close_stream(&c->err_fd, &c->err_open);
    exec_request_free(&c->req);
    memset(c, 0, sizeof *c);
    c->in_fd = c->out_fd = c->err_fd = -1;
}

// Emits BEGIN, an error and END for a command that could not start.
static void fail_command(command_state *c, int code, const char *message) {
    (void)emit_marker("BEGIN", c->token);
    c->section = 1;
    (void)emit_section(c, 2);
    if (message) (void)write_all(STDOUT_FILENO, message, strlen(message));
    (void)emit_end(c->token, code);
    clear_command(c);
}

// Takes ownership of req (freed on every path) and emits BEGIN first.
static void start_command(command_state *c, const char *token, exec_request *req) {
    memset(c, 0, sizeof *c);
    c->in_fd = c->out_fd = c->err_fd = -1;
    c->req = *req;
    memset(req, 0, sizeof *req);
    c->active = 1;
    snprintf(c->token, sizeof c->token, "%s", token);

    int in_pipe[2] = {-1, -1};
    int out_pipe[2] = {-1, -1};
    int err_pipe[2] = {-1, -1};
    if (pipe(in_pipe) != 0 || pipe(out_pipe) != 0 || pipe(err_pipe) != 0) {
        if (in_pipe[0] >= 0) { close(in_pipe[0]); close(in_pipe[1]); }
        if (out_pipe[0] >= 0) { close(out_pipe[0]); close(out_pipe[1]); }
        if (err_pipe[0] >= 0) { close(err_pipe[0]); close(err_pipe[1]); }
        fail_command(c, 125, "floe-exec: cannot create pipes\n");
        return;
    }

    const char *cwd = c->req.cwd && c->req.cwd[0] ? c->req.cwd : default_cwd();
    pid_t pid = spawn_command_child(
        &c->req,
        cwd,
        in_pipe[0],
        in_pipe[1],
        out_pipe[0],
        out_pipe[1],
        err_pipe[0],
        err_pipe[1]
    );
    if (pid < 0) {
        close(in_pipe[0]); close(in_pipe[1]);
        close(out_pipe[0]); close(out_pipe[1]);
        close(err_pipe[0]); close(err_pipe[1]);
        fail_command(c, 125, "floe-exec: cannot fork\n");
        return;
    }

    (void)setpgid(pid, pid); // best effort; the child also does this itself
    c->pid = pid;
    c->pgid = pid;
    close(in_pipe[0]);
    close(out_pipe[1]);
    close(err_pipe[1]);
    c->in_fd = in_pipe[1];
    c->out_fd = out_pipe[0];
    c->err_fd = err_pipe[0];
    c->out_open = 1;
    c->err_open = 1;
    set_nonblocking(c->in_fd);
    set_nonblocking(c->out_fd);
    set_nonblocking(c->err_fd);

    // The host parser waits for BEGIN before assigning output sections, so it
    // must be the first bytes written for this command.
    if (emit_marker("BEGIN", c->token) != 0) {
        signal_command(c, SIGKILL);
        clear_command(c);
        return;
    }
    c->section = 1; // stdout is the implicit section right after BEGIN

    if (c->req.input_len == 0) {
        close(c->in_fd);
        c->in_fd = -1;
        c->stdin_open = 0;
    } else {
        c->stdin_open = 1;
    }
}

static int command_drain_done(const command_state *c) {
    if (!c->exited) return 0;
    if (!c->out_open && !c->err_open) return 1;
    return now_ms() - c->last_data >= DRAIN_QUIET_MS;
}

static void finish_command(command_state *c) {
    int code = c->cancel_requested ? 130 : c->exit_code;
    // Final bounded drain for anything already buffered in the pipes.
    for (int i = 0; i < 64 && (c->out_open || c->err_open); i++) {
        int before = c->out_open + c->err_open;
        if (c->out_open) forward_stream(c, 1);
        if (c->err_open) forward_stream(c, 2);
        if (c->out_open + c->err_open == before) break;
    }
    close_stream(&c->in_fd, &c->stdin_open);
    close_stream(&c->out_fd, &c->out_open);
    close_stream(&c->err_fd, &c->err_open);
    (void)emit_end(c->token, code);
    exec_request_free(&c->req);
    memset(c, 0, sizeof *c);
    c->in_fd = c->out_fd = c->err_fd = -1;
}

// Abandons a child that cannot be killed (uninterruptible sleep). The status
// is collected later by reap_all so no zombie accumulates.
static void abandon_command(command_state *c) {
    close_stream(&c->in_fd, &c->stdin_open);
    close_stream(&c->out_fd, &c->out_open);
    close_stream(&c->err_fd, &c->err_open);
    (void)emit_end(c->token, 130);
    exec_request_free(&c->req);
    memset(c, 0, sizeof *c);
    c->in_fd = c->out_fd = c->err_fd = -1;
}

// ---------------------------------------------------------------------------
// PTY session lifecycle
// ---------------------------------------------------------------------------

static void finish_session(pty_session *s) {
    for (int i = 0; i < 64 && s->master_fd >= 0; i++) {
        size_t before = s->forwarded;
        session_forward_output(s);
        if (s->forwarded == before && s->master_fd >= 0) break;
    }
    session_close_master(s);
    int code = s->exit_code;
    if (s->killed_signal != 0) code = 128 + s->killed_signal;
    (void)emit_end(s->token, code);
    session_free(s);
    s->master_fd = -1;
}

// Abandons a session whose process cannot be killed; the pty is closed and
// the host gets an END so the channel never hangs.
static void abandon_session(pty_session *s) {
    session_close_master(s);
    int code = s->killed_signal != 0 ? 128 + s->killed_signal : (s->exit_code ? s->exit_code : 128);
    (void)emit_end(s->token, code);
    session_free(s);
    s->master_fd = -1;
}

static void start_session(command_state *cmd, pty_session *s, const char *token,
                          open_request *req) {
    memset(s, 0, sizeof *s);
    s->master_fd = -1;

    int master = posix_openpt(O_RDWR);
    if (master < 0 || grantpt(master) != 0 || unlockpt(master) != 0) {
        if (master >= 0) close(master);
        emit_failure(token, 0, 125, "floe-exec: cannot allocate a pty");
        return;
    }
    const char *slave_name = ptsname(master);
    if (!slave_name) {
        close(master);
        emit_failure(token, 0, 125, "floe-exec: cannot name the pty slave");
        return;
    }
    char slave_path[256];
    snprintf(slave_path, sizeof slave_path, "%s", slave_name);

    struct winsize ws;
    memset(&ws, 0, sizeof ws);
    ws.ws_col = (unsigned short)req->cols;
    ws.ws_row = (unsigned short)req->rows;
    (void)ioctl(master, TIOCSWINSZ, &ws);

    const char *cwd = req->cwd && req->cwd[0] ? req->cwd : default_cwd();
    pid_t pid = fork();
    if (pid < 0) {
        close(master);
        emit_failure(token, 0, 125, "floe-exec: cannot fork the session");
        return;
    }
    if (pid == 0) {
        (void)setsid();
        child_reset_signals();
        int slave = open(slave_path, O_RDWR);
        if (slave < 0) {
            // The console is still the runner's: never write unframed text
            // between frames. The parent reports END 126.
            _exit(126);
        }
        (void)ioctl(slave, TIOCSCTTY, 0);
        (void)ioctl(slave, TIOCSWINSZ, &ws);
        (void)dup2(slave, STDIN_FILENO);
        (void)dup2(slave, STDOUT_FILENO);
        (void)dup2(slave, STDERR_FILENO);
        if (slave > STDERR_FILENO) close(slave);
        close(master);
        child_close_wake_pipe();
        if (cwd && cwd[0] != '\0' && chdir(cwd) != 0) {
            child_message("floe-exec: chdir '%s' failed: %s\n", cwd, strerror(errno));
            _exit(126);
        }
        if (req->argc > 0 && req->argv[0][0] != '\0') {
            execvp(req->argv[0], req->argv);
            int saved = errno;
            if (saved == ENOENT) {
                child_message("floe-exec: %s: command not found\n", req->argv[0]);
            } else {
                child_message("floe-exec: %s: %s\n", req->argv[0], strerror(saved));
            }
            _exit(saved == ENOENT ? 127 : 126);
        }
        child_message("floe-exec: empty argv\n");
        _exit(127);
    }

    set_nonblocking(master);
    s->active = 1;
    snprintf(s->token, sizeof s->token, "%s", token);
    s->pid = pid;
    s->pgid = pid;
    s->master_fd = master;
    s->last_data = now_ms();
    (void)cmd; // sessions and commands are mutually exclusive
    (void)emit_marker("BEGIN", s->token);
}

// ---------------------------------------------------------------------------
// Background services
// ---------------------------------------------------------------------------

static void do_spawn(const char *token, const unsigned char *payload, size_t plen) {
    spawn_request req;
    if (spawn_request_parse(payload, plen, &req) != 0) {
        emit_failure(token, 0, 125, "floe-exec: malformed SPAWN payload");
        return;
    }
    if (req.cwd && req.cwd[0] != '\0') {
        mkdir_parents(req.cwd, 0755);
    }
    mkdir_parents(req.log_path, 0755);

    const char *cwd = req.cwd && req.cwd[0] ? req.cwd : default_cwd();
    pid_t pid = fork();
    if (pid < 0) {
        emit_failure(token, 0, 125, "floe-exec: cannot fork the service");
        spawn_request_free(&req);
        return;
    }
    if (pid == 0) {
        (void)setsid();
        child_reset_signals();
        int nullfd = open("/dev/null", O_RDWR);
        if (nullfd >= 0) {
            (void)dup2(nullfd, STDIN_FILENO);
            if (nullfd > STDERR_FILENO) close(nullfd);
        }
        int logfd = open(req.log_path, O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (logfd < 0) {
            // stdout/stderr are still the runner's console here; stay silent
            // and let the reap path report the service as gone.
            _exit(126);
        }
        (void)dup2(logfd, STDOUT_FILENO);
        (void)dup2(logfd, STDERR_FILENO);
        if (logfd > STDERR_FILENO) close(logfd);
        child_close_wake_pipe();
        if (cwd && cwd[0] != '\0' && chdir(cwd) != 0) {
            child_message("floe-exec: chdir '%s' failed: %s\n", cwd, strerror(errno));
            _exit(126);
        }
        if (req.argc > 0 && req.argv[0][0] != '\0') {
            execvp(req.argv[0], req.argv);
            int saved = errno;
            if (saved == ENOENT) {
                child_message("floe-exec: %s: command not found\n", req.argv[0]);
            } else {
                child_message("floe-exec: %s: %s\n", req.argv[0], strerror(saved));
            }
            _exit(saved == ENOENT ? 127 : 126);
        }
        child_message("floe-exec: empty argv\n");
        _exit(127);
    }

    if (spawned_record(pid) != 0) {
        kill(-pid, SIGKILL);
        kill(pid, SIGKILL);
        emit_failure(token, 0, 125, "floe-exec: background service table is full");
        spawn_request_free(&req);
        return;
    }
    char pid_marker[MAX_TOKEN + 64];
    int n = snprintf(pid_marker, sizeof pid_marker, "\x1e" "FLOE-PID %s %ld\x1e", token, (long)pid);
    if (n > 0 && (size_t)n < sizeof pid_marker) {
        (void)write_all(STDOUT_FILENO, pid_marker, (size_t)n);
    }
    (void)emit_end(token, 0);
    spawn_request_free(&req);
}

// ---------------------------------------------------------------------------
// Inbound frame dispatch
// ---------------------------------------------------------------------------

typedef struct {
    command_state *cmd;
    pty_session *session;
    assembly *asm_state;
} guest_state;

static int parse_two_decimals(const unsigned char *args, size_t len, size_t *first, uint32_t *second) {
    char buf[64];
    if (len == 0 || len >= sizeof buf) return -1;
    memcpy(buf, args, len);
    buf[len] = '\0';
    char *end = NULL;
    errno = 0;
    long a = strtol(buf, &end, 10);
    if (errno != 0 || !end || end == buf || *end != ' ') return -1;
    char *end2 = NULL;
    errno = 0;
    long b = strtol(end + 1, &end2, 10);
    if (errno != 0 || !end2 || end2 == end + 1 || *end2 != '\0') return -1;
    if (a < 0 || (unsigned long)a > MAX_PAYLOAD) return -1;
    if (b <= 0 || (unsigned long)b > MAX_CHUNKS) return -1;
    *first = (size_t)a;
    *second = (uint32_t)b;
    return 0;
}

static int start_exec_payload(command_state *cmd, pty_session *sess, const char *token,
                              const unsigned char *payload, size_t plen) {
    exec_request req;
    if (exec_request_parse(payload, plen, &req) != 0) {
        emit_failure(token, 1, 125, "floe-exec: malformed EXEC payload");
        return -1;
    }
    if (cmd->active || sess->active) {
        exec_request_free(&req);
        emit_failure(token, 1, 125, "floe-exec: guest is busy with another command or session");
        return -1;
    }
    start_command(cmd, token, &req);
    return 0;
}

static int start_open_payload(command_state *cmd, pty_session *sess, const char *token,
                              const unsigned char *payload, size_t plen) {
    open_request req;
    if (open_request_parse(payload, plen, &req) != 0) {
        emit_failure(token, 0, 125, "floe-exec: malformed OPEN payload");
        return -1;
    }
    if (!req.mode || strcmp(req.mode, "pty") != 0) {
        open_request_free(&req);
        emit_failure(token, 0, 125, "floe-exec: unsupported OPEN mode");
        return -1;
    }
    if (cmd->active || sess->active) {
        open_request_free(&req);
        emit_failure(token, 0, 125, "floe-exec: guest is busy with another command or session");
        return -1;
    }
    start_session(cmd, sess, token, &req);
    open_request_free(&req);
    return 0;
}

static void handle_frame(guest_state *st, const unsigned char *body, size_t len) {
    const unsigned char *name_end = memchr(body, ' ', len);
    if (!name_end) return;
    size_t name_len = (size_t)(name_end - body);
    const unsigned char *rest = name_end + 1;
    size_t rest_len = len - name_len - 1;

    const unsigned char *token_end = memchr(rest, ' ', rest_len);
    size_t token_len = token_end ? (size_t)(token_end - rest) : rest_len;
    if (token_len == 0 || token_len >= MAX_TOKEN) return;
    char token[MAX_TOKEN];
    memcpy(token, rest, token_len);
    token[token_len] = '\0';
    for (size_t i = 0; i < token_len; i++) {
        if ((unsigned char)token[i] < 0x21 || (unsigned char)token[i] > 0x7e) return;
    }
    const unsigned char *args = token_end ? token_end + 1 : rest + rest_len;
    size_t args_len = token_end ? rest_len - token_len - 1 : 0;

    command_state *cmd = st->cmd;
    pty_session *sess = st->session;
    assembly *asm_state = st->asm_state;

    if (name_len == 4 && memcmp(body, "EXEC", 4) == 0) {
        size_t payload_bytes = 0;
        uint32_t chunks = 0;
        if (parse_two_decimals(args, args_len, &payload_bytes, &chunks) == 0) {
            asm_begin(asm_state, ASM_EXEC, token, payload_bytes, chunks);
            return;
        }
        size_t cap = args_len / 4 * 3 + 4;
        unsigned char *payload = malloc(cap);
        if (!payload) {
            emit_failure(token, 1, 125, "floe-exec: cannot allocate the EXEC payload");
            return;
        }
        long decoded = b64_decode(args, args_len, payload, cap);
        if (decoded < 0) {
            free(payload);
            emit_failure(token, 1, 125, "floe-exec: malformed inline EXEC payload");
            return;
        }
        (void)start_exec_payload(cmd, sess, token, payload, (size_t)decoded);
        free(payload);
        return;
    }

    if (name_len == 4 && memcmp(body, "OPEN", 4) == 0) {
        size_t payload_bytes = 0;
        uint32_t chunks = 0;
        if (parse_two_decimals(args, args_len, &payload_bytes, &chunks) != 0) return;
        asm_begin(asm_state, ASM_OPEN, token, payload_bytes, chunks);
        return;
    }

    if (name_len == 5 && memcmp(body, "SPAWN", 5) == 0) {
        size_t payload_bytes = 0;
        uint32_t chunks = 0;
        if (parse_two_decimals(args, args_len, &payload_bytes, &chunks) != 0) return;
        asm_begin(asm_state, ASM_SPAWN, token, payload_bytes, chunks);
        return;
    }

    if (name_len == 5 && memcmp(body, "CHUNK", 5) == 0) {
        const unsigned char *index_end = memchr(args, ' ', args_len);
        if (!index_end) return;
        char index_buf[16];
        size_t index_len = (size_t)(index_end - args);
        if (index_len == 0 || index_len >= sizeof index_buf) return;
        memcpy(index_buf, args, index_len);
        index_buf[index_len] = '\0';
        char *index_tail = NULL;
        errno = 0;
        long index = strtol(index_buf, &index_tail, 10);
        if (errno != 0 || !index_tail || *index_tail != '\0' || index < 0) return;
        const unsigned char *chunk_body = index_end + 1;
        size_t chunk_len = args_len - index_len - 1;
        if (asm_chunk(asm_state, token, (uint32_t)index, chunk_body, chunk_len) != 0) {
            asm_reset(asm_state);
        }
        return;
    }

    if (name_len == 3 && memcmp(body, "RUN", 3) == 0) {
        if (asm_state->kind == ASM_NONE || strcmp(asm_state->token, token) != 0) return;
        if (asm_state->chunks_received != asm_state->chunks_expected ||
            asm_state->payload.len != asm_state->expected) {
            emit_failure(token, asm_state->kind == ASM_EXEC, 125,
                         "floe-exec: incomplete chunked payload");
            asm_reset(asm_state);
            return;
        }
        int kind = asm_state->kind;
        unsigned char *payload = asm_state->payload.data;
        size_t plen = asm_state->payload.len;
        asm_state->payload.data = NULL;
        asm_state->payload.len = 0;
        asm_state->payload.cap = 0;
        asm_reset(asm_state);
        if (kind == ASM_EXEC) {
            (void)start_exec_payload(cmd, sess, token, payload, plen);
        } else if (kind == ASM_OPEN) {
            (void)start_open_payload(cmd, sess, token, payload, plen);
        } else {
            do_spawn(token, payload, plen);
        }
        free(payload);
        return;
    }

    if (name_len == 2 && memcmp(body, "IN", 2) == 0) {
        if (!sess->active || strcmp(sess->token, token) != 0) return;
        size_t cap = args_len / 4 * 3 + 4;
        unsigned char *decoded = malloc(cap);
        if (!decoded) return;
        long decoded_len = b64_decode(args, args_len, decoded, cap);
        if (decoded_len > 0) {
            session_queue_input(sess, decoded, (size_t)decoded_len);
        }
        free(decoded);
        return;
    }

    if (name_len == 6 && memcmp(body, "SIGNAL", 6) == 0) {
        if (!sess->active || strcmp(sess->token, token) != 0) return;
        if (args_len >= 3 && memcmp(args, "INT", 3) == 0) {
            session_request_kill(sess, SIGINT);
        } else if (args_len >= 4 && memcmp(args, "TERM", 4) == 0) {
            session_request_kill(sess, SIGTERM);
        } else if (args_len >= 5 && memcmp(args, "WINCH", 5) == 0) {
            unsigned char rows_buf[16] = {0};
            unsigned char cols_buf[16] = {0};
            long rows = 0, cols = 0;
            if (args_len > 6) {
                const unsigned char *p = args + 6;
                size_t remaining = args_len - 6;
                const unsigned char *space = memchr(p, ' ', remaining);
                if (space) {
                    size_t rlen = (size_t)(space - p);
                    size_t clen = remaining - rlen - 1;
                    if (rlen < sizeof rows_buf && clen < sizeof cols_buf) {
                        memcpy(rows_buf, p, rlen);
                        memcpy(cols_buf, space + 1, clen);
                        char *end1 = NULL, *end2 = NULL;
                        errno = 0;
                        rows = strtol((char *)rows_buf, &end1, 10);
                        cols = strtol((char *)cols_buf, &end2, 10);
                        if (errno != 0 || !end1 || *end1 || !end2 || *end2) return;
                    }
                }
            }
            if (rows > 0 && cols > 0 && sess->master_fd >= 0) {
                struct winsize ws;
                memset(&ws, 0, sizeof ws);
                ws.ws_row = (unsigned short)rows;
                ws.ws_col = (unsigned short)cols;
                (void)ioctl(sess->master_fd, TIOCSWINSZ, &ws);
                if (sess->pgid > 0) kill(-sess->pgid, SIGWINCH);
            }
        }
        return;
    }

    if (name_len == 5 && memcmp(body, "CLOSE", 5) == 0) {
        if (sess->active && strcmp(sess->token, token) == 0) {
            session_request_kill(sess, SIGTERM);
        }
        return;
    }

    if (name_len == 4 && memcmp(body, "KILL", 4) == 0) {
        char pid_buf[32];
        if (args_len == 0 || args_len >= sizeof pid_buf) return;
        memcpy(pid_buf, args, args_len);
        pid_buf[args_len] = '\0';
        char *end = NULL;
        errno = 0;
        long pid = strtol(pid_buf, &end, 10);
        if (errno != 0 || !end || *end != '\0' || pid <= 0) {
            (void)emit_end(token, 3);
            return;
        }
        if (!spawned_contains((pid_t)pid)) {
            (void)emit_end(token, 3); // never signal a pid we do not own
            return;
        }
        kill(-(pid_t)pid, SIGTERM);
        kill((pid_t)pid, SIGTERM);
        (void)kills_schedule((pid_t)pid);
        (void)emit_end(token, 0);
        return;
    }

    if (name_len == 5 && memcmp(body, "ALIVE", 5) == 0) {
        char pid_buf[32];
        if (args_len == 0 || args_len >= sizeof pid_buf) return;
        memcpy(pid_buf, args, args_len);
        pid_buf[args_len] = '\0';
        char *end = NULL;
        errno = 0;
        long pid = strtol(pid_buf, &end, 10);
        if (errno != 0 || !end || *end != '\0' || pid <= 0) {
            (void)emit_end(token, 3);
            return;
        }
        (void)emit_end(token, spawned_contains((pid_t)pid) ? 0 : 3);
        return;
    }
}

static void dispatch_inbound(guest_state *st, bytebuf *in) {
    static const char prefix[] = "\x1e" "FLOE-";
    const size_t prefix_len = sizeof prefix - 1;
    for (;;) {
        if (in->len == 0) return;
        unsigned char *mark = memchr(in->data, FLOE_MARK, in->len);
        if (!mark) {
            bb_consume(in, in->len); // noise between frames
            return;
        }
        size_t skip = (size_t)(mark - in->data);
        if (skip > 0) bb_consume(in, skip);
        if (in->len < prefix_len) return; // possibly a split prefix
        if (memcmp(in->data, prefix, prefix_len) != 0) {
            bb_consume(in, 1);
            continue;
        }
        unsigned char *newline = memchr(in->data, '\n', in->len);
        unsigned char *closing = NULL;
        for (size_t i = 1; i < in->len; i++) {
            if (in->data[i] == FLOE_MARK) {
                closing = in->data + i;
                break;
            }
        }
        size_t line_len = 0;
        size_t consume = 0;
        if (newline && (!closing || newline < closing)) {
            line_len = (size_t)(newline - in->data);
            consume = line_len + 1;
        } else if (closing) {
            line_len = (size_t)(closing - in->data);
            consume = line_len + 1;
            if (consume < in->len && in->data[consume] == '\n') consume++;
        } else {
            if (in->len > MAX_INBOUND) bb_consume(in, in->len);
            return; // incomplete frame
        }
        if (line_len > prefix_len) {
            handle_frame(st, in->data + prefix_len, line_len - prefix_len);
        }
        bb_consume(in, consume);
    }
}

// ---------------------------------------------------------------------------
// Main loop
// ---------------------------------------------------------------------------

int main(void) {
    if (getpid() == 1 || getenv("FLOE_GUEST_INIT") != NULL) {
        guest_bring_up();
    }
    if (pipe(g_wake_pipe) == 0) {
        set_nonblocking(g_wake_pipe[0]);
        set_nonblocking(g_wake_pipe[1]);
    }
    install_signal_handlers();
    set_default_environment();
    int console = STDIN_FILENO;
    set_console_raw(console);

    bytebuf inbound = {0};
    command_state cmd;
    memset(&cmd, 0, sizeof cmd);
    cmd.in_fd = cmd.out_fd = cmd.err_fd = -1;
    pty_session sess;
    memset(&sess, 0, sizeof sess);
    sess.master_fd = -1;
    assembly asm_state;
    memset(&asm_state, 0, sizeof asm_state);
    guest_state st = {&cmd, &sess, &asm_state};

    for (;;) {
        struct pollfd fds[8];
        int n = 0;
        int i_console = n++;
        fds[i_console].fd = console;
        fds[i_console].events = POLLIN;
        fds[i_console].revents = 0;

        int i_wake = -1;
        if (g_wake_pipe[0] >= 0) {
            i_wake = n++;
            fds[i_wake].fd = g_wake_pipe[0];
            fds[i_wake].events = POLLIN;
            fds[i_wake].revents = 0;
        }
        int i_out = -1, i_err = -1, i_in = -1, i_master = -1, i_min = -1;
        if (cmd.active) {
            if (cmd.out_open && cmd.out_fd >= 0) {
                i_out = n++;
                fds[i_out].fd = cmd.out_fd;
                fds[i_out].events = POLLIN;
                fds[i_out].revents = 0;
            }
            if (cmd.err_open && cmd.err_fd >= 0) {
                i_err = n++;
                fds[i_err].fd = cmd.err_fd;
                fds[i_err].events = POLLIN;
                fds[i_err].revents = 0;
            }
            if (cmd.stdin_open && cmd.in_fd >= 0) {
                i_in = n++;
                fds[i_in].fd = cmd.in_fd;
                fds[i_in].events = POLLOUT;
                fds[i_in].revents = 0;
            }
        } else if (sess.active) {
            if (sess.master_fd >= 0) {
                i_master = n++;
                fds[i_master].fd = sess.master_fd;
                fds[i_master].events = POLLIN;
                fds[i_master].revents = 0;
                if (sess.input_len > sess.input_off) {
                    i_min = n++;
                    fds[i_min].fd = sess.master_fd;
                    fds[i_min].events = POLLOUT;
                    fds[i_min].revents = 0;
                }
            }
        }

        int timeout = (cmd.active || sess.active) ? POLL_SLICE_MS : -1;
        int ready = poll(fds, (nfds_t)n, timeout);
        if (ready < 0) {
            if (errno == EINTR) continue;
            sleep_ms(10);
            continue;
        }

        if (i_wake >= 0 && (fds[i_wake].revents & POLLIN)) {
            unsigned char drain[64];
            while (read(g_wake_pipe[0], drain, sizeof drain) > 0) {
                // Drain the wake bytes; reaping happens below.
            }
        }

        if (fds[i_console].revents & (POLLIN | POLLHUP | POLLERR)) {
            unsigned char chunk[IO_CHUNK];
            ssize_t got = read(console, chunk, sizeof chunk);
            if (got > 0) {
                for (ssize_t i = 0; i < got; i++) {
                    if (chunk[i] == FLOE_CANCEL) {
                        if (cmd.active) {
                            request_cancel(&cmd);
                        } else if (sess.active) {
                            session_request_kill(&sess, SIGINT);
                        }
                        continue;
                    }
                    if (inbound.len + 1 > MAX_INBOUND) bb_consume(&inbound, inbound.len);
                    if (bb_append(&inbound, &chunk[i], 1) != 0) {
                        bb_consume(&inbound, inbound.len);
                    }
                }
                dispatch_inbound(&st, &inbound);
                continue; // poll set may have changed (command/session started)
            }
            if (got == 0) {
                // Console EOF: the guest is being stopped.
                if (cmd.active) signal_command(&cmd, SIGKILL);
                if (sess.active) session_signal(&sess, SIGKILL);
                bb_free(&inbound);
                clear_command(&cmd);
                session_free(&sess);
                asm_reset(&asm_state);
                return 0;
            }
            if (errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) {
                bb_free(&inbound);
                return 0;
            }
        }

        if (cmd.active) {
            if (i_out >= 0 && (fds[i_out].revents & (POLLIN | POLLHUP | POLLERR))) {
                forward_stream(&cmd, 1);
            }
            if (i_err >= 0 && (fds[i_err].revents & (POLLIN | POLLHUP | POLLERR))) {
                forward_stream(&cmd, 2);
            }
            if (i_in >= 0 && (fds[i_in].revents & (POLLOUT | POLLERR | POLLHUP))) {
                feed_stdin(&cmd);
            }
            reap_all(&cmd, &sess);
            enforce_cancel(&cmd);
            if (cmd.active && cmd.cancel_requested && cmd.abandon_deadline_set &&
                !cmd.exited && now_ms() >= cmd.abandon_deadline) {
                abandon_command(&cmd);
            } else if (cmd.active && cmd.exited && command_drain_done(&cmd)) {
                finish_command(&cmd);
            }
        } else if (sess.active) {
            if (i_master >= 0 && (fds[i_master].revents & (POLLIN | POLLHUP | POLLERR))) {
                session_forward_output(&sess);
            }
            if (i_min >= 0 && (fds[i_min].revents & (POLLOUT | POLLERR | POLLHUP))) {
                session_feed_input(&sess);
            }
            reap_all(&cmd, &sess);
            session_enforce_kill(&sess);
            if (sess.active && sess.abandon_deadline_set && !sess.exited &&
                now_ms() >= sess.abandon_deadline) {
                abandon_session(&sess);
            } else if (sess.active && session_done(&sess)) {
                finish_session(&sess);
            }
        } else {
            reap_all(&cmd, &sess);
        }
        kills_enforce();
    }
}
