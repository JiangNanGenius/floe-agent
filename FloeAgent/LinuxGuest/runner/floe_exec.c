// floe_exec.c — Floe Linux guest command runner (protocol 3).
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
// Capability negotiation (protocol 3)
// -----------------------------------
// The host opens the channel with `\x1eFLOE-HELLO <token>\x1e` and the
// runner answers `FLOE-CAPS <token> runner=<version> protocol=3
// maxCommands=N maxSessions=M` + `FLOE-END <token> 0`. Older hosts never
// send HELLO and are still served (one command at a time is a host choice,
// not a guest requirement).
//
// One-shot commands — CONCURRENT
// ------------------------------
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
// Up to MAX_CONCURRENT_COMMANDS commands run in parallel, each with its own
// pipes, cwd, process group and cancellation state. Every response frame
// carries the command's token, so the host demultiplexes. Only a full
// command table rejects a new EXEC (END 125, "command table full").
//
// Interactive PTY sessions — CONCURRENT
// -------------------------------------
//   OPEN payload fields = [mode="pty", cwd, cols, rows, argv0, argv1, ...]
//   host input:  \x1eFLOE-IN <token> <base64>\n
//   signals:     \x1eFLOE-SIGNAL <token> INT|TERM|KILL|WINCH <rows> <cols>\x1e
//   close:       \x1eFLOE-CLOSE <token>\x1e
//   guest: BEGIN, OUT stream (pty merged output), END with the real status
//   (128+signal when the host initiated INT/TERM/KILL).
// Up to MAX_CONCURRENT_SESSIONS independent PTYs run at the same time;
// IN/SIGNAL/CLOSE are routed by token. Only a full session table rejects an
// OPEN (END 125, "session table full").
//
// Background services (prioritized control channel)
// -------------------------------------------------
//   SPAWN payload fields = [cwd, logPath, argv0, argv1, ...]
//   guest: \x1eFLOE-PID <token> <pid>\x1e + \x1eFLOE-END <token> 0\x1e (never
//   waits for the process); stdout/stderr are appended to logPath.
//   \x1eFLOE-KILL <token> <pid>\x1e  -> END 0 (owned pid) or END 3 (unknown)
//   \x1eFLOE-ALIVE <token> <pid>\x1e -> END 0 (owned/alive) or END 3
// Only pids this runner spawned are ever signalled (bounded table). Control
// frames are accepted at any time, including while commands/sessions run.
//
// Cancellation and truthful termination
// -------------------------------------
// Targeted: `\x1eFLOE-SIGNAL <token> INT|TERM|KILL\x1e` interrupts exactly
// one command or session's process group. Legacy: a raw 0x03 byte cancels
// every in-flight command (the console is in raw mode, so it is a byte, not
// SIGINT). Escalation is TERM (or the requested signal), SIGKILL after a
// grace period, then reaping. END is emitted ONLY after the process group is
// actually reaped. A child that cannot be killed within a hard deadline is
// quarantined: the runner emits `\x1eFLOE-FAILED <token> unreaped\x1e`
// instead of END and never claims the process stopped; the pid stays in a
// bounded unreaped table until waitpid collects it, and the host treats the
// guest as failed (VM reset), never as cleanly stopped.
//
// argv is executed verbatim with execvp (never through a shell), stdin is
// the decoded `stdin` field followed by EOF, stdout and stderr are streamed
// as separate framed sections, and the exit code is the child's real wait
// status (128+signal when it dies from a signal).
//
// Boot clock: on Linux, when this process is PID 1, the runner applies the
// host-supplied wall clock (`floe.epoch=<unix seconds>` on the kernel command
// line) after mounting /proc and before serving any frame. Parsing is strict
// and side-effect free (floe_clock.h): exactly one canonical numeric token,
// bounded read, no shell, no other parameter. A missing, invalid,
// out-of-range or duplicated value produces one bounded stderr diagnostic and
// never a fake "synchronized" claim. The native host build (and any
// non-PID-1 harness) never changes the host clock.
//
// Console discipline: nothing unframed is written between frames. Boot-time
// diagnostics (mount failures, clock state) go to stderr and are discarded by
// the host parser before the first BEGIN.
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
#include <sys/time.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

#include "floe_clock.h"
#include "floe_net.h"
#include "floe_host_archive.h"

#ifdef __linux__
#include <sys/mount.h>
#include <sys/sysmacros.h>
#endif

#define FLOE_MARK 0x1e
#define FLOE_CANCEL 0x03

#define FLOE_RUNNER_VERSION "2.0.0"
#define FLOE_PROTOCOL_VERSION 3

// Last reported network state, exposed in the CAPS answer (`net=...`) so the
// host can report readiness honestly instead of assuming slirp means working
// DNS. Native builds keep it at FLOE_NET_DOWN and never touch the host.
static floe_net_status g_net_status = FLOE_NET_DOWN;

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
// If a cancelled child cannot be killed within this window, it is
// quarantined (FAILED, never END) so the channel never hangs.
#define CANCEL_ABANDON_MS 5000
// After a child is reaped, keep draining pipes until they are quiet for this
// long (a grandchild may still hold them open).
#define DRAIN_QUIET_MS 400
#define POLL_SLICE_MS 20
// Buffered host input for one PTY session (base64 FLOE-IN frames).
#define SESSION_INPUT_CAP (1024 * 1024)
// Concurrency tables.
#define MAX_CONCURRENT_COMMANDS 8
#define MAX_CONCURRENT_SESSIONS 4
#define MAX_ASSEMBLIES 8
// A cancelled child that survives SIGKILL is quarantined here until waitpid
// collects it; bounded so the table can never grow without limit.
#define MAX_UNREAPED 16
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

// Current console section owner: which token's unmarked bytes belong to.
// With concurrent commands and sessions the runner must re-announce a
// token's section every time another token has written since the last frame
// — the host router attributes bytes with no frame marker to the last
// BEGIN/OUT/ERR owner, so a per-command flag is not enough. The runner is a
// single event loop, so one global owner is exact.
static char g_section_token[MAX_TOKEN];
static int g_section_kind; // 0 = none, 1 = stdout (OUT), 2 = stderr (ERR)

// Optional floe-host archive bridge: the host advertises the action set it
// will serve in HELLO; an empty set keeps the command disabled.
static floe_host_caps g_host_caps;

// A guest command waiting for a host archive reply must not hang forever even
// if the console dies; the host's own command timeout still applies.
#define HOST_ARCHIVE_TIMEOUT_MS 300000

static void section_mark(const char *token, int kind) {
    snprintf(g_section_token, sizeof g_section_token, "%s", token);
    g_section_kind = kind;
}

static void section_release(const char *token) {
    if (g_section_kind != 0 && strcmp(g_section_token, token) == 0) {
        g_section_token[0] = '\0';
        g_section_kind = 0;
    }
}

// Emits the token's section marker unless that section is already the
// current owner; returns 0 when the bytes may be written.
static int ensure_section(const char *token, int kind) {
    if (g_section_kind == kind && strcmp(g_section_token, token) == 0) return 0;
    if (emit_marker(kind == 2 ? "ERR" : "OUT", token) != 0) return -1;
    section_mark(token, kind);
    return 0;
}

static int emit_end(const char *token, int code) {
    char buf[MAX_TOKEN + 48];
    int n = snprintf(buf, sizeof buf, "\x1e" "FLOE-END %s %d\x1e", token, code);
    if (n <= 0 || (size_t)n >= sizeof buf) return -1;
    return write_all(STDOUT_FILENO, buf, (size_t)n);
}

// Distinct failure frame for a token whose process was abandoned alive: the
// host must treat the guest as failed (quarantine/reset), never as stopped.
static int emit_failed(const char *token, const char *reason) {
    char buf[MAX_TOKEN + 64];
    int n = snprintf(buf, sizeof buf, "\x1e" "FLOE-FAILED %s %s\x1e", token, reason);
    if (n <= 0 || (size_t)n >= sizeof buf) return -1;
    return write_all(STDOUT_FILENO, buf, (size_t)n);
}

// Capability answer to FLOE-HELLO.
static int emit_caps(const char *token) {
    char buf[MAX_TOKEN + 128];
    int n = snprintf(buf, sizeof buf,
                     "\x1e" "FLOE-CAPS %s runner=%s protocol=%d maxCommands=%d maxSessions=%d net=%s hostArchive=%s\x1e",
                     token, FLOE_RUNNER_VERSION, FLOE_PROTOCOL_VERSION,
                     MAX_CONCURRENT_COMMANDS, MAX_CONCURRENT_SESSIONS,
                     floe_net_status_text(g_net_status),
                     g_host_caps.value[0] ? g_host_caps.value : "none");
    if (n <= 0 || (size_t)n >= sizeof buf) return -1;
    if (write_all(STDOUT_FILENO, buf, (size_t)n) != 0) return -1;
    return emit_end(token, 0);
}

// Error text followed by END, shared by the failure frames. Nothing is
// written when the token is empty (already rejected by handle_frame).
static void emit_message(const char *message) {
    if (!message || message[0] == '\0') return;
    size_t len = strlen(message);
    (void)write_all(STDOUT_FILENO, message, len);
    if (message[len - 1] != '\n') (void)write_all(STDOUT_FILENO, "\n", 1);
}

// BEGIN + ERR + END, used when a command frame cannot be served (table full,
// malformed payload, failed setup). BEGIN is required by the host command
// parser, which ignores everything before it (or before FAILED).
static void emit_failure(const char *token, int begin, int code, const char *message) {
    if (token[0] != '\0') {
        if (begin) {
            (void)emit_marker("BEGIN", token);
            section_mark(token, 1);
        }
        (void)ensure_section(token, 2);
    }
    emit_message(message);
    if (token[0] != '\0') {
        (void)emit_end(token, code);
        section_release(token);
    }
}

// Failure frame for an OPEN/session that never started. The host's session
// parser has no ERR section — everything between OUT and END is terminal
// output — so the reason is delivered as session output followed by the real
// exit code. Never a silent hang.
static void emit_session_failure(const char *token, int code, const char *message) {
    if (token[0] != '\0') (void)ensure_section(token, 1);
    emit_message(message);
    if (token[0] != '\0') {
        (void)emit_end(token, code);
        section_release(token);
    }
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
// Chunked envelope assembly (per-token, so concurrent transfers interleave)
// ---------------------------------------------------------------------------

enum {
    ASM_NONE = 0,
    ASM_EXEC,
    ASM_OPEN,
    ASM_SPAWN,
};

typedef struct {
    int used;
    int kind;
    char token[MAX_TOKEN];
    size_t expected;
    uint32_t chunks_expected;
    uint32_t chunks_received;
    bytebuf payload;
} assembly;

static assembly g_asm[MAX_ASSEMBLIES];

static void asm_reset(assembly *a) {
    bb_free(&a->payload);
    memset(a, 0, sizeof *a);
}

static assembly *asm_find(const char *token) {
    for (int i = 0; i < MAX_ASSEMBLIES; i++) {
        if (g_asm[i].used && strcmp(g_asm[i].token, token) == 0) return &g_asm[i];
    }
    return NULL;
}

static assembly *asm_begin(int kind, const char *token, size_t expected, uint32_t chunks) {
    assembly *slot = asm_find(token);
    if (!slot) {
        for (int i = 0; i < MAX_ASSEMBLIES; i++) {
            if (!g_asm[i].used) { slot = &g_asm[i]; break; }
        }
    }
    if (!slot) return NULL; // table full: the frame is dropped, RUN never comes
    asm_reset(slot);
    slot->used = 1;
    slot->kind = kind;
    snprintf(slot->token, sizeof slot->token, "%s", token);
    slot->expected = expected;
    slot->chunks_expected = chunks;
    return slot;
}

static int asm_chunk(assembly *a, const char *token, uint32_t index, const unsigned char *body, size_t body_len) {
    if (!a || a->kind == ASM_NONE || strcmp(a->token, token) != 0) return -1;
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
// Command state (one-shot EXEC), one slot per concurrent command
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
    int cancel_requested;
    int cancel_signal; // signal the host asked for (INT/TERM/KILL)
    int term_sent;
    int sigkill_sent;
    int abandon_deadline_set;
    int64_t cancel_deadline;
    int64_t abandon_deadline;
    int64_t last_data;
    int exited;
    int exit_code;
    // Set for a command that is waiting for a FLOE-HOSTREPLY instead of a
    // child process; it owns no pid and is never signalled.
    int host_wait;
    int64_t host_deadline;
    char token[MAX_TOKEN];
} command_state;

static command_state g_commands[MAX_CONCURRENT_COMMANDS];

static command_state *command_find(const char *token) {
    for (int i = 0; i < MAX_CONCURRENT_COMMANDS; i++) {
        if (g_commands[i].active && strcmp(g_commands[i].token, token) == 0) return &g_commands[i];
    }
    return NULL;
}

static command_state *command_free_slot(void) {
    for (int i = 0; i < MAX_CONCURRENT_COMMANDS; i++) {
        if (!g_commands[i].active) return &g_commands[i];
    }
    return NULL;
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
                    // Re-announce the section whenever another token wrote in
                    // between; the host routes unmarked bytes to the last
                    // announced owner.
                    if (ensure_section(c->token, which == 2 ? 2 : 1) == 0) {
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

// The first signal is the one the host asked for (INT by default), then TERM
// after the grace window, then SIGKILL as the final escalation. SIGKILL is
// final; everything else still ends with a real waitpid reap or a quarantine
// FAILED. The reported exit code is 128 + the requested signal, and END is
// emitted only after the child is really reaped.
static void request_cancel(command_state *c, int sig) {
    if (!c->active || c->cancel_requested || c->exited) return;
    c->cancel_requested = 1;
    if (c->cancel_signal == 0) c->cancel_signal = sig;
    c->cancel_deadline = now_ms() + CANCEL_GRACE_MS;
    c->abandon_deadline = now_ms() + CANCEL_ABANDON_MS;
    c->abandon_deadline_set = 1;
    if (sig == SIGKILL) {
        c->term_sent = 1;
        c->sigkill_sent = 1;
        signal_command(c, SIGKILL);
        return;
    }
    if (sig == SIGTERM) c->term_sent = 1;
    signal_command(c, sig);
}

static void enforce_cancel(command_state *c) {
    if (!c->active || !c->cancel_requested || c->exited) return;
    if (now_ms() < c->cancel_deadline) return;
    if (!c->term_sent) {
        c->term_sent = 1;
        c->cancel_deadline = now_ms() + CANCEL_GRACE_MS;
        signal_command(c, SIGTERM);
        return;
    }
    if (!c->sigkill_sent) {
        c->sigkill_sent = 1;
        signal_command(c, SIGKILL);
    }
}

// ---------------------------------------------------------------------------
// Unreaped quarantine (a cancelled child that even SIGKILL could not reap)
// ---------------------------------------------------------------------------

typedef struct {
    int used;
    pid_t pid;
} unreaped_slot;

static unreaped_slot g_unreaped[MAX_UNREAPED];

static void unreaped_record(pid_t pid) {
    for (int i = 0; i < MAX_UNREAPED; i++) {
        if (!g_unreaped[i].used) {
            g_unreaped[i].used = 1;
            g_unreaped[i].pid = pid;
            return;
        }
    }
    // Table full: nothing more can be tracked; the child is still never
    // claimed stopped (the caller already emitted FAILED).
}

static void unreaped_forget(pid_t pid) {
    for (int i = 0; i < MAX_UNREAPED; i++) {
        if (g_unreaped[i].used && g_unreaped[i].pid == pid) g_unreaped[i].used = 0;
    }
}

// ---------------------------------------------------------------------------
// PTY session, one slot per concurrent interactive terminal
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

static pty_session g_sessions[MAX_CONCURRENT_SESSIONS];

static pty_session *session_find(const char *token) {
    for (int i = 0; i < MAX_CONCURRENT_SESSIONS; i++) {
        if (g_sessions[i].active && strcmp(g_sessions[i].token, token) == 0) return &g_sessions[i];
    }
    return NULL;
}

static pty_session *session_free_slot(void) {
    for (int i = 0; i < MAX_CONCURRENT_SESSIONS; i++) {
        if (!g_sessions[i].active) return &g_sessions[i];
    }
    return NULL;
}

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
                    // The host routes unmarked bytes to the last announced
                    // owner, so re-announce this session after any other
                    // command/session wrote in between.
                    if (ensure_section(s->token, 1) == 0) {
                        (void)write_all(STDOUT_FILENO, buf, n);
                    }
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
    session_signal(s, sig == SIGKILL ? SIGKILL : sig);
    if (sig == SIGKILL) s->sigkill_sent = 1;
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
// the child would never see EOF. With concurrent commands, the child must
// also not inherit other commands' pipe ends, so every runner-side fd is
// O_CLOEXEC and only the three dup2 targets survive exec.
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

static int pipe_cloexec(int fds[2]) {
#ifdef __linux__
    return pipe2(fds, O_CLOEXEC);
#else
    if (pipe(fds) != 0) return -1;
    (void)fcntl(fds[0], F_SETFD, FD_CLOEXEC);
    (void)fcntl(fds[1], F_SETFD, FD_CLOEXEC);
    return 0;
#endif
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
static int mkdir_p(const char *path, mode_t mode) {
    mkdir_parents(path, mode);
    if (mkdir(path, mode) == 0) return 0;
    return errno == EEXIST ? 0 : -1;
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
    // floe-cache is optional: the host exports it only when the app-wide
    // Runtime v2 shared download cache (cache/{pip,npm,xdg}) is available.
    // A failed 9p mount is ignored below; set_default_environment verifies
    // the mount in /proc/mounts before pointing any tool at it, so a guest
    // started by an older host keeps using the per-environment layer cache.
    static const struct share shares[] = {
        {"floe", "/floe"},
        {"floe-env", "/floe/env"},
        {"workspace", "/workspace"},
        {"floe-cache", "/floe/cache"},
    };
    for (size_t i = 0; i < sizeof shares / sizeof shares[0]; i++) {
        mkdir_p(shares[i].target, 0755);
        try_mount(shares[i].tag, shares[i].target, "9p", "trans=virtio,version=9p2000.L");
    }
}
#else
static void guest_bring_up(void) {}
#endif

// ---------------------------------------------------------------------------
// First-boot guest network (Linux only)
// ---------------------------------------------------------------------------

#ifdef __linux__
#include <arpa/inet.h>
#include <net/if.h>
#include <net/route.h>
#include <netinet/in.h>
#include <sys/socket.h>

// Replaces path with `content` through a same-directory temp file + rename so
// a crash cannot leave a truncated resolver or git config behind. Best
// effort: failures are reported by the caller's status, never hidden.
static int write_file_atomic(const char *path, const char *content, size_t len) {
    char tmp[256];
    int n = snprintf(tmp, sizeof tmp, "%s.floe.tmp", path);
    if (n <= 0 || (size_t)n >= sizeof tmp) return -1;
    int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd < 0) return -1;
    if (write_all(fd, content, len) != 0) {
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
    return 0;
}

// Renders a config with floe_net_render_* and writes it, reporting one line
// per failure. A missing parent directory is created.
static int write_rendered(const char *path, int (*render)(char *, size_t)) {
    char content[FLOE_NET_CONFIG_MAX];
    char dir[256];
    int n = render(content, sizeof content);
    if (n < 0) {
        diag("floe-exec: net %s: configuration does not fit\n", path);
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
    if (write_file_atomic(path, content, (size_t)n) != 0) {
        diag("floe-exec: net %s: %s\n", path, strerror(errno));
        return -1;
    }
    return 0;
}

// Applies ioctl(2) network configuration: address, netmask, default route.
// No shell, no bus, no DHCP client needed. Returns 0 only when the interface
// is UP with the slirp address and a default route through the slirp host.
static int apply_interface_config(int fd) {
    struct ifreq ifr;
    memset(&ifr, 0, sizeof ifr);
    if (strlen(FLOE_NET_INTERFACE) >= sizeof ifr.ifr_name) return -1;
    memcpy(ifr.ifr_name, FLOE_NET_INTERFACE, strlen(FLOE_NET_INTERFACE) + 1);

    struct sockaddr_in *sin;

    // Address.
    sin = (struct sockaddr_in *)&ifr.ifr_addr;
    sin->sin_family = AF_INET;
    if (inet_pton(AF_INET, FLOE_NET_GUEST_ADDRESS, &sin->sin_addr) != 1) return -1;
    if (ioctl(fd, SIOCSIFADDR, &ifr) != 0) return -1;

    // Netmask.
    memset(&ifr.ifr_netmask, 0, sizeof ifr.ifr_netmask);
    sin = (struct sockaddr_in *)&ifr.ifr_netmask;
    sin->sin_family = AF_INET;
    if (inet_pton(AF_INET, FLOE_NET_NETMASK, &sin->sin_addr) != 1) return -1;
    if (ioctl(fd, SIOCSIFNETMASK, &ifr) != 0) return -1;

    // Up (also re-reads flags: SIOCSIFFLAGS clobbers untouched fields, so
    // preserve the current flag set).
    memset(&ifr.ifr_flags, 0, sizeof ifr.ifr_flags);
    if (ioctl(fd, SIOCGIFFLAGS, &ifr) != 0) return -1;
    ifr.ifr_flags = (short)(ifr.ifr_flags | IFF_UP | IFF_RUNNING | IFF_MULTICAST);
    if (ioctl(fd, SIOCSIFFLAGS, &ifr) != 0) return -1;

    // Default route. SIOCADDRT fails with EEXIST when the route is already
    // there (the runner re-runs on every boot, and an image built by an older
    // revision may already carry it), which is success for this purpose.
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
        diag("floe-exec: net default route: %s\n", strerror(errno));
        // The address is still usable on-link; report a partial rather than
        // pretending nothing was configured.
    }

    ifr.ifr_flags = 0;
    if (ioctl(fd, SIOCGIFFLAGS, &ifr) != 0) return -1;
    if ((ifr.ifr_flags & IFF_UP) == 0) return -1;
    return 0;
}

// Bounded UDP DNS query over the ordered resolver plan (floe_net.h). One
// short packet per resolver, FLOE_NET_PROBE_TIMEOUT_SECONDS each, at most
// FLOE_NET_PROBE_MAX_ATTEMPTS attempts, no retries: this is a readiness
// observation, not a resolver. The first entry is slirp's 10.0.2.3 alias,
// which the engine relays to the host's own resolver, so a host that forces
// its DNS still answers. Returns the resolver text that answered, NULL when
// none did inside the budget.
static const char *resolver_answers(void) {
    unsigned char query[64];
    size_t qlen = 0;
    // ID 0x464c ("FL"), standard query, one question, recursion desired.
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
    query[qlen++] = 0x00; // root label
    query[qlen++] = 0x00; query[qlen++] = 0x01; // type A
    query[qlen++] = 0x00; query[qlen++] = 0x01; // class IN

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
            // Accept any well-formed reply carrying our transaction ID; the
            // point is that the path answers, not what it resolved.
            if (got >= 12 && reply[0] == 0x46 && reply[1] == 0x4c) ok = 1;
        }
        close(fd);
        if (ok) return server_text;
    }
    return NULL;
}

// First-boot network. Runs before the runner accepts any frame, so a guest
// that answers HELLO has already had its interface, route and resolver
// configured. Failures are reported through g_net_status and the console; the
// command channel still starts, because a guest without network is still a
// usable local shell.
static void guest_bring_up_network(void) {
    int fd = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    if (fd < 0) {
        diag("floe-exec: net %s: no socket: %s\n", FLOE_NET_INTERFACE, strerror(errno));
        return;
    }
    int configured = apply_interface_config(fd) == 0;
    close(fd);
    if (!configured) {
        diag("floe-exec: net %s: interface configuration failed: %s\n",
             FLOE_NET_INTERFACE, strerror(errno));
        g_net_status = FLOE_NET_DOWN;
        return;
    }

    // A failed config file is a degraded network (the running interface still
    // works), not silence: report it and keep going.
    if (write_rendered("/etc/resolv.conf", floe_net_render_resolv_conf) != 0 ||
        write_rendered("/etc/network/interfaces.d/" FLOE_NET_INTERFACE,
                       floe_net_render_interfaces) != 0) {
        diag("floe-exec: net resolver/interface configuration incomplete\n");
    }
    if (write_rendered("/etc/gitconfig", floe_net_render_gitconfig) != 0) {
        diag("floe-exec: net /etc/gitconfig (git safe.directory) not written\n");
    }

    const char *answered = resolver_answers();
    if (answered != NULL) {
        g_net_status = FLOE_NET_UP;
        diag("floe-exec: net %s=%s/%s gw=" FLOE_NET_GATEWAY " dns=%s status=up\n",
             FLOE_NET_INTERFACE, FLOE_NET_GUEST_ADDRESS, FLOE_NET_GUEST_PREFIX,
             answered);
    } else {
        g_net_status = FLOE_NET_PARTIAL;
        diag("floe-exec: net %s=%s/%s gw=" FLOE_NET_GATEWAY
             " status=partial (no resolver answered in %ds)\n",
             FLOE_NET_INTERFACE, FLOE_NET_GUEST_ADDRESS, FLOE_NET_GUEST_PREFIX,
             FLOE_NET_PROBE_MAX_ATTEMPTS * FLOE_NET_PROBE_TIMEOUT_SECONDS);
    }
}
#else
// Native host build: the developer machine's network is never touched.
static void guest_bring_up_network(void) {}
#endif

// True only for the guest's init process. The floe-guest-init script reaches
// the runner through exec, so PID 1 is preserved; anything else (the native
// protocol harness, the developer host, a runner started inside a live guest)
// must never own the machine clock.
static int is_guest_pid1(void) {
    return getpid() == 1;
}

#ifdef __linux__
// Apply `floe.epoch=<unix seconds>` from /proc/cmdline to CLOCK_REALTIME.
// Called only after guest_bring_up() mounted /proc and only by PID 1 (see
// main). The command line is read with a fixed bound; any problem leaves the
// clock untouched and says exactly that, so the guest never pretends the time
// is synchronized. No shell, no allocation, no other kernel parameter.
static void guest_apply_boot_epoch(void) {
    char cmdline[FLOE_EPOCH_CMDLINE_MAX];
    size_t len = 0;
    int truncated = 0;
    if (floe_cmdline_read_bounded("/proc/cmdline", cmdline, sizeof cmdline,
                                  &len, &truncated) != 0) {
        diag("floe-exec: clock NOT set: cannot read /proc/cmdline: %s\n",
             strerror(errno));
        return;
    }
    if (truncated) {
        diag("floe-exec: clock NOT set: cmdline truncated\n");
        return;
    }
    int64_t epoch = 0;
    floe_epoch_status status = floe_epoch_parse(cmdline, len, &epoch);
    if (status != FLOE_EPOCH_OK) {
        diag("floe-exec: clock NOT set: floe.epoch %s%s\n",
             floe_epoch_status_text(status), truncated ? " (cmdline truncated)" : "");
        return;
    }
    if ((int64_t)(time_t)epoch != epoch) {
        diag("floe-exec: clock NOT set: floe.epoch=%lld does not fit time_t\n",
             (long long)epoch);
        return;
    }
    struct timespec ts;
    ts.tv_sec = (time_t)epoch;
    ts.tv_nsec = 0;
    if (clock_settime(CLOCK_REALTIME, &ts) != 0) {
        // settimeofday is the explicit fallback for C libraries/kernels where
        // clock_settime(CLOCK_REALTIME) is not wired through.
        struct timeval tv;
        tv.tv_sec = (time_t)epoch;
        tv.tv_usec = 0;
        if (settimeofday(&tv, NULL) != 0) {
            diag("floe-exec: clock NOT set: floe.epoch=%lld rejected: %s\n",
                 (long long)epoch, strerror(errno));
            return;
        }
    }
    diag("floe-exec: clock set from floe.epoch=%lld\n", (long long)epoch);
}
#else
// Native host build: never touches the host clock.
static void guest_apply_boot_epoch(void) {}
#endif

static const char *default_cwd(void) {
    const char *env = getenv("FLOE_GUEST_CWD");
    if (env && env[0] == '/' && access(env, X_OK) == 0) return env;
    if (access("/workspace", X_OK) == 0) return "/workspace";
    if (access("/floe/env", X_OK) == 0) return "/floe/env";
    if (access("/root", X_OK) == 0) return "/root";
    return "/";
}

#ifdef __linux__
// True only when `path` is a real mount point listed in /proc/mounts. A
// directory merely mkdir'd below an unmounted share does not qualify, so the
// shared cache can never be mistaken for the empty mount point.
static int floe_path_is_mount(const char *path) {
    FILE *mounts = fopen("/proc/mounts", "re");
    if (!mounts) return 0;
    char line[1024];
    char needle[300];
    int found = 0;
    int n = snprintf(needle, sizeof needle, " %s ", path);
    if (n > 0 && n < (int)sizeof needle) {
        while (fgets(line, sizeof line, mounts)) {
            if (strstr(line, needle)) { found = 1; break; }
        }
    }
    (void)fclose(mounts);
    return found;
}

// Ensures the cache subdirectory exists and is writable; a read-only 9p
// export or a failed mkdir must leave the per-environment cache in effect.
static int floe_cache_ready(const char *path) {
    if (mkdir_p(path, 0755) != 0) return 0;
    return access(path, W_OK) == 0;
}
#endif

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
    // Persistent temp/cache inside the environment write layer. The root
    // partition is a compact image with a RAM-backed /tmp, so native
    // apt/pip/npm/gem work must not stage temp or cache there: a pip source
    // build (e.g. Pillow when no riscv64 wheel exists) would otherwise
    // ENOSPC the root partition. Paths are kept aligned with
    // LinuxGuestWritablePaths (Sources/FloeExecution/Linux).
    #define FLOE_ENV_TMP "/floe/env/tmp"
    #define FLOE_ENV_CACHE_XDG "/floe/env/cache/xdg"
    #define FLOE_ENV_CACHE_PIP "/floe/env/cache/pip"
    #define FLOE_ENV_CACHE_NPM "/floe/env/cache/npm"
    static const struct { const char *path; mode_t mode; } writable_dirs[] = {
        {FLOE_ENV_TMP, 01777},
        {FLOE_ENV_CACHE_XDG, 0755},
        {FLOE_ENV_CACHE_PIP, 0755},
        {FLOE_ENV_CACHE_NPM, 0755},
    };
    int writable_ready = access("/floe/env", W_OK) == 0;
    if (writable_ready) {
        for (size_t i = 0; i < sizeof writable_dirs / sizeof writable_dirs[0]; i++) {
            if (mkdir_p(writable_dirs[i].path, writable_dirs[i].mode) != 0
                || access(writable_dirs[i].path, W_OK) != 0) {
                writable_ready = 0;
                break;
            }
        }
    }
    if (writable_ready) {
        // overwrite: every guest command (shell, apt, pip, npm, gem, native
        // builds) sees the persistent locations.
        setenv("TMPDIR", FLOE_ENV_TMP, 1);
        setenv("TMP", FLOE_ENV_TMP, 1);
        setenv("TEMP", FLOE_ENV_TMP, 1);
        setenv("XDG_CACHE_HOME", FLOE_ENV_CACHE_XDG, 1);
        setenv("PIP_CACHE_DIR", FLOE_ENV_CACHE_PIP, 1);
        setenv("npm_config_cache", FLOE_ENV_CACHE_NPM, 1);

        // Optional App-wide shared download cache. Only floe-cache actually
        // mounted by the host (checked in /proc/mounts) and writable wins;
        // a missing/older share keeps the per-environment paths above, so a
        // package downloaded by one VM is reused by the next but an
        // unmounted or read-only cache is never silently substituted.
        if (floe_path_is_mount("/floe/cache")) {
            if (floe_cache_ready("/floe/cache/xdg"))
                setenv("XDG_CACHE_HOME", "/floe/cache/xdg", 1);
            if (floe_cache_ready("/floe/cache/pip"))
                setenv("PIP_CACHE_DIR", "/floe/cache/pip", 1);
            if (floe_cache_ready("/floe/cache/npm"))
                setenv("npm_config_cache", "/floe/cache/npm", 1);
        }
    }
    // If the share is missing/unwritable the /tmp defaults above stay in
    // effect; the failure is observed per command rather than hidden.
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
    c->exit_code = c->cancel_requested ? 128 + c->cancel_signal : code;
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

static void reap_all(void) {
    for (;;) {
        int status = 0;
        pid_t p = waitpid(-1, &status, WNOHANG);
        if (p == 0) return;
        if (p < 0) {
            if (errno == EINTR) continue;
            if (errno == ECHILD) {
                // Every child vanished without waitpid seeing it: mark any
                // still-active slot exited so END goes out instead of a hang.
                for (int i = 0; i < MAX_CONCURRENT_COMMANDS; i++) {
                    command_state *cmd = &g_commands[i];
                    if (cmd->active && !cmd->exited && cmd->pid > 0) {
                        cmd->exited = 1;
                        cmd->exit_code = cmd->cancel_requested ? 128 + cmd->cancel_signal : 128;
                        cmd->last_data = now_ms();
                        close_stream(&cmd->in_fd, &cmd->stdin_open);
                    }
                }
                for (int i = 0; i < MAX_CONCURRENT_SESSIONS; i++) {
                    pty_session *sess = &g_sessions[i];
                    if (sess->active && !sess->exited && sess->pid > 0) {
                        sess->exited = 1;
                        sess->exit_code = 128;
                        sess->last_data = now_ms();
                    }
                }
            }
            return;
        }
        unreaped_forget(p);
        int claimed = 0;
        for (int i = 0; i < MAX_CONCURRENT_COMMANDS && !claimed; i++) {
            command_state *cmd = &g_commands[i];
            if (cmd->active && !cmd->exited && p == cmd->pid) {
                record_command_exit(cmd, status);
                claimed = 1;
            }
        }
        for (int i = 0; i < MAX_CONCURRENT_SESSIONS && !claimed; i++) {
            pty_session *sess = &g_sessions[i];
            if (sess->active && !sess->exited && p == sess->pid) {
                record_session_exit(sess, status);
                claimed = 1;
            }
        }
        if (!claimed) {
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

// Emits BEGIN, ERR and END for a command that could not start. BEGIN is
// required: the host parser only routes output for a token after BEGIN.
static void fail_command(command_state *c, int code, const char *message) {
    (void)emit_marker("BEGIN", c->token);
    section_mark(c->token, 1);
    (void)ensure_section(c->token, 2);
    emit_message(message);
    (void)emit_end(c->token, code);
    section_release(c->token);
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
    if (pipe_cloexec(in_pipe) != 0 || pipe_cloexec(out_pipe) != 0 || pipe_cloexec(err_pipe) != 0) {
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
    section_mark(c->token, 1); // stdout is the implicit section after BEGIN

    if (c->req.input_len == 0) {
        close(c->in_fd);
        c->in_fd = -1;
        c->stdin_open = 0;
    } else {
        c->stdin_open = 1;
    }
}

// Optional guest → host archive bridge. The command validates the request
// against the negotiated capability set, emits a bounded control message and
// waits for FLOE-HOSTREPLY; the host does the work on the shared directory.
static void start_host_archive_command(command_state *c, const char *token, exec_request *req) {
    floe_host_request hreq;
    int parsed = floe_host_request_parse(req->argc, req->argv, &hreq);
    if (parsed != 0) {
        exec_request_free(req);
        emit_failure(token, 1, 126,
                     "floe-host: usage: floe-host archive create|extract|list|decompress "
                     "[--format FMT] --source PATH [--destination PATH]");
        return;
    }
    if (!floe_host_caps_allows(&g_host_caps, hreq.action)) {
        exec_request_free(req);
        emit_failure(token, 1, 126,
                     "floe-host: host archive bridge is not negotiated for this action "
                     "(the host must advertise it in FLOE-HELLO archive=...)");
        return;
    }
    char payload[FLOE_HOST_PAYLOAD_MAX];
    int payload_len = floe_host_request_encode(&hreq, token, payload, sizeof payload);
    if (payload_len <= 0) {
        exec_request_free(req);
        emit_failure(token, 1, 126, "floe-host: request could not be encoded");
        return;
    }
    size_t encoded_cap = ((size_t)payload_len + 2) / 3 * 4 + 1;
    char *encoded = malloc(encoded_cap);
    if (!encoded) {
        exec_request_free(req);
        emit_failure(token, 1, 125, "floe-host: cannot allocate the control message");
        return;
    }
    if (floe_host_b64_encode((const unsigned char *)payload, (size_t)payload_len, encoded, encoded_cap) <= 0) {
        free(encoded);
        exec_request_free(req);
        emit_failure(token, 1, 125, "floe-host: cannot encode the control message");
        return;
    }

    memset(c, 0, sizeof *c);
    c->in_fd = c->out_fd = c->err_fd = -1;
    c->active = 1;
    c->host_wait = 1;
    c->host_deadline = now_ms() + HOST_ARCHIVE_TIMEOUT_MS;
    snprintf(c->token, sizeof c->token, "%s", token);
    exec_request_free(req);

    if (emit_marker("BEGIN", c->token) != 0) {
        free(encoded);
        clear_command(c);
        return;
    }
    section_mark(c->token, 1);
    char frame[MAX_TOKEN + FLOE_HOST_PAYLOAD_MAX * 2 + 64];
    int n = snprintf(frame, sizeof frame, "\x1e" "FLOE-HOSTREQ %s %s\x1e", c->token, encoded);
    free(encoded);
    if (n <= 0 || (size_t)n >= sizeof frame || write_all(STDOUT_FILENO, frame, (size_t)n) != 0) {
        ensure_section(c->token, 2);
        emit_message("floe-host: cannot send the control message\n");
        emit_end(c->token, 125);
        section_release(c->token);
        clear_command(c);
    }
}

static void finish_host_wait(command_state *c, int code, const char *message) {
    if (message && message[0] != '\0') {
        ensure_section(c->token, 2);
        emit_message(message);
    }
    emit_end(c->token, code);
    section_release(c->token);
    clear_command(c);
}

static int command_drain_done(const command_state *c) {
    if (!c->exited) return 0;
    if (!c->out_open && !c->err_open) return 1;
    return now_ms() - c->last_data >= DRAIN_QUIET_MS;
}

static void finish_command(command_state *c) {
    int code = c->cancel_requested ? 128 + c->cancel_signal : c->exit_code;
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
    // BEGIN went out after fork; a child that never printed still gets a
    // well-formed stream (BEGIN + END is legal; sections are optional).
    (void)emit_end(c->token, code);
    section_release(c->token);
    exec_request_free(&c->req);
    memset(c, 0, sizeof *c);
    c->in_fd = c->out_fd = c->err_fd = -1;
}

// Quarantines a child that cannot be killed (uninterruptible sleep). The
// runner emits FAILED — never END — so the host reports a failed guest
// instead of a clean stop. The pid is reaped asynchronously by reap_all.
static void quarantine_command(command_state *c) {
    close_stream(&c->in_fd, &c->stdin_open);
    close_stream(&c->out_fd, &c->out_open);
    close_stream(&c->err_fd, &c->err_open);
    unreaped_record(c->pid);
    (void)emit_failed(c->token, "unreaped");
    section_release(c->token);
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
    section_release(s->token);
    session_free(s);
    s->master_fd = -1;
}

// Quarantines a session whose process cannot be killed; the pty is closed
// and the host gets FAILED (never END) so it resets the guest instead of
// reporting a clean terminal exit.
static void quarantine_session(pty_session *s) {
    session_close_master(s);
    unreaped_record(s->pid);
    (void)emit_failed(s->token, "unreaped");
    section_release(s->token);
    session_free(s);
    s->master_fd = -1;
}

static void start_session(pty_session *s, const char *token, open_request *req) {
    memset(s, 0, sizeof *s);
    s->master_fd = -1;

    int master = posix_openpt(O_RDWR | O_CLOEXEC);
    if (master < 0 || grantpt(master) != 0 || unlockpt(master) != 0) {
        if (master >= 0) close(master);
        emit_session_failure(token, 125, "floe-exec: cannot allocate a pty");
        return;
    }
    const char *slave_name = ptsname(master);
    if (!slave_name) {
        close(master);
        emit_session_failure(token, 125, "floe-exec: cannot name the pty slave");
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
        emit_session_failure(token, 125, "floe-exec: cannot fork the session");
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
    // BEGIN announces the session to the host (its parser also accepts a
    // first OUT); an output-less session still ends with a well-formed END.
    (void)emit_marker("BEGIN", s->token);
    section_mark(s->token, 1);
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
        int logfd = open(req.log_path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
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
        if (req.argc > 0 && req.argv[0] != NULL && req.argv[0][0] != '\0') {
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

static int start_exec_payload(const char *token, const unsigned char *payload, size_t plen) {
    exec_request req;
    if (exec_request_parse(payload, plen, &req) != 0) {
        emit_failure(token, 1, 125, "floe-exec: malformed EXEC payload");
        return -1;
    }
    command_state *slot = command_free_slot();
    if (!slot) {
        exec_request_free(&req);
        emit_failure(token, 1, 125, "floe-exec: command table full");
        return -1;
    }
    // The optional floe-host archive bridge is a runner built-in: it never
    // forks, it forwards a bounded request to the host and relays the reply.
    if (req.argc >= 1 && req.argv[0] && strcmp(req.argv[0], "floe-host") == 0) {
        start_host_archive_command(slot, token, &req);
        return 0;
    }
    start_command(slot, token, &req);
    return 0;
}

static int start_open_payload(const char *token, const unsigned char *payload, size_t plen) {
    open_request req;
    if (open_request_parse(payload, plen, &req) != 0) {
        emit_session_failure(token, 125, "floe-exec: malformed OPEN payload");
        return -1;
    }
    if (!req.mode || strcmp(req.mode, "pty") != 0) {
        open_request_free(&req);
        emit_session_failure(token, 125, "floe-exec: unsupported OPEN mode");
        return -1;
    }
    pty_session *slot = session_free_slot();
    if (!slot) {
        open_request_free(&req);
        emit_session_failure(token, 125, "floe-exec: session table full");
        return -1;
    }
    start_session(slot, token, &req);
    open_request_free(&req);
    return 0;
}

static void handle_frame(const unsigned char *body, size_t len) {
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

    if (name_len == 5 && memcmp(body, "HELLO", 5) == 0) {
        // The host may advertise optional capabilities as key=value fields;
        // unknown keys are ignored and an absent key disables the bridge.
        (void)floe_host_caps_parse((const char *)args, args_len, &g_host_caps);
        (void)emit_caps(token);
        return;
    }

    if (name_len == 4 && memcmp(body, "EXEC", 4) == 0) {
        size_t payload_bytes = 0;
        uint32_t chunks = 0;
        if (parse_two_decimals(args, args_len, &payload_bytes, &chunks) == 0) {
            (void)asm_begin(ASM_EXEC, token, payload_bytes, chunks);
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
        (void)start_exec_payload(token, payload, (size_t)decoded);
        free(payload);
        return;
    }

    if (name_len == 4 && memcmp(body, "OPEN", 4) == 0) {
        size_t payload_bytes = 0;
        uint32_t chunks = 0;
        if (parse_two_decimals(args, args_len, &payload_bytes, &chunks) != 0) return;
        (void)asm_begin(ASM_OPEN, token, payload_bytes, chunks);
        return;
    }

    if (name_len == 9 && memcmp(body, "HOSTREPLY", 9) == 0) {
        command_state *slot = command_find(token);
        if (!slot || !slot->host_wait) return; // unknown or late reply: ignore
        size_t cap = args_len / 4 * 3 + 4;
        unsigned char *decoded = malloc(cap);
        if (!decoded) {
            finish_host_wait(slot, 125, "floe-host: cannot allocate the reply buffer\n");
            return;
        }
        long decoded_len = b64_decode(args, args_len, decoded, cap);
        if (decoded_len <= 0 || (size_t)decoded_len >= FLOE_HOST_REPLY_MAX) {
            free(decoded);
            finish_host_wait(slot, 125, "floe-host: malformed host reply\n");
            return;
        }
        decoded[decoded_len] = '\0';
        floe_host_reply reply;
        if (floe_host_reply_parse((const char *)decoded, &reply) != 0) {
            free(decoded);
            finish_host_wait(slot, 125, "floe-host: unreadable host reply\n");
            return;
        }
        char text[FLOE_HOST_REPLY_MAX + 64];
        (void)floe_host_reply_text((const char *)decoded, text, sizeof text);
        free(decoded);
        (void)ensure_section(token, 1);
        emit_message(text);
        finish_host_wait(slot, reply.exit_code, NULL);
        return;
    }

    if (name_len == 5 && memcmp(body, "SPAWN", 5) == 0) {
        size_t payload_bytes = 0;
        uint32_t chunks = 0;
        if (parse_two_decimals(args, args_len, &payload_bytes, &chunks) != 0) return;
        (void)asm_begin(ASM_SPAWN, token, payload_bytes, chunks);
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
        assembly *a = asm_find(token);
        if (asm_chunk(a, token, (uint32_t)index, chunk_body, chunk_len) != 0 && a) {
            asm_reset(a);
        }
        return;
    }

    if (name_len == 3 && memcmp(body, "RUN", 3) == 0) {
        assembly *a = asm_find(token);
        if (!a || a->kind == ASM_NONE) return;
        if (a->chunks_received != a->chunks_expected ||
            a->payload.len != a->expected) {
            if (a->kind == ASM_OPEN) {
                emit_session_failure(token, 125, "floe-exec: incomplete chunked payload");
            } else {
                emit_failure(token, a->kind == ASM_EXEC, 125,
                             "floe-exec: incomplete chunked payload");
            }
            asm_reset(a);
            return;
        }
        int kind = a->kind;
        unsigned char *payload = a->payload.data;
        size_t plen = a->payload.len;
        // Detach the payload but keep the slot marked used until the
        // pointers are copied out; then clear it without freeing the
        // (now owned by us) payload bytes.
        a->payload.data = NULL;
        a->payload.len = 0;
        a->payload.cap = 0;
        a->kind = ASM_NONE;
        a->used = 0;
        a->token[0] = '\0';
        a->expected = 0;
        a->chunks_expected = 0;
        a->chunks_received = 0;
        if (kind == ASM_EXEC) {
            (void)start_exec_payload(token, payload, plen);
        } else if (kind == ASM_OPEN) {
            (void)start_open_payload(token, payload, plen);
        } else {
            do_spawn(token, payload, plen);
        }
        free(payload);
        return;
    }

    if (name_len == 2 && memcmp(body, "IN", 2) == 0) {
        pty_session *sess = session_find(token);
        if (!sess) return;
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
        int sig = 0;
        if (args_len >= 5 && memcmp(args, "WINCH", 5) == 0) {
            pty_session *sess = session_find(token);
            if (!sess) return;
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
            return;
        }
        if (args_len >= 3 && memcmp(args, "INT", 3) == 0) sig = SIGINT;
        else if (args_len >= 4 && memcmp(args, "TERM", 4) == 0) sig = SIGTERM;
        else if (args_len >= 4 && memcmp(args, "KILL", 4) == 0) sig = SIGKILL;
        else return;
        // Targeted cancellation: sessions first, then one-shot commands.
        pty_session *sess = session_find(token);
        if (sess) {
            session_request_kill(sess, sig);
            return;
        }
        command_state *cmd = command_find(token);
        if (cmd) {
            request_cancel(cmd, sig);
        }
        return;
    }

    if (name_len == 5 && memcmp(body, "CLOSE", 5) == 0) {
        pty_session *sess = session_find(token);
        if (sess) {
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

static void dispatch_inbound(bytebuf *in) {
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
            handle_frame(in->data + prefix_len, line_len - prefix_len);
        }
        bb_consume(in, consume);
    }
}

// ---------------------------------------------------------------------------
// Main loop
// ---------------------------------------------------------------------------

// Pollfd owner kinds for the dynamic poll set.
enum {
    OWNER_CONSOLE = 0,
    OWNER_WAKE,
    OWNER_CMD_OUT,
    OWNER_CMD_ERR,
    OWNER_CMD_IN,
    OWNER_SESSION_IN,
    OWNER_SESSION_OUT,
};

typedef struct {
    int kind;
    int index; // command/session slot
} poll_owner;

int main(void) {
    if (getpid() == 1 || getenv("FLOE_GUEST_INIT") != NULL) {
        guest_bring_up();
        // Interface, default route, resolver and git safe.directory are
        // applied before the channel accepts a frame, so a guest that
        // answers HELLO is already usable for apt/pip/npm and guest git.
        guest_bring_up_network();
    }
    if (is_guest_pid1()) {
        // guest_bring_up() mounted /proc; the boot clock must be applied
        // before any command frame is accepted. Non-PID-1 harnesses skip
        // this entirely and never touch the host clock.
        guest_apply_boot_epoch();
    }
    if (pipe(g_wake_pipe) == 0) {
        set_nonblocking(g_wake_pipe[0]);
        set_nonblocking(g_wake_pipe[1]);
    }
    install_signal_handlers();
    set_default_environment();
    int console = STDIN_FILENO;
    set_console_raw(console);

    for (int i = 0; i < MAX_CONCURRENT_COMMANDS; i++) g_commands[i].in_fd = -1;
    for (int i = 0; i < MAX_CONCURRENT_COMMANDS; i++) {
        g_commands[i].out_fd = -1;
        g_commands[i].err_fd = -1;
    }
    for (int i = 0; i < MAX_CONCURRENT_SESSIONS; i++) g_sessions[i].master_fd = -1;

    bytebuf inbound = {0};

    for (;;) {
        struct pollfd fds[2 + MAX_CONCURRENT_COMMANDS * 3 + MAX_CONCURRENT_SESSIONS * 2];
        poll_owner owners[2 + MAX_CONCURRENT_COMMANDS * 3 + MAX_CONCURRENT_SESSIONS * 2];
        int n = 0;
        int i_console = n;
        owners[n].kind = OWNER_CONSOLE;
        owners[n].index = -1;
        fds[n].fd = console;
        fds[n].events = POLLIN;
        fds[n].revents = 0;
        n++;

        int i_wake = -1;
        if (g_wake_pipe[0] >= 0) {
            i_wake = n;
            owners[n].kind = OWNER_WAKE;
            owners[n].index = -1;
            fds[n].fd = g_wake_pipe[0];
            fds[n].events = POLLIN;
            fds[n].revents = 0;
            n++;
        }

        int any_active = 0;
        for (int i = 0; i < MAX_CONCURRENT_COMMANDS; i++) {
            command_state *cmd = &g_commands[i];
            if (!cmd->active) continue;
            any_active = 1;
            if (cmd->out_open && cmd->out_fd >= 0) {
                owners[n].kind = OWNER_CMD_OUT;
                owners[n].index = i;
                fds[n].fd = cmd->out_fd;
                fds[n].events = POLLIN;
                fds[n].revents = 0;
                n++;
            }
            if (cmd->err_open && cmd->err_fd >= 0) {
                owners[n].kind = OWNER_CMD_ERR;
                owners[n].index = i;
                fds[n].fd = cmd->err_fd;
                fds[n].events = POLLIN;
                fds[n].revents = 0;
                n++;
            }
            if (cmd->stdin_open && cmd->in_fd >= 0) {
                owners[n].kind = OWNER_CMD_IN;
                owners[n].index = i;
                fds[n].fd = cmd->in_fd;
                fds[n].events = POLLOUT;
                fds[n].revents = 0;
                n++;
            }
        }
        for (int i = 0; i < MAX_CONCURRENT_SESSIONS; i++) {
            pty_session *sess = &g_sessions[i];
            if (!sess->active || sess->master_fd < 0) continue;
            any_active = 1;
            owners[n].kind = OWNER_SESSION_IN;
            owners[n].index = i;
            fds[n].fd = sess->master_fd;
            fds[n].events = POLLIN;
            fds[n].revents = 0;
            n++;
            if (sess->input_len > sess->input_off) {
                owners[n].kind = OWNER_SESSION_OUT;
                owners[n].index = i;
                fds[n].fd = sess->master_fd;
                fds[n].events = POLLOUT;
                fds[n].revents = 0;
                n++;
            }
        }

        int timeout = any_active ? POLL_SLICE_MS : -1;
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
                        // Legacy interrupt-all byte: every in-flight command
                        // gets TERM escalation; sessions keep their own
                        // CLOSE/SIGNAL semantics.
                        for (int c = 0; c < MAX_CONCURRENT_COMMANDS; c++) {
                            if (!g_commands[c].active) continue;
                            if (g_commands[c].host_wait) {
                                g_commands[c].cancel_requested = 1;
                                g_commands[c].cancel_signal = SIGINT;
                                continue;
                            }
                            request_cancel(&g_commands[c], SIGINT);
                        }
                        continue;
                    }
                    if (inbound.len + 1 > MAX_INBOUND) bb_consume(&inbound, inbound.len);
                    if (bb_append(&inbound, &chunk[i], 1) != 0) {
                        bb_consume(&inbound, inbound.len);
                    }
                }
                dispatch_inbound(&inbound);
                continue; // poll set may have changed (command/session started)
            }
            if (got == 0) {
                // Console EOF: the guest is being stopped.
                for (int c = 0; c < MAX_CONCURRENT_COMMANDS; c++) {
                    if (g_commands[c].active) signal_command(&g_commands[c], SIGKILL);
                }
                for (int s = 0; s < MAX_CONCURRENT_SESSIONS; s++) {
                    if (g_sessions[s].active) session_signal(&g_sessions[s], SIGKILL);
                }
                bb_free(&inbound);
                for (int c = 0; c < MAX_CONCURRENT_COMMANDS; c++) clear_command(&g_commands[c]);
                for (int s = 0; s < MAX_CONCURRENT_SESSIONS; s++) session_free(&g_sessions[s]);
                for (int a = 0; a < MAX_ASSEMBLIES; a++) asm_reset(&g_asm[a]);
                return 0;
            }
            if (errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK) {
                bb_free(&inbound);
                return 0;
            }
        }

        for (int f = 0; f < n; f++) {
            if (fds[f].revents == 0) continue;
            switch (owners[f].kind) {
            case OWNER_CMD_OUT:
                if (fds[f].revents & (POLLIN | POLLHUP | POLLERR)) {
                    forward_stream(&g_commands[owners[f].index], 1);
                }
                break;
            case OWNER_CMD_ERR:
                if (fds[f].revents & (POLLIN | POLLHUP | POLLERR)) {
                    forward_stream(&g_commands[owners[f].index], 2);
                }
                break;
            case OWNER_CMD_IN:
                if (fds[f].revents & (POLLOUT | POLLERR | POLLHUP)) {
                    feed_stdin(&g_commands[owners[f].index]);
                }
                break;
            case OWNER_SESSION_IN:
                if (fds[f].revents & (POLLIN | POLLHUP | POLLERR)) {
                    session_forward_output(&g_sessions[owners[f].index]);
                }
                break;
            case OWNER_SESSION_OUT:
                if (fds[f].revents & (POLLOUT | POLLERR | POLLHUP)) {
                    session_feed_input(&g_sessions[owners[f].index]);
                }
                break;
            default:
                break;
            }
        }

        reap_all();
        kills_enforce();

        for (int c = 0; c < MAX_CONCURRENT_COMMANDS; c++) {
            command_state *cmd = &g_commands[c];
            if (!cmd->active) continue;
            if (cmd->host_wait) {
                // No child process: either the host answered (handled in
                // handle_frame), the host cancelled the command, or the
                // reply deadline passed.
                if (cmd->cancel_requested) {
                    finish_host_wait(cmd, 130, "floe-host: command cancelled\n");
                } else if (now_ms() >= cmd->host_deadline) {
                    finish_host_wait(cmd, 124, "floe-host: timed out waiting for the host reply\n");
                }
                continue;
            }
            enforce_cancel(cmd);
            if (cmd->cancel_requested && cmd->abandon_deadline_set &&
                !cmd->exited && now_ms() >= cmd->abandon_deadline) {
                quarantine_command(cmd);
            } else if (cmd->exited && command_drain_done(cmd)) {
                finish_command(cmd);
            }
        }
        for (int s = 0; s < MAX_CONCURRENT_SESSIONS; s++) {
            pty_session *sess = &g_sessions[s];
            if (!sess->active) continue;
            session_enforce_kill(sess);
            if (sess->abandon_deadline_set && !sess->exited &&
                now_ms() >= sess->abandon_deadline) {
                quarantine_session(sess);
            } else if (session_done(sess)) {
                finish_session(sess);
            }
        }
    }
}
