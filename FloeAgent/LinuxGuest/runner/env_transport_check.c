// env_transport_check.c — real-stdio check for the per-process sensitive
// environment transport (EXECENV / OPENENV, CAPS env=1).
//
// This drives the *actual* runner binary over pipes exactly like the guest
// console: HELLO/CAPS, inline and chunked EXECENV, OPENENV, ordinary EXEC
// backward compatibility, two concurrent children with different secrets,
// stdin independence, invalid/oversized/duplicate/NUL/truncated blocks, and
// the guarantee that a completed command did not modify PID 1's environment.
//
// It is a host-native protocol check, not guest-image qualification: the
// static riscv64 binary still has to be rebuilt and bound by the release
// owner, then exercised in the real guest.
//
// Usage: env_transport_check <path-to-floe-exec-host-build>

#define _GNU_SOURCE 1

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define MARK 0x1e
#define MAX_TOKEN 96
#define MAX_PAYLOAD (256 * 1024)
#define INLINE_LIMIT 3800
#define CHUNK_CHARS 3000

static int failures;
static int passes;

static void check(int condition, const char *format, ...) {
    if (condition) {
        passes++;
        return;
    }
    failures++;
    va_list args;
    va_start(args, format);
    fputs("FAIL  ", stderr);
    vfprintf(stderr, format, args);
    fputc('\n', stderr);
    va_end(args);
}

static int64_t now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

// ---------------------------------------------------------------------------
// byte buffer
// ---------------------------------------------------------------------------

typedef struct {
    unsigned char *data;
    size_t len;
    size_t cap;
} buffer;

static int buffer_reserve(buffer *b, size_t extra) {
    if (b->len + extra <= b->cap) return 0;
    size_t cap = b->cap ? b->cap : 4096;
    while (cap < b->len + extra) cap *= 2;
    unsigned char *grown = realloc(b->data, cap);
    if (!grown) return -1;
    b->data = grown;
    b->cap = cap;
    return 0;
}

static int buffer_append(buffer *b, const void *bytes, size_t length) {
    if (buffer_reserve(b, length) != 0) return -1;
    memcpy(b->data + b->len, bytes, length);
    b->len += length;
    return 0;
}

static void buffer_append_u32(buffer *b, uint32_t value) {
    unsigned char raw[4];
    raw[0] = (unsigned char)(value >> 24);
    raw[1] = (unsigned char)(value >> 16);
    raw[2] = (unsigned char)(value >> 8);
    raw[3] = (unsigned char)value;
    (void)buffer_append(b, raw, sizeof raw);
}

static void buffer_append_field(buffer *b, const void *bytes, size_t length) {
    buffer_append_u32(b, (uint32_t)length);
    if (length > 0) (void)buffer_append(b, bytes, length);
}

static void buffer_free(buffer *b) {
    free(b->data);
    memset(b, 0, sizeof *b);
}

// ---------------------------------------------------------------------------
// base64
// ---------------------------------------------------------------------------

static const char base64_table[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

static char *base64_encode(const unsigned char *data, size_t length) {
    size_t out_len = (length + 2) / 3 * 4;
    char *out = malloc(out_len + 1);
    if (!out) return NULL;
    size_t o = 0;
    for (size_t i = 0; i < length; i += 3) {
        uint32_t value = (uint32_t)data[i] << 16;
        if (i + 1 < length) value |= (uint32_t)data[i + 1] << 8;
        if (i + 2 < length) value |= data[i + 2];
        out[o++] = base64_table[(value >> 18) & 0x3f];
        out[o++] = base64_table[(value >> 12) & 0x3f];
        out[o++] = i + 1 < length ? base64_table[(value >> 6) & 0x3f] : '=';
        out[o++] = i + 2 < length ? base64_table[value & 0x3f] : '=';
    }
    out[o] = '\0';
    return out;
}

// ---------------------------------------------------------------------------
// runner process
// ---------------------------------------------------------------------------

static pid_t runner_pid = -1;
static int runner_in = -1;
static int runner_out = -1;
static buffer console_bytes;
static unsigned long token_counter;

static int write_all_fd(int fd, const void *bytes, size_t length) {
    const unsigned char *p = bytes;
    while (length > 0) {
        ssize_t written = write(fd, p, length);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) return -1;
        p += written;
        length -= (size_t)written;
    }
    return 0;
}

static int start_runner(const char *path) {
    int in_pipe[2] = {-1, -1};
    int out_pipe[2] = {-1, -1};
    if (pipe(in_pipe) != 0 || pipe(out_pipe) != 0) return -1;
    pid_t pid = fork();
    if (pid < 0) return -1;
    if (pid == 0) {
        dup2(in_pipe[0], STDIN_FILENO);
        dup2(out_pipe[1], STDOUT_FILENO);
        int devnull = open("/dev/null", O_WRONLY);
        if (devnull >= 0) dup2(devnull, STDERR_FILENO);
        close(in_pipe[0]);
        close(in_pipe[1]);
        close(out_pipe[0]);
        close(out_pipe[1]);
        execl(path, path, (char *)NULL);
        _exit(127);
    }
    close(in_pipe[0]);
    close(out_pipe[1]);
    runner_pid = pid;
    runner_in = in_pipe[1];
    runner_out = out_pipe[0];
    return 0;
}

static void stop_runner(void) {
    if (runner_pid <= 0) return;
    kill(runner_pid, SIGKILL);
    int status = 0;
    while (waitpid(runner_pid, &status, 0) < 0 && errno == EINTR) {}
    if (runner_in >= 0) close(runner_in);
    if (runner_out >= 0) close(runner_out);
    runner_pid = -1;
    runner_in = -1;
    runner_out = -1;
}

static void drain_console(int timeout_ms) {
    if (runner_out < 0) return;
    int64_t deadline = now_ms() + timeout_ms;
    for (;;) {
        int64_t remaining = deadline - now_ms();
        if (remaining < 0) remaining = 0;
        struct pollfd pfd;
        pfd.fd = runner_out;
        pfd.events = POLLIN;
        pfd.revents = 0;
        int ready = poll(&pfd, 1, (int)remaining);
        if (ready < 0) {
            if (errno == EINTR) continue;
            return;
        }
        if (ready == 0) return;
        unsigned char chunk[8192];
        ssize_t got = read(runner_out, chunk, sizeof chunk);
        if (got < 0 && errno == EINTR) continue;
        if (got <= 0) return;
        (void)buffer_append(&console_bytes, chunk, (size_t)got);
    }
}

// Reads the console until every token has an END frame (or the deadline).
static int read_until_ends(char tokens[][MAX_TOKEN], int count, int timeout_ms) {
    int64_t deadline = now_ms() + timeout_ms;
    for (;;) {
        int all = 1;
        for (int i = 0; i < count; i++) {
            char marker[MAX_TOKEN + 32];
            snprintf(marker, sizeof marker, "\x1e" "FLOE-END %s ", tokens[i]);
            int found = 0;
            for (size_t pos = 0; pos + strlen(marker) <= console_bytes.len; pos++) {
                if (memcmp(console_bytes.data + pos, marker, strlen(marker)) == 0) {
                    found = 1;
                    break;
                }
            }
            if (!found) all = 0;
        }
        if (all) return 0;
        if (now_ms() >= deadline) return -1;
        drain_console(100);
    }
}

// Extracts one token's stdout/stderr sections and exit code from the console
// capture, mirroring the host router's section ownership rule.
static int extract_token(const char *token, buffer *out, buffer *err, int *exit_code) {
    size_t token_len = strlen(token);
    size_t i = 0;
    int owner_stdout = 0;
    int owner_stderr = 0;
    int owner_matches = 0;
    *exit_code = -1;
    while (i < console_bytes.len) {
        if (console_bytes.data[i] != MARK) {
            if (owner_matches && owner_stdout) (void)buffer_append(out, console_bytes.data + i, 1);
            else if (owner_matches && owner_stderr) (void)buffer_append(err, console_bytes.data + i, 1);
            i++;
            continue;
        }
        // A marker is only a frame when it starts "\x1eFLOE-<name> <token>".
        const unsigned char *start = console_bytes.data + i;
        size_t remaining = console_bytes.len - i;
        if (remaining < 7 || memcmp(start + 1, "FLOE-", 5) != 0) {
            if (owner_matches && owner_stdout) (void)buffer_append(out, console_bytes.data + i, 1);
            else if (owner_matches && owner_stderr) (void)buffer_append(err, console_bytes.data + i, 1);
            i++;
            continue;
        }
        const unsigned char *space = memchr(start + 6, ' ', remaining - 6);
        if (!space) {
            if (owner_matches && owner_stdout) (void)buffer_append(out, console_bytes.data + i, 1);
            else if (owner_matches && owner_stderr) (void)buffer_append(err, console_bytes.data + i, 1);
            i++;
            continue;
        }
        size_t name_len = (size_t)(space - (start + 6));
        const unsigned char *after = space + 1;
        const unsigned char *closing = memchr(after, MARK, (size_t)(console_bytes.data + console_bytes.len - after));
        if (!closing) {
            if (owner_matches && owner_stdout) (void)buffer_append(out, console_bytes.data + i, 1);
            else if (owner_matches && owner_stderr) (void)buffer_append(err, console_bytes.data + i, 1);
            i++;
            continue;
        }
        size_t body_len = (size_t)(closing - after);
        size_t token_len_in_frame = body_len;
        const unsigned char *end_of_token = memchr(after, ' ', body_len);
        if (end_of_token) token_len_in_frame = (size_t)(end_of_token - after);
        int match = token_len_in_frame == token_len &&
                    memcmp(after, token, token_len) == 0;
        int known = (name_len == 5 && memcmp(start + 6, "BEGIN", 5) == 0) ||
                    (name_len == 3 && memcmp(start + 6, "OUT", 3) == 0) ||
                    (name_len == 3 && memcmp(start + 6, "ERR", 3) == 0) ||
                    (name_len == 3 && memcmp(start + 6, "END", 3) == 0) ||
                    (name_len == 6 && memcmp(start + 6, "FAILED", 6) == 0) ||
                    (name_len == 3 && memcmp(start + 6, "PID", 3) == 0) ||
                    (name_len == 4 && memcmp(start + 6, "CAPS", 4) == 0);
        if (known) {
            // Every known frame (for ANY token) changes section ownership:
            // payload bytes belong to the most recent BEGIN/OUT/ERR owner,
            // exactly like the production router. Only bytes owned by the
            // requested token are collected.
            if (name_len == 5 || (name_len == 3 && memcmp(start + 6, "OUT", 3) == 0)) {
                owner_stdout = 1;
                owner_stderr = 0;
                owner_matches = match;
            } else if (name_len == 3 && memcmp(start + 6, "ERR", 3) == 0) {
                owner_stdout = 0;
                owner_stderr = 1;
                owner_matches = match;
            } else if (name_len == 3 && memcmp(start + 6, "END", 3) == 0) {
                if (match && end_of_token && (size_t)(closing - end_of_token - 1) > 0) {
                    char code_text[16] = {0};
                    size_t copy = (size_t)(closing - end_of_token - 1);
                    if (copy >= sizeof code_text) copy = sizeof code_text - 1;
                    memcpy(code_text, end_of_token + 1, copy);
                    *exit_code = atoi(code_text);
                }
                if (owner_matches) {
                    owner_stdout = 0;
                    owner_stderr = 0;
                    owner_matches = 0;
                }
            }
            i = (size_t)(closing - console_bytes.data) + 1;
            continue;
        }
        if (owner_matches && owner_stdout) (void)buffer_append(out, console_bytes.data + i, 1);
        else if (owner_matches && owner_stderr) (void)buffer_append(err, console_bytes.data + i, 1);
        i++;
    }
    return 0;
}

// ---------------------------------------------------------------------------
// frames and payloads
// ---------------------------------------------------------------------------

static void next_token(char *token, const char *prefix) {
    token_counter++;
    snprintf(token, MAX_TOKEN, "%s-%lu-%d", prefix, token_counter, (int)getpid());
}

static int send_control(const char *name, const char *token, const char *arguments) {
    char header[512];
    int n = arguments && arguments[0]
        ? snprintf(header, sizeof header, "\x1e" "FLOE-%s %s %s\x1e\n", name, token, arguments)
        : snprintf(header, sizeof header, "\x1e" "FLOE-%s %s\x1e\n", name, token);
    if (n <= 0 || (size_t)n >= sizeof header) return -1;
    return write_all_fd(runner_in, header, (size_t)n);
}

static int send_payload(const char *name, const char *token, const buffer *payload, int allow_inline) {
    char *encoded = base64_encode(payload->data, payload->len);
    if (!encoded) return -1;
    int result = -1;
    if (allow_inline) {
        size_t line_len = strlen(name) + strlen(token) + strlen(encoded) + 8;
        if (line_len <= INLINE_LIMIT) {
            char *line = malloc(line_len + 32);
            if (line) {
                int n = snprintf(line, line_len + 32, "\x1e" "FLOE-%s %s %s\n", name, token, encoded);
                if (n > 0) result = write_all_fd(runner_in, line, (size_t)n);
                free(line);
            }
            free(encoded);
            return result;
        }
    }
    char header[256];
    size_t length = strlen(encoded);
    size_t chunks = (length + CHUNK_CHARS - 1) / CHUNK_CHARS;
    if (chunks == 0) chunks = 1;
    int n = snprintf(header, sizeof header, "\x1e" "FLOE-%s %s %zu %zu\x1e\n",
                     name, token, payload->len, chunks);
    if (n <= 0 || (size_t)n >= sizeof header) {
        free(encoded);
        return -1;
    }
    if (write_all_fd(runner_in, header, (size_t)n) != 0) goto done;
    for (size_t index = 0; index < chunks; index++) {
        size_t offset = index * CHUNK_CHARS;
        size_t len = length - offset;
        if (len > CHUNK_CHARS) len = CHUNK_CHARS;
        char chunk_header[128];
        int cn = snprintf(chunk_header, sizeof chunk_header,
                          "\x1e" "FLOE-CHUNK %s %zu ", token, index);
        if (cn <= 0 || (size_t)cn >= sizeof chunk_header) goto done;
        if (write_all_fd(runner_in, chunk_header, (size_t)cn) != 0) goto done;
        if (write_all_fd(runner_in, encoded + offset, len) != 0) goto done;
        if (write_all_fd(runner_in, "\x1e\n", 2) != 0) goto done;
    }
    result = send_control("RUN", token, NULL);
done:
    free(encoded);
    return result;
}

typedef struct {
    const char *name;
    const char *value;
} env_entry;

static void append_env_block(buffer *payload, const env_entry *entries, int count) {
    buffer_append_u32(payload, (uint32_t)count);
    for (int i = 0; i < count; i++) {
        size_t len = strlen(entries[i].name);
        buffer_append_u32(payload, (uint32_t)len);
        (void)buffer_append(payload, entries[i].name, len);
        size_t value_len = strlen(entries[i].value);
        buffer_append_u32(payload, (uint32_t)value_len);
        if (value_len > 0) (void)buffer_append(payload, entries[i].value, value_len);
    }
}

static void append_env_field(buffer *payload, const env_entry *env, int envc,
                             const unsigned char *raw_env, size_t raw_env_len) {
    buffer block = {0};
    if (raw_env) (void)buffer_append(&block, raw_env, raw_env_len);
    else append_env_block(&block, env, envc);
    buffer_append_u32(payload, (uint32_t)block.len);
    if (block.len > 0) (void)buffer_append(payload, block.data, block.len);
    buffer_free(&block);
}

static void build_exec_payload(buffer *payload, const char *cwd, const char *stdin_data,
                               const env_entry *env, int envc,
                               const unsigned char *raw_env, size_t raw_env_len,
                               const char *const argv[], int argc) {
    unsigned char *no_stdin = (unsigned char *)"";
    size_t stdin_len = stdin_data ? strlen(stdin_data) : 0;
    unsigned char *stdin_bytes = stdin_data ? (unsigned char *)stdin_data : no_stdin;
    int has_env = env != NULL || raw_env != NULL;
    buffer_append_u32(payload, (uint32_t)(2 + (has_env ? 1 : 0) + (size_t)argc));
    buffer_append_field(payload, cwd, strlen(cwd));
    buffer_append_field(payload, stdin_bytes, stdin_len);
    if (has_env) append_env_field(payload, env, envc, raw_env, raw_env_len);
    for (int i = 0; i < argc; i++) buffer_append_field(payload, argv[i], strlen(argv[i]));
}

// Runs one command and extracts its stdout/stderr/exit code.
static int run_command(const char *name, int expect_env,
                       const env_entry *env, int envc,
                       const unsigned char *raw_env, size_t raw_env_len,
                       const char *const argv[], int argc,
                       const char *stdin_data, buffer *out, buffer *err,
                       int *exit_code, int timeout_ms) {
    (void)expect_env; // the frame name selects the payload layout
    char token[MAX_TOKEN];
    next_token(token, "t");
    buffer payload = {0};
    build_exec_payload(&payload, "/", stdin_data, env, envc, raw_env, raw_env_len, argv, argc);
    if (send_payload(name, token, &payload, 1) != 0) {
        buffer_free(&payload);
        return -1;
    }
    buffer_free(&payload);
    char tokens[1][MAX_TOKEN];
    snprintf(tokens[0], sizeof tokens[0], "%s", token);
    if (read_until_ends(tokens, 1, timeout_ms) != 0) return -2;
    return extract_token(token, out, err, exit_code);
}

static int hello(void) {
    char token[MAX_TOKEN];
    next_token(token, "hello");
    if (send_control("HELLO", token, NULL) != 0) return -1;
    char tokens[1][MAX_TOKEN];
    snprintf(tokens[0], sizeof tokens[0], "%s", token);
    if (read_until_ends(tokens, 1, 5000) != 0) return -2;
    return 0;
}

// ---------------------------------------------------------------------------
// checks
// ---------------------------------------------------------------------------

static void reset_console(void) {
    console_bytes.len = 0;
}

static int output_contains(const buffer *b, const char *needle) {
    size_t needle_len = strlen(needle);
    if (b->len < needle_len) return 0;
    for (size_t i = 0; i + needle_len <= b->len; i++) {
        if (memcmp(b->data + i, needle, needle_len) == 0) return 1;
    }
    return 0;
}

static void expect_exit(buffer *out, int code, int expected_code, const char *label) {
    char text[256];
    size_t copy = out->len < sizeof text - 1 ? out->len : sizeof text - 1;
    memcpy(text, out->data, copy);
    text[copy] = '\0';
    check(code == expected_code, "%s: exit code %d (expected %d), output: %s",
          label, code, expected_code, text);
}

static void test_caps(void) {
    reset_console();
    check(hello() == 0, "HELLO/CAPS answered");
    const char *caps = "\x1e" "FLOE-CAPS ";
    int found = 0, env_flag = 0;
    for (size_t i = 0; i + strlen(caps) <= console_bytes.len; i++) {
        if (memcmp(console_bytes.data + i, caps, strlen(caps)) == 0) {
            found = 1;
            char tail[512];
            size_t copy = console_bytes.len - i;
            if (copy >= sizeof tail) copy = sizeof tail - 1;
            memcpy(tail, console_bytes.data + i, copy);
            tail[copy] = '\0';
            if (strstr(tail, " env=1 ") || strstr(tail, " env=1\x1e")) env_flag = 1;
            break;
        }
    }
    check(found, "CAPS frame present");
    check(env_flag, "CAPS advertises env=1");
}

static void test_basic_env(void) {
    reset_console();
    env_entry env[] = {{"FLOE_ENV_TEST_A", "alpha-sentinel-9f3a"}};
    const char *argv[] = {"/bin/sh", "-c", "printf '%s' \"$FLOE_ENV_TEST_A\""};
    buffer out = {0}, err = {0};
    int code = -999;
    check(run_command("EXECENV", 1, env, 1, NULL, 0, argv, 3, NULL, &out, &err, &code, 5000) == 0,
          "EXECENV basic: frame received");
    expect_exit(&out, code, 0, "EXECENV basic");
    check(output_contains(&out, "alpha-sentinel-9f3a"), "EXECENV basic: value reached the child envp");
    check(!output_contains(&err, "alpha-sentinel-9f3a"), "EXECENV basic: value not on stderr");
    buffer_free(&out);
    buffer_free(&err);
}

static void test_no_global_pollution(void) {
    reset_console();
    const char *argv[] = {"/bin/sh", "-c", "printf '%s' \"${FLOE_ENV_TEST_A-unset}\""};
    buffer out = {0}, err = {0};
    int code = -999;
    check(run_command("EXEC", 0, NULL, 0, NULL, 0, argv, 3, NULL, &out, &err, &code, 5000) == 0,
          "ordinary EXEC after EXECENV: frame received");
    expect_exit(&out, code, 0, "ordinary EXEC after EXECENV");
    check(output_contains(&out, "unset"), "PID 1 environment was not modified by EXECENV");
    check(!output_contains(&out, "alpha-sentinel-9f3a"), "previous secret is absent from the next process");
    buffer_free(&out);
    buffer_free(&err);
}

static void test_stdin_independent(void) {
    reset_console();
    env_entry env[] = {{"FLOE_ENV_SECRET", "env-sentinel-4b21"}};
    const char *argv[] = {"/bin/sh", "-c", "cat"};
    const char *stdin_data = "stdin-sentinel-a77c";
    buffer out = {0}, err = {0};
    int code = -999;
    check(run_command("EXECENV", 1, env, 1, NULL, 0, argv, 3, stdin_data, &out, &err, &code, 5000) == 0,
          "EXECENV stdin: frame received");
    expect_exit(&out, code, 0, "EXECENV stdin");
    check(output_contains(&out, stdin_data), "stdin remains an independent channel");
    check(!output_contains(&out, "env-sentinel-4b21"), "env value did not leak into stdin/output");
    buffer_free(&out);
    buffer_free(&err);
}

static void test_two_concurrent_secrets(void) {
    reset_console();
    char token_a[MAX_TOKEN], token_b[MAX_TOKEN];
    next_token(token_a, "cona");
    next_token(token_b, "conb");
    env_entry env_a[] = {{"FLOE_ENV_CONCURRENT_A", "concurrent-A-1f2e"}};
    env_entry env_b[] = {{"FLOE_ENV_CONCURRENT_B", "concurrent-B-8d4c"}};
    const char *argv_a[] = {"/bin/sh", "-c", "sleep 0.3; printf '%s' \"$FLOE_ENV_CONCURRENT_A\""};
    const char *argv_b[] = {"/bin/sh", "-c", "sleep 0.3; printf '%s' \"$FLOE_ENV_CONCURRENT_B\""};
    buffer payload_a = {0}, payload_b = {0};
    build_exec_payload(&payload_a, "/", NULL, env_a, 1, NULL, 0, argv_a, 3);
    build_exec_payload(&payload_b, "/", NULL, env_b, 1, NULL, 0, argv_b, 3);
    int sent = send_payload("EXECENV", token_a, &payload_a, 1);
    sent |= send_payload("EXECENV", token_b, &payload_b, 1);
    buffer_free(&payload_a);
    buffer_free(&payload_b);
    check(sent == 0, "concurrent EXECENV: both frames sent");
    char tokens[2][MAX_TOKEN];
    snprintf(tokens[0], sizeof tokens[0], "%s", token_a);
    snprintf(tokens[1], sizeof tokens[1], "%s", token_b);
    check(read_until_ends(tokens, 2, 8000) == 0, "concurrent EXECENV: both commands ended");
    buffer out_a = {0}, err_a = {0}, out_b = {0}, err_b = {0};
    int code_a = -999, code_b = -999;
    extract_token(token_a, &out_a, &err_a, &code_a);
    extract_token(token_b, &out_b, &err_b, &code_b);
    expect_exit(&out_a, code_a, 0, "concurrent A");
    expect_exit(&out_b, code_b, 0, "concurrent B");
    check(output_contains(&out_a, "concurrent-A-1f2e"), "concurrent A received its own value");
    check(output_contains(&out_b, "concurrent-B-8d4c"), "concurrent B received its own value");
    check(!output_contains(&out_a, "concurrent-B-8d4c"), "concurrent A never saw B's value");
    check(!output_contains(&out_b, "concurrent-A-1f2e"), "concurrent B never saw A's value");
    buffer_free(&out_a);
    buffer_free(&err_a);
    buffer_free(&out_b);
    buffer_free(&err_b);
}

static int invalid_env_case(const char *label, const unsigned char *block, size_t length,
                            const char *secret_sentinel) {
    reset_console();
    const char *argv[] = {"/bin/sh", "-c", "printf 'ran'"};
    buffer out = {0}, err = {0};
    int code = -999;
    int rc = run_command("EXECENV", 1, NULL, 0, block, length, argv, 3, NULL, &out, &err, &code, 5000);
    check(rc == 0, "%s: runner answered", label);
    expect_exit(&out, code, 125, label);
    char combined[512];
    size_t a = out.len < sizeof combined - 1 ? out.len : sizeof combined - 1;
    memcpy(combined, out.data, a);
    size_t b = err.len < sizeof combined - 1 - a ? err.len : sizeof combined - 1 - a;
    memcpy(combined + a, err.data, b);
    combined[a + b] = '\0';
    check(strstr(combined, "malformed EXECENV") != NULL, "%s: actionable generic failure", label);
    check(secret_sentinel == NULL || strstr(combined, secret_sentinel) == NULL,
          "%s: failure text does not echo the environment value", label);
    check(strstr(combined, "ran") == NULL, "%s: no child was started", label);
    buffer_free(&out);
    buffer_free(&err);
    return 0;
}

static void test_invalid_name(void) {
    buffer block = {0};
    buffer_append_u32(&block, 1);
    const char *name = "BAD-NAME";
    const char *value = "invalid-name-sentinel";
    buffer_append_u32(&block, (uint32_t)strlen(name));
    (void)buffer_append(&block, name, strlen(name));
    buffer_append_u32(&block, (uint32_t)strlen(value));
    (void)buffer_append(&block, value, strlen(value));
    invalid_env_case("invalid env name", block.data, block.len, value);
    buffer_free(&block);
}

static void test_oversize_value(void) {
    static unsigned char block[256 * 1024];
    size_t offset = 0;
    size_t value_len = 40 * 1024;
    const char *name = "FLOE_ENV_OVERSIZE";
    uint32_t count = 1, name_len = (uint32_t)strlen(name), value32 = (uint32_t)value_len;
    memcpy(block + offset, &(unsigned char[4]){(unsigned char)(count >> 24), (unsigned char)(count >> 16), (unsigned char)(count >> 8), (unsigned char)count}, 4); offset += 4;
    memcpy(block + offset, &(unsigned char[4]){(unsigned char)(name_len >> 24), (unsigned char)(name_len >> 16), (unsigned char)(name_len >> 8), (unsigned char)name_len}, 4); offset += 4;
    memcpy(block + offset, name, name_len); offset += name_len;
    memcpy(block + offset, &(unsigned char[4]){(unsigned char)(value32 >> 24), (unsigned char)(value32 >> 16), (unsigned char)(value32 >> 8), (unsigned char)value32}, 4); offset += 4;
    memset(block + offset, 'x', value_len); offset += value_len;
    invalid_env_case("oversized env value", block, offset, NULL);
}

static void test_duplicate_name(void) {
    buffer block = {0};
    const char *name = "FLOE_ENV_DUP";
    const char *a = "dup-one-sentinel";
    const char *b = "dup-two-sentinel";
    buffer_append_u32(&block, 2);
    for (int i = 0; i < 2; i++) {
        const char *value = i == 0 ? a : b;
        buffer_append_u32(&block, (uint32_t)strlen(name));
        (void)buffer_append(&block, name, strlen(name));
        buffer_append_u32(&block, (uint32_t)strlen(value));
        (void)buffer_append(&block, value, strlen(value));
    }
    invalid_env_case("duplicate env name", block.data, block.len, a);
    buffer_free(&block);
}

static void test_truncated_block(void) {
    buffer block = {0};
    buffer_append_u32(&block, 2);
    const char *name = "FLOE_ENV_TRUNC";
    const char *value = "truncated-sentinel";
    buffer_append_u32(&block, (uint32_t)strlen(name));
    (void)buffer_append(&block, name, strlen(name));
    buffer_append_u32(&block, (uint32_t)strlen(value));
    (void)buffer_append(&block, value, strnlen(value, 4));
    invalid_env_case("truncated env block", block.data, block.len, NULL);
    buffer_free(&block);
}

static void test_nul_value(void) {
    buffer block = {0};
    const char *name = "FLOE_ENV_NUL";
    buffer_append_u32(&block, 1);
    buffer_append_u32(&block, (uint32_t)strlen(name));
    (void)buffer_append(&block, name, strlen(name));
    buffer_append_u32(&block, 6);
    (void)buffer_append(&block, "ab\0cd", 6);
    invalid_env_case("NUL in env value", block.data, block.len, NULL);
    buffer_free(&block);
}

static void test_too_many_entries(void) {
    buffer block = {0};
    buffer_append_u32(&block, 65);
    for (int i = 0; i < 65; i++) {
        char name[32];
        snprintf(name, sizeof name, "FLOE_ENV_MANY_%d", i);
        const char *value = "v";
        buffer_append_u32(&block, (uint32_t)strlen(name));
        (void)buffer_append(&block, name, strlen(name));
        buffer_append_u32(&block, (uint32_t)strlen(value));
        (void)buffer_append(&block, value, strlen(value));
    }
    invalid_env_case("too many env entries", block.data, block.len, NULL);
    buffer_free(&block);
}

static void test_newline_value(void) {
    reset_console();
    env_entry env[] = {{"FLOE_ENV_MULTILINE", "line1\nline2"}};
    const char *argv[] = {"/bin/sh", "-c", "printf '%s' \"$FLOE_ENV_MULTILINE\""};
    buffer out = {0}, err = {0};
    int code = -999;
    check(run_command("EXECENV", 1, env, 1, NULL, 0, argv, 3, NULL, &out, &err, &code, 5000) == 0,
          "multiline value: frame received");
    expect_exit(&out, code, 0, "multiline env value");
    check(output_contains(&out, "line1\nline2"), "a newline is legal inside a value");
    buffer_free(&out);
    buffer_free(&err);
}

static void test_open_env_pty(void) {
    reset_console();
    char token[MAX_TOKEN];
    next_token(token, "ptyenv");
    env_entry env[] = {{"FLOE_ENV_PTY", "pty-sentinel-63b7"}};
    const char *argv[] = {"/bin/sh", "-c", "printf '%s' \"$FLOE_ENV_PTY\""};
    buffer payload = {0};
    buffer_append_u32(&payload, (uint32_t)(5 + 3));
    buffer_append_field(&payload, "pty", 3);
    buffer_append_field(&payload, "/", 1);
    buffer_append_field(&payload, "80", 2);
    buffer_append_field(&payload, "24", 2);
    append_env_field(&payload, env, 1, NULL, 0);
    for (int i = 0; i < 3; i++) buffer_append_field(&payload, argv[i], strlen(argv[i]));
    int sent = send_payload("OPENENV", token, &payload, 0);
    buffer_free(&payload);
    check(sent == 0, "OPENENV: frame sent");
    char tokens[1][MAX_TOKEN];
    snprintf(tokens[0], sizeof tokens[0], "%s", token);
    check(read_until_ends(tokens, 1, 8000) == 0, "OPENENV: session ended");
    buffer out = {0}, err = {0};
    int code = -999;
    extract_token(token, &out, &err, &code);
    expect_exit(&out, code, 0, "OPENENV");
    check(output_contains(&out, "pty-sentinel-63b7"), "PTY child received the per-process environment");
    buffer_free(&out);
    buffer_free(&err);
}

static void test_ordinary_exec_still_works(void) {
    reset_console();
    const char *argv[] = {"/bin/sh", "-c", "printf 'ordinary-ok'"};
    buffer out = {0}, err = {0};
    int code = -999;
    check(run_command("EXEC", 0, NULL, 0, NULL, 0, argv, 3, NULL, &out, &err, &code, 5000) == 0,
          "ordinary EXEC: frame received");
    expect_exit(&out, code, 0, "ordinary EXEC");
    check(output_contains(&out, "ordinary-ok"), "ordinary EXEC output is unchanged");
    buffer_free(&out);
    buffer_free(&err);
}

static void test_host_archive_env_rejected(void) {
    reset_console();
    env_entry env[] = {{"FLOE_ENV_HOST", "host-archive-sentinel"}};
    const char *argv[] = {"floe-host", "archive", "list", "--source", "/tmp"};
    buffer out = {0}, err = {0};
    int code = -999;
    check(run_command("EXECENV", 1, env, 1, NULL, 0, argv, 5, NULL, &out, &err, &code, 5000) == 0,
          "floe-host with env: runner answered");
    expect_exit(&out, code, 125, "floe-host with env");
    buffer_free(&out);
    buffer_free(&err);
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s <floe-exec-host-build>\n", argv[0]);
        return 2;
    }
    signal(SIGPIPE, SIG_IGN);
    if (start_runner(argv[1]) != 0) {
        fprintf(stderr, "cannot start runner\n");
        return 2;
    }
    test_caps();
    test_basic_env();
    test_no_global_pollution();
    test_stdin_independent();
    test_newline_value();
    test_two_concurrent_secrets();
    test_invalid_name();
    test_oversize_value();
    test_duplicate_name();
    test_truncated_block();
    test_nul_value();
    test_too_many_entries();
    test_open_env_pty();
    test_ordinary_exec_still_works();
    test_host_archive_env_rejected();
    stop_runner();
    buffer_free(&console_bytes);
    printf("env transport: %d passed, %d failed\n", passes, failures);
    return failures == 0 ? 0 : 1;
}
