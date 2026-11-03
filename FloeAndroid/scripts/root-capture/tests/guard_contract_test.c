/* SPDX-License-Identifier: MPL-2.0
 *
 * Host contract test for the embedded Floe root-capture guard.
 *
 * This is not the helper build. It compiles the exact guard source with the
 * host C compiler and exercises the real pipe / deadline / size / signal /
 * sidecar paths in forked processes. The tcpdump integration is represented by
 * a main loop that installs the same SIGTERM handler tcpdump uses and exits on
 * it; everything under test is the production guard code.
 */
#define _GNU_SOURCE

#include "floe_capture_guard.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static volatile sig_atomic_t stop_requested = 0;
static char test_directory[4096];
static int failures = 0;

static void on_signal(int signal_number)
{
    (void)signal_number;
    stop_requested = 1;
}

static uint64_t monotonic_millis(void)
{
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0)
        return 0;
    return (uint64_t)ts.tv_sec * 1000ULL + (uint64_t)ts.tv_nsec / 1000000ULL;
}

static void fail(const char *format, ...)
{
    va_list arguments;
    va_start(arguments, format);
    fprintf(stderr, "FAIL: ");
    vfprintf(stderr, format, arguments);
    fprintf(stderr, "\n");
    va_end(arguments);
    failures++;
}

static int write_text(int fd, const char *text)
{
    size_t length = strlen(text);
    size_t written = 0;
    while (written < length) {
        ssize_t count = write(fd, text + written, length - written);
        if (count < 0) {
            if (errno == EINTR)
                continue;
            return -1;
        }
        written += (size_t)count;
    }
    return 0;
}

static long read_bounded(const char *path, char *buffer, size_t capacity)
{
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    ssize_t count;
    if (fd < 0)
        return -1;
    count = read(fd, buffer, capacity - 1);
    close(fd);
    if (count < 0)
        return -1;
    buffer[count] = '\0';
    return (long)count;
}

static const char *last_stop_reason(const char *text)
{
    const char *cursor = text;
    const char *reason = NULL;
    while ((cursor = strstr(cursor, "reason=")) != NULL) {
        const char *value = cursor + 7;
        static char captured[32];
        size_t index = 0;
        while (value[index] != '\0' && value[index] != ' ' &&
               value[index] != '\n' && index + 1 < sizeof(captured)) {
            captured[index] = value[index];
            index++;
        }
        captured[index] = '\0';
        if (strchr(text, '\n') != NULL)
            reason = captured;
        cursor = value;
    }
    return reason;
}

static int has_line(const char *text, const char *prefix)
{
    const char *cursor = text;
    size_t length = strlen(prefix);
    while (cursor != NULL && *cursor != '\0') {
        if (strncmp(cursor, prefix, length) == 0)
            return 1;
        cursor = strchr(cursor, '\n');
        if (cursor != NULL)
            cursor++;
    }
    return 0;
}

static int wait_for_file(const char *path, int timeout_ms)
{
    uint64_t deadline = monotonic_millis() + (uint64_t)timeout_ms;
    struct stat facts;
    while (monotonic_millis() < deadline) {
        if (stat(path, &facts) == 0 && facts.st_size > 0)
            return 0;
        usleep(10000);
    }
    return -1;
}

static int wait_child(pid_t pid, int timeout_ms, int *status)
{
    uint64_t deadline = monotonic_millis() + (uint64_t)timeout_ms;
    for (;;) {
        pid_t result = waitpid(pid, status, WNOHANG);
        if (result == pid)
            return 0;
        if (result < 0 && errno != EINTR)
            return -1;
        if (monotonic_millis() >= deadline)
            return -1;
        usleep(20000);
    }
}

static void case_path(const char *name, char *out, size_t capacity)
{
    snprintf(out, capacity, "%s/%s.pcap", test_directory, name);
}

static pid_t start_child(const char *output, int mode, int read_fd, int write_fd)
{
    pid_t pid = fork();
    if (pid < 0)
        return -1;
    if (pid == 0) {
        int fd;
        uint64_t deadline;
        if (write_fd >= 0)
            close(write_fd);
        if (dup2(read_fd, STDIN_FILENO) < 0)
            _exit(60);
        if (mode == 5)
            signal(SIGTERM, SIG_IGN);
        else
            signal(SIGTERM, on_signal);
        fd = open(output, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
        if (fd < 0)
            _exit(61);
        if (floe_capture_guard_install(output) != 0)
            _exit(62);
        if (mode == 0) {
            /* daemonLost / duration: no writes; wait for the guard signal. */
            deadline = monotonic_millis() + 20000;
            while (!stop_requested && monotonic_millis() < deadline)
                pause();
            close(fd);
            _exit(stop_requested ? 0 : 63);
        }
        if (mode == 1) {
            /* Normal short capture: write a little and exit by itself. */
            char block[16384];
            int index;
            memset(block, 'A', sizeof(block));
            for (index = 0; index < 3 && !stop_requested; index++) {
                if (write(fd, block, sizeof(block)) != (ssize_t)sizeof(block))
                    _exit(64);
                usleep(20000);
            }
            close(fd);
            _exit(0);
        }
        if (mode == 2) {
            /* Steady writer for the size bound. */
            char block[16384];
            deadline = monotonic_millis() + 20000;
            memset(block, 'B', sizeof(block));
            while (!stop_requested && monotonic_millis() < deadline) {
                if (write(fd, block, sizeof(block)) != (ssize_t)sizeof(block))
                    break;
                usleep(100000);
            }
            close(fd);
            _exit(0);
        }
        if (mode == 5) {
            /* Ignore SIGTERM and keep growing until the kernel cap. */
            char block[65536];
            deadline = monotonic_millis() + 20000;
            memset(block, 'C', sizeof(block));
            while (monotonic_millis() < deadline) {
                if (write(fd, block, sizeof(block)) < 0)
                    break;
            }
            close(fd);
            _exit(0);
        }
        _exit(65);
    }
    return pid;
}

static void run_case(
    const char *name,
    const char *config,
    int mode,
    const char *expected_reason,
    long max_bytes,
    int close_pipe_after_ready,
    int fragmented_config,
    int minimum_elapsed_ms,
    int maximum_elapsed_ms)
{
    char output[4096];
    char sidecar[4200];
    char text[8192];
    int pipe_fds[2];
    pid_t pid;
    int status = 0;
    uint64_t started;
    uint64_t elapsed;
    struct stat facts;
    long sidecar_bytes;

    case_path(name, output, sizeof(output));
    snprintf(sidecar, sizeof(sidecar), "%s.guard", output);
    unlink(output);
    unlink(sidecar);
    if (pipe(pipe_fds) != 0) {
        fail("%s: pipe", name);
        return;
    }
    pid = start_child(output, mode, pipe_fds[0], pipe_fds[1]);
    close(pipe_fds[0]);
    if (pid < 0) {
        fail("%s: fork", name);
        close(pipe_fds[1]);
        return;
    }
    started = monotonic_millis();
    if (fragmented_config) {
        char first[64];
        size_t length = strlen(config);
        size_t split = length / 2;
        memcpy(first, config, split);
        first[split] = '\0';
        if (write_text(pipe_fds[1], first) != 0 ||
            (usleep(20000), write_text(pipe_fds[1], config + split)) != 0) {
            fail("%s: config write", name);
        }
    } else if (write_text(pipe_fds[1], config) != 0) {
        fail("%s: config write", name);
    }
    if (close_pipe_after_ready) {
        if (wait_for_file(sidecar, 2000) != 0)
            fail("%s: guard ready record missing", name);
        close(pipe_fds[1]);
        pipe_fds[1] = -1;
    }
    if (wait_child(pid, maximum_elapsed_ms + 5000, &status) != 0) {
        fail("%s: child did not exit within the hard test bound", name);
        kill(pid, SIGKILL);
        waitpid(pid, &status, 0);
        if (pipe_fds[1] >= 0)
            close(pipe_fds[1]);
        return;
    }
    elapsed = monotonic_millis() - started;
    if (pipe_fds[1] >= 0)
        close(pipe_fds[1]);

    if (!WIFEXITED(status)) {
        /* The hard-cap case may legitimately die on SIGXFSZ. */
        if (!(mode == 5 && WIFSIGNALED(status))) {
            fail("%s: unexpected termination status %#x", name, status);
            return;
        }
    } else if (WEXITSTATUS(status) != 0 && mode != 5) {
        fail("%s: child exit %d", name, WEXITSTATUS(status));
        return;
    }
    if (elapsed < (uint64_t)minimum_elapsed_ms)
        fail("%s: stopped too early (%llu ms)", name, (unsigned long long)elapsed);

    sidecar_bytes = read_bounded(sidecar, text, sizeof(text));
    if (sidecar_bytes <= 0) {
        fail("%s: no guard sidecar", name);
        return;
    }
    if (!has_line(text, "ready schema=" FLOE_GUARD_SIDECAR_SCHEMA))
        fail("%s: missing ready record", name);
    if (expected_reason != NULL) {
        const char *reason = last_stop_reason(text);
        if (reason == NULL || strcmp(reason, expected_reason) != 0)
            fail("%s: expected stop reason %s, got %s", name, expected_reason,
                 reason == NULL ? "(none)" : reason);
        if (strstr(text, "hard_stop ") != NULL && mode != 5)
            fail("%s: unexpected hard stop", name);
    } else if (mode != 5 && (has_line(text, "stop ") || has_line(text, "hard_stop "))) {
        fail("%s: unexpected stop record on a normal exit", name);
    }

    if (stat(output, &facts) != 0)
        fail("%s: output file missing after stop", name);
    else if (max_bytes >= 0 && facts.st_size > max_bytes)
        fail("%s: output %lld exceeds bound %ld", name, (long long)facts.st_size,
             max_bytes);
}

static void test_parser(void)
{
    struct floe_guard_config config;
    const char *valid =
        "floe-guard-v1 300000 134217728 /data/local/floe-capture/work/capture-x.pcap\n";
    const char *bad[] = {
        "",
        "floe-guard-v1",
        "floe-guard-v1 300000 134217728\n",
        "floe-guard-v2 300000 134217728 /x\n",
        "floe-guard-v1 0 134217728 /x\n",
        "floe-guard-v1 600001 134217728 /x\n",
        "floe-guard-v1 300000 4095 /x\n",
        "floe-guard-v1 300000 268435457 /x\n",
        "floe-guard-v1 -1 134217728 /x\n",
        "floe-guard-v1 300000 1e8 /x\n",
        "floe-guard-v1 300000 134217728 relative.pcap\n",
        "floe-guard-v1 300000 134217728 /x\nfloe-guard-v1 1 4096 /y\n",
        "floe-guard-v1 300000 134217728 /x\nextra",
    };
    size_t index;

    if (floe_capture_guard_parse_config(valid, &config) != 0)
        fail("parser: rejected the valid server record");
    else if (config.max_millis != 300000ULL || config.max_bytes != 134217728ULL ||
             strcmp(config.output_path, "/data/local/floe-capture/work/capture-x.pcap") != 0)
        fail("parser: decoded fields differ from the input");
    for (index = 0; index < sizeof(bad) / sizeof(bad[0]); index++) {
        if (floe_capture_guard_parse_config(bad[index], &config) == 0)
            fail("parser: accepted invalid record %zu", index);
    }
    if (floe_capture_guard_stop_reason("stop schema=x reason=durationLimit forced=0") == NULL)
        fail("reason: rejected durationLimit");
    if (floe_capture_guard_stop_reason("stop reason=sizeLimit") == NULL)
        fail("reason: rejected sizeLimit");
    if (floe_capture_guard_stop_reason("stop schema=x reason=madeUp") != NULL)
        fail("reason: accepted an unknown reason");
}

static void test_invalid_start(void)
{
    char output[4096];
    char sidecar[4200];
    int pipe_fds[2];
    pid_t pid;
    int status = 0;

    case_path("invalid", output, sizeof(output));
    snprintf(sidecar, sizeof(sidecar), "%s.guard", output);
    unlink(output);
    unlink(sidecar);
    if (pipe(pipe_fds) != 0) {
        fail("invalid: pipe");
        return;
    }
    pid = fork();
    if (pid == 0) {
        dup2(pipe_fds[0], STDIN_FILENO);
        signal(SIGTERM, on_signal);
        if (floe_capture_guard_install(output) != 0)
            _exit(0);
        _exit(1);
    }
    close(pipe_fds[0]);
    if (pid < 0) {
        fail("invalid: fork");
        close(pipe_fds[1]);
        return;
    }
    write_text(pipe_fds[1], "not-a-guard-record\n");
    close(pipe_fds[1]);
    if (wait_child(pid, 3000, &status) != 0)
        fail("invalid: guard did not fail closed");
    else if (!WIFEXITED(status) || WEXITSTATUS(status) != 0)
        fail("invalid: guard accepted a malformed config");
    if (access(sidecar, F_OK) == 0)
        fail("invalid: guard created a ready record for invalid config");
    unlink(output);
    unlink(sidecar);
}

int main(void)
{
    char template_path[] = "/tmp/floe-guard-test-XXXXXX";
    char *directory;
    char output[4096];
    char config[4200];
    struct stat facts;

    directory = mkdtemp(template_path);
    if (directory == NULL) {
        perror("mkdtemp");
        return 2;
    }
    snprintf(test_directory, sizeof(test_directory), "%s", directory);

    test_parser();
    test_invalid_start();

    case_path("daemon-lost", output, sizeof(output));
    snprintf(config, sizeof(config),
             "floe-guard-v1 60000 4194304 %s\n", output);
    run_case("daemon-lost", config, 0, "daemonLost", -1, 1, 1, 0, 4000);

    case_path("duration", output, sizeof(output));
    snprintf(config, sizeof(config),
             "floe-guard-v1 1000 8388608 %s\n", output);
    run_case("duration", config, 0, "durationLimit", -1, 0, 0, 800, 6000);

    case_path("size", output, sizeof(output));
    snprintf(config, sizeof(config),
             "floe-guard-v1 60000 262144 %s\n", output);
    run_case("size", config, 2, "sizeLimit", 262144, 0, 0, 0, 8000);

    case_path("normal", output, sizeof(output));
    snprintf(config, sizeof(config),
             "floe-guard-v1 60000 8388608 %s\n", output);
    run_case("normal", config, 1, NULL, -1, 0, 0, 0, 5000);

    case_path("hard-cap", output, sizeof(output));
    snprintf(config, sizeof(config),
             "floe-guard-v1 60000 131072 %s\n", output);
    run_case("hard-cap", config, 5, NULL, 131072, 0, 0, 0, 8000);
    if (stat(output, &facts) == 0 && facts.st_size > 131072)
        fail("hard-cap: output exceeds the kernel limit");

    if (failures == 0)
        printf("guard contract: PASS (%s)\n", test_directory);
    else
        printf("guard contract: %d FAILURE(S) (%s)\n", failures, test_directory);
    return failures == 0 ? 0 : 1;
}
