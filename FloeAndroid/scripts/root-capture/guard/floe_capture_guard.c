/* SPDX-License-Identifier: MPL-2.0
 *
 * Floe root-capture guard. See floe_capture_guard.h for the contract.
 *
 * This file is intentionally portable POSIX C (bionic and host libc): it uses
 * poll(2), clock_gettime(2), setrlimit(2), pthreads and stat(2) only. It never
 * trusts environment variables, argv or model-supplied flags. The only input
 * is the single configuration record read from the inherited stdin pipe.
 */
#define _GNU_SOURCE

#include "floe_capture_guard.h"

/* The pinned-helper build generates this header from the exact guard source,
 * header and patch bytes; host contract tests supply the macros directly. */
#if !defined(FLOE_GUARD_SOURCE_SHA256) || !defined(FLOE_GUARD_HEADER_SHA256) || \
    !defined(FLOE_GUARD_PATCH_SHA256)
#include "floe_guard_identity.h"
#endif

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#ifndef FLOE_GUARD_SOURCE_SHA256
#error "FLOE_GUARD_SOURCE_SHA256 must be supplied by scripts/root-capture/build-helper.sh"
#endif
#ifndef FLOE_GUARD_HEADER_SHA256
#error "FLOE_GUARD_HEADER_SHA256 must be supplied by scripts/root-capture/build-helper.sh"
#endif
#ifndef FLOE_GUARD_PATCH_SHA256
#error "FLOE_GUARD_PATCH_SHA256 must be supplied by scripts/root-capture/build-helper.sh"
#endif

#define FLOE_GUARD_READY_TIMEOUT_MS 5000
#define FLOE_GUARD_POLL_MS 200
#define FLOE_GUARD_GRACE_MS 3000
#define FLOE_GUARD_MAX_STAT_ERRORS 5
#define FLOE_GUARD_PCAP_HEADROOM (24u + 16u + 65535u)

/* Keep this referenced so llvm-strip --strip-all cannot drop it. */
static const char floe_guard_identity[] __attribute__((used)) =
    FLOE_GUARD_IDENTITY_MAGIC FLOE_GUARD_ABI "|"
    "1|" FLOE_GUARD_SOURCE_SHA256 "|"
    FLOE_GUARD_HEADER_SHA256 "|"
    FLOE_GUARD_PATCH_SHA256;

struct floe_guard_state {
    struct floe_guard_config config;
    uint64_t deadline_ms;
    uint64_t soft_limit;
    int sidecar_fd;
    int stop_written;
    pthread_t thread;
};

static struct floe_guard_state g_state;

static uint64_t monotonic_millis(void)
{
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0)
        return 0;
    return (uint64_t)ts.tv_sec * 1000ULL + (uint64_t)ts.tv_nsec / 1000000ULL;
}

static int all_digits(const char *value, size_t max_length)
{
    size_t length = strlen(value);
    size_t index;
    if (length == 0 || length > max_length)
        return 0;
    for (index = 0; index < length; index++) {
        if (value[index] < '0' || value[index] > '9')
            return 0;
    }
    return 1;
}

static int parse_u64(const char *value, size_t max_length, uint64_t *out)
{
    uint64_t result = 0;
    size_t index;
    if (!all_digits(value, max_length))
        return -1;
    for (index = 0; value[index] != '\0'; index++) {
        uint64_t digit = (uint64_t)(value[index] - '0');
        if (result > (UINT64_MAX - digit) / 10ULL)
            return -1;
        result = result * 10ULL + digit;
    }
    *out = result;
    return 0;
}

int floe_capture_guard_parse_config(const char *line, struct floe_guard_config *out)
{
    char copy[FLOE_GUARD_MAX_CONFIG + 1];
    char *first_space;
    char *second_space;
    char *third_space;
    char *path;
    uint64_t millis = 0;
    uint64_t bytes = 0;
    size_t length;

    if (line == NULL || out == NULL)
        return -1;
    length = strlen(line);
    if (length == 0 || length > FLOE_GUARD_MAX_CONFIG)
        return -1;
    memcpy(copy, line, length + 1);
    if (copy[length - 1] == '\n')
        copy[length - 1] = '\0';
    if (strchr(copy, '\n') != NULL || strchr(copy, '\r') != NULL)
        return -1;
    if (strncmp(copy, FLOE_GUARD_CONFIG_SCHEMA " ", strlen(FLOE_GUARD_CONFIG_SCHEMA) + 1) != 0)
        return -1;
    first_space = copy + strlen(FLOE_GUARD_CONFIG_SCHEMA);
    second_space = strchr(first_space + 1, ' ');
    if (second_space == NULL)
        return -1;
    *first_space = '\0';
    *second_space = '\0';
    third_space = strchr(second_space + 1, ' ');
    if (third_space == NULL || third_space[1] == '\0')
        return -1;
    *third_space = '\0';
    path = third_space + 1;
    if (parse_u64(first_space + 1, 10, &millis) != 0)
        return -1;
    if (parse_u64(second_space + 1, 12, &bytes) != 0)
        return -1;
    if (millis < 1ULL || millis > FLOE_GUARD_MAX_MILLIS)
        return -1;
    if (bytes < 4096ULL || bytes > FLOE_GUARD_MAX_BYTES)
        return -1;
    if (path[0] != '/' || strlen(path) >= FLOE_GUARD_MAX_PATH)
        return -1;
    if (strchr(path, '\n') != NULL || strchr(path, '\r') != NULL)
        return -1;

    memset(out, 0, sizeof(*out));
    out->max_millis = millis;
    out->max_bytes = bytes;
    memcpy(out->output_path, path, strlen(path) + 1);
    return 0;
}

static int read_config_line(char *buffer, size_t capacity, int timeout_ms)
{
    size_t used = 0;
    uint64_t deadline = monotonic_millis() + (uint64_t)timeout_ms;

    for (;;) {
        struct pollfd descriptor;
        uint64_t now = monotonic_millis();
        int remaining;
        int ready;
        char byte;

        if (now >= deadline)
            return -1;
        remaining = (int)(deadline - now);
        if (remaining > 250)
            remaining = 250;
        descriptor.fd = STDIN_FILENO;
        descriptor.events = POLLIN;
        descriptor.revents = 0;
        ready = poll(&descriptor, 1, remaining);
        if (ready < 0) {
            if (errno == EINTR)
                continue;
            return -1;
        }
        if (ready == 0)
            continue;
        if ((descriptor.revents & POLLIN) != 0) {
            ssize_t count = read(STDIN_FILENO, &byte, 1);
            if (count == 0)
                return -1;
            if (count < 0) {
                if (errno == EINTR || errno == EAGAIN)
                    continue;
                return -1;
            }
        } else if ((descriptor.revents & (POLLHUP | POLLERR | POLLNVAL)) != 0) {
            /* EOF before a complete configuration record. */
            return -1;
        } else {
            continue;
        }
        if (byte == '\0')
            return -1;
        if (used + 1 >= capacity)
            return -1;
        buffer[used++] = byte;
        if (byte == '\n') {
            buffer[used] = '\0';
            return 0;
        }
    }
}

const char *floe_capture_guard_stop_reason(const char *line)
{
    static const char *const allowed[] = {
        "durationLimit",
        "sizeLimit",
        "daemonLost",
        "outputError",
    };
    const char *cursor;
    size_t index;

    if (line == NULL)
        return NULL;
    if (strncmp(line, "stop ", 5) != 0 && strncmp(line, "hard_stop ", 10) != 0)
        return NULL;
    cursor = strstr(line, "reason=");
    if (cursor == NULL)
        return NULL;
    cursor += 7;
    for (index = 0; index < sizeof(allowed) / sizeof(allowed[0]); index++) {
        size_t length = strlen(allowed[index]);
        if (strncmp(cursor, allowed[index], length) == 0 &&
            (cursor[length] == ' ' || cursor[length] == '\n' ||
             cursor[length] == '\0')) {
            return allowed[index];
        }
    }
    return NULL;
}

static int write_all(int fd, const char *data, size_t length)
{
    size_t written = 0;
    while (written < length) {
        ssize_t count = write(fd, data + written, length - written);
        if (count < 0) {
            if (errno == EINTR)
                continue;
            return -1;
        }
        if (count == 0)
            return -1;
        written += (size_t)count;
    }
    return 0;
}

static int append_record(const char *format, ...)
{
    char record[512];
    va_list arguments;
    int length;
    int result;

    va_start(arguments, format);
    length = vsnprintf(record, sizeof(record), format, arguments);
    va_end(arguments);
    if (length < 0 || (size_t)length >= sizeof(record))
        return -1;
    result = write_all(g_state.sidecar_fd, record, (size_t)length);
    if (result == 0)
        result = fsync(g_state.sidecar_fd);
    return result;
}

static void write_stop_record(const char *reason, int forced)
{
    struct stat facts;
    long long size = -1;

    if (g_state.stop_written)
        return;
    g_state.stop_written = 1;
    if (stat(g_state.config.output_path, &facts) == 0)
        size = (long long)facts.st_size;
    append_record(
        "stop schema=%s reason=%s forced=%d pid=%ld bytes=%lld\n",
        FLOE_GUARD_SIDECAR_SCHEMA,
        reason,
        forced,
        (long)getpid(),
        size);
}

static void hard_stop_record(const char *reason)
{
    append_record(
        "hard_stop schema=%s reason=%s forced=1 pid=%ld\n",
        FLOE_GUARD_SIDECAR_SCHEMA,
        reason,
        (long)getpid());
}

static void *guard_thread(void *unused)
{
    int stat_errors = 0;
    const char *reason = NULL;

    (void)unused;
    for (;;) {
        struct pollfd descriptor;
        uint64_t now;
        int ready;

        descriptor.fd = STDIN_FILENO;
        descriptor.events = POLLIN;
        descriptor.revents = 0;
        ready = poll(&descriptor, 1, FLOE_GUARD_POLL_MS);
        if (ready < 0 && errno != EINTR) {
            reason = "daemonLost";
            break;
        }
        if (ready > 0) {
            if ((descriptor.revents & (POLLHUP | POLLERR | POLLNVAL)) != 0) {
                reason = "daemonLost";
                break;
            }
            if ((descriptor.revents & POLLIN) != 0) {
                char discard[64];
                ssize_t count = read(STDIN_FILENO, discard, sizeof(discard));
                if (count == 0) {
                    reason = "daemonLost";
                    break;
                }
                if (count < 0 && errno != EINTR && errno != EAGAIN) {
                    reason = "daemonLost";
                    break;
                }
                /* Unexpected post-config data is drained, not treated as a
                 * stop; the write end being open is enough liveness proof. */
            }
        }

        now = monotonic_millis();
        if (now >= g_state.deadline_ms) {
            reason = "durationLimit";
            break;
        }
        {
            struct stat facts;
            if (stat(g_state.config.output_path, &facts) == 0) {
                stat_errors = 0;
                if ((uint64_t)facts.st_size >= g_state.soft_limit) {
                    reason = "sizeLimit";
                    break;
                }
            } else if (errno != ENOENT) {
                stat_errors++;
                if (stat_errors >= FLOE_GUARD_MAX_STAT_ERRORS) {
                    reason = "outputError";
                    break;
                }
            }
        }
    }

    write_stop_record(reason, 0);
    kill(getpid(), SIGTERM);
    {
        struct timespec pause;
        int index;
        pause.tv_sec = 0;
        pause.tv_nsec = 100L * 1000L * 1000L;
        for (index = 0; index < FLOE_GUARD_GRACE_MS / 100; index++)
            nanosleep(&pause, NULL);
    }
    hard_stop_record(reason);
    _exit(124);
    return NULL;
}

int floe_capture_guard_install(const char *wfile)
{
    char line[FLOE_GUARD_MAX_CONFIG + 1];
    struct floe_guard_config config;
    struct rlimit limit;
    char sidecar[FLOE_GUARD_MAX_PATH + 16];
    uint64_t soft_limit;
    int sidecar_length;
    int sidecar_fd;

    if (wfile == NULL || floe_guard_identity[0] == '\0')
        return -1;
    if (read_config_line(line, sizeof(line), FLOE_GUARD_READY_TIMEOUT_MS) != 0)
        return -1;
    if (floe_capture_guard_parse_config(line, &config) != 0)
        return -1;
    if (strcmp(config.output_path, wfile) != 0)
        return -1;

    /* Kernel backstop for the byte budget. The guard's soft limit stops a
     * packet record before this point; if capture is still writing, the
     * kernel refuses the growth at exactly max_bytes. */
    limit.rlim_cur = (rlim_t)config.max_bytes;
    limit.rlim_max = (rlim_t)config.max_bytes;
    if (setrlimit(RLIMIT_FSIZE, &limit) != 0)
        return -1;

    sidecar_length = snprintf(
        sidecar, sizeof(sidecar), "%s.guard", config.output_path);
    if (sidecar_length < 0 || (size_t)sidecar_length >= sizeof(sidecar))
        return -1;
    sidecar_fd = open(
        sidecar,
        O_WRONLY | O_CREAT | O_EXCL | O_APPEND | O_NOFOLLOW | O_CLOEXEC,
        0600);
    if (sidecar_fd < 0)
        return -1;

    memset(&g_state, 0, sizeof(g_state));
    g_state.config = config;
    g_state.sidecar_fd = sidecar_fd;
    /* Leave one maximum PCAP record of headroom so a graceful stop normally
     * finishes below the hard limit. Tiny budgets use the hard limit. */
    soft_limit = config.max_bytes;
    if (soft_limit > FLOE_GUARD_PCAP_HEADROOM)
        soft_limit -= FLOE_GUARD_PCAP_HEADROOM;
    g_state.soft_limit = soft_limit;
    g_state.deadline_ms = monotonic_millis() + config.max_millis;

    /* Start the watcher before announcing readiness: a failed thread
     * creation must never be presented to the server as a guarded helper. */
    if (pthread_create(&g_state.thread, NULL, guard_thread, NULL) != 0) {
        close(sidecar_fd);
        g_state.sidecar_fd = -1;
        return -1;
    }
    pthread_detach(g_state.thread);

    if (append_record(
            "ready schema=%s version=%d pid=%ld max_millis=%llu max_bytes=%llu\n",
            FLOE_GUARD_SIDECAR_SCHEMA,
            FLOE_GUARD_VERSION,
            (long)getpid(),
            (unsigned long long)config.max_millis,
            (unsigned long long)config.max_bytes) != 0) {
        close(sidecar_fd);
        g_state.sidecar_fd = -1;
        return -1;
    }
    return 0;
}
