// clock_arg_check.c — native check for the guest boot clock parameter
// (`floe.epoch=`) parser and the bounded /proc/cmdline reader.
//
// Compiles the runner's real floe_clock.h (the same header floe_exec.c uses)
// on the developer host and checks the strict numeric rules: a valid current
// epoch, very long digit strings, negative/signed values, duplicates, empty
// and malformed values, the exact upper bound, and truncation reporting. It
// performs no clock call and no shell-out; it is NOT the host protocol check
// (that suite is tests/host_protocol_check.sh and is unaffected).
//
// Usage:
//   make -C FloeAgent/LinuxGuest/runner check-clock
// or directly:
//   cc -std=gnu11 -O2 -Wall -Wextra -Werror -o /tmp/clock-arg-check clock_arg_check.c

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "../runner/floe_clock.h"

static int g_checks;
static int g_failures;

#define CHECK(condition)                                                      \
    do {                                                                      \
        g_checks++;                                                           \
        if (!(condition)) {                                                   \
            g_failures++;                                                     \
            fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__,           \
                    #condition);                                              \
        }                                                                     \
    } while (0)

// ---------------------------------------------------------------------------
// Parser checks
// ---------------------------------------------------------------------------

static void expect_status(const char *label, const char *cmdline,
                          floe_epoch_status want) {
    int64_t value = -12345;
    floe_epoch_status got =
        floe_epoch_parse(cmdline, cmdline ? strlen(cmdline) : 0, &value);
    g_checks++;
    if (got != want) {
        g_failures++;
        fprintf(stderr, "FAIL %s: status %d (%s), want %d (%s)\n", label,
                (int)got, floe_epoch_status_text(got), (int)want,
                floe_epoch_status_text(want));
    }
    if (want != FLOE_EPOCH_OK && value != 0) {
        g_failures++;
        fprintf(stderr, "FAIL %s: rejected value must not leak (%lld)\n", label,
                (long long)value);
    }
}

static void expect_value(const char *label, const char *cmdline,
                         int64_t want) {
    int64_t value = -12345;
    floe_epoch_status got = floe_epoch_parse(cmdline, strlen(cmdline), &value);
    g_checks++;
    if (got != FLOE_EPOCH_OK || value != want) {
        g_failures++;
        fprintf(stderr, "FAIL %s: status %d value %lld, want ok %lld\n", label,
                (int)got, (long long)value, (long long)want);
    }
}

static void test_parse_accepts(void) {
    time_t now = time(NULL);
    char host_line[256];
    snprintf(host_line, sizeof host_line,
             "console=hvc0 root=/dev/vda rw loglevel=4 "
             "init=/usr/local/bin/floe-exec floe.epoch=%lld",
             (long long)now);
    expect_value("host-generated line with current epoch", host_line,
                 (int64_t)now);

    expect_value("value alone", "floe.epoch=1700000000", 1700000000);
    expect_value("zero is a valid unix second", "floe.epoch=0", 0);
    expect_value("tab and newline separators",
                 "a=1\tfloe.epoch=1700000001\nb=2\n", 1700000001);
    expect_value("surrounding whitespace",
                 "\t floe.epoch=1700000002 \n", 1700000002);
    expect_value("init= field first", "init=/sbin/init floe.epoch=1700000003",
                 1700000003);
    expect_value("rdinit= field first", "rdinit=/sbin/init floe.epoch=1700000004",
                 1700000004);
    expect_value("upper bound is inclusive", "floe.epoch=253402300799",
                 FLOE_EPOCH_MAX_SECONDS);

    // The reader gives a bounded buffer; a trailing NUL inside len is a field
    // separator like whitespace, and garbage after it is not a second key.
    {
        static const char raw[] = "floe.epoch=42\0tail";
        int64_t value = -1;
        floe_epoch_status got =
            floe_epoch_parse(raw, sizeof raw - 1, &value);
        CHECK(got == FLOE_EPOCH_OK);
        CHECK(value == 42);
    }

    // A NULL output pointer is allowed (used when only validity matters).
    {
        floe_epoch_status got = floe_epoch_parse("floe.epoch=7", 12, NULL);
        CHECK(got == FLOE_EPOCH_OK);
    }
}

static void test_parse_rejects(void) {
    // Missing key entirely, or only a near miss.
    expect_status("plain cmdline", "console=hvc0 root=/dev/vda rw init=/sbin/init",
                  FLOE_EPOCH_MISSING);
    expect_status("empty string", "", FLOE_EPOCH_MISSING);
    expect_status("only whitespace", " \t\r\n", FLOE_EPOCH_MISSING);
    expect_status("key without value separator", "floe.epoch", FLOE_EPOCH_MISSING);
    expect_status("key embedded in another field", "foo=floe.epoch=1700000000",
                  FLOE_EPOCH_MISSING);
    expect_status("prefixed key", "xfloe.epoch=1700000000", FLOE_EPOCH_MISSING);
    expect_status("key inside another value", "rdinit=floe.epoch=1700000000",
                  FLOE_EPOCH_MISSING);

    // Empty value.
    expect_status("empty value", "floe.epoch=", FLOE_EPOCH_EMPTY);
    expect_status("empty value then whitespace", "floe.epoch= \n",
                  FLOE_EPOCH_EMPTY);

    // Sign / non-digit / non-canonical.
    expect_status("negative value", "floe.epoch=-1700000000",
                  FLOE_EPOCH_INVALID);
    expect_status("negative zero", "floe.epoch=-0", FLOE_EPOCH_INVALID);
    expect_status("explicit plus", "floe.epoch=+1700000000",
                  FLOE_EPOCH_INVALID);
    expect_status("leading zeros", "floe.epoch=01700000000",
                  FLOE_EPOCH_INVALID);
    expect_status("trailing letter", "floe.epoch=1700000000x",
                  FLOE_EPOCH_INVALID);
    expect_status("embedded letter", "floe.epoch=17a", FLOE_EPOCH_INVALID);
    expect_status("decimal point", "floe.epoch=1.5", FLOE_EPOCH_INVALID);

    // Range and overflow (must never wrap around).
    expect_status("above upper bound", "floe.epoch=253402300800",
                  FLOE_EPOCH_RANGE);
    expect_status("long digit string",
                  "floe.epoch=99999999999999999999", FLOE_EPOCH_RANGE);
    expect_status(
        "100-digit digit string",
        "floe.epoch=999999999999999999999999999999999999999999999999999999999"
        "9999999999999999999999999999999999999999",
        FLOE_EPOCH_RANGE);

    // Duplicate keys are ambiguous: neither value may be used.
    expect_status("duplicate same value",
                  "floe.epoch=1700000000 floe.epoch=1700000000",
                  FLOE_EPOCH_DUPLICATE);
    expect_status("duplicate different values",
                  "floe.epoch=1700000000\tfloe.epoch=1700000001",
                  FLOE_EPOCH_DUPLICATE);
    expect_status("valid then invalid",
                  "floe.epoch=1700000000 floe.epoch=bogus",
                  FLOE_EPOCH_DUPLICATE);
    expect_status("invalid then valid",
                  "floe.epoch=-1\nfloe.epoch=1700000000", FLOE_EPOCH_DUPLICATE);
    expect_status("duplicate empty and valid",
                  "floe.epoch= floe.epoch=1700000000", FLOE_EPOCH_DUPLICATE);

    // Robustness: no buffer at all.
    expect_status("NULL buffer", NULL, FLOE_EPOCH_MISSING);
}

static void test_status_text(void) {
    const floe_epoch_status all[] = {
        FLOE_EPOCH_OK,      FLOE_EPOCH_MISSING, FLOE_EPOCH_EMPTY,
        FLOE_EPOCH_INVALID, FLOE_EPOCH_RANGE,   FLOE_EPOCH_DUPLICATE,
    };
    for (size_t i = 0; i < sizeof all / sizeof all[0]; i++) {
        const char *text = floe_epoch_status_text(all[i]);
        CHECK(text != NULL);
        CHECK(text[0] != '\0');
        for (size_t j = i + 1; j < sizeof all / sizeof all[0]; j++) {
            CHECK(strcmp(text, floe_epoch_status_text(all[j])) != 0);
        }
    }
}

// ---------------------------------------------------------------------------
// Bounded reader checks
// ---------------------------------------------------------------------------

static int write_temp_file(char *path, const char *data, size_t len) {
    int fd = mkstemp(path);
    if (fd < 0) return -1;
    size_t off = 0;
    while (off < len) {
        ssize_t n = write(fd, data + off, len - off);
        if (n < 0) {
            if (errno == EINTR) continue;
            close(fd);
            unlink(path);
            return -1;
        }
        off += (size_t)n;
    }
    if (close(fd) != 0) {
        unlink(path);
        return -1;
    }
    return 0;
}

static void test_reader_small_file(void) {
    static const char line[] = "console=hvc0 floe.epoch=1700000000\n";
    char path[] = "/tmp/floe-clock-check.XXXXXX";
    char buf[FLOE_EPOCH_CMDLINE_MAX];
    size_t len = 0;
    int truncated = -1;

    CHECK(write_temp_file(path, line, sizeof line - 1) == 0);
    CHECK(floe_cmdline_read_bounded(path, buf, sizeof buf, &len, &truncated) == 0);
    CHECK(len == sizeof line - 1);
    CHECK(truncated == 0);
    CHECK(buf[len] == '\0');
    {
        int64_t epoch = 0;
        floe_epoch_status got = floe_epoch_parse(buf, len, &epoch);
        CHECK(got == FLOE_EPOCH_OK);
        CHECK(epoch == 1700000000);
    }
    unlink(path);
}

static void test_reader_exact_fit(void) {
    char path[] = "/tmp/floe-clock-check.XXXXXX";
    size_t cap = 64;
    char data[64];
    char buf[64];
    size_t len = 0;
    int truncated = -1;
    memset(data, 'a', sizeof data);

    CHECK(write_temp_file(path, data, cap - 1) == 0);
    CHECK(floe_cmdline_read_bounded(path, buf, cap, &len, &truncated) == 0);
    CHECK(len == cap - 1);
    CHECK(truncated == 0);
    unlink(path);
}

static void test_reader_truncates(void) {
    char path[] = "/tmp/floe-clock-check.XXXXXX";
    size_t big_len = 10 * 1024;
    char *big = malloc(big_len);
    char buf[FLOE_EPOCH_CMDLINE_MAX];
    size_t len = 0;
    int truncated = -1;

    CHECK(big != NULL);
    if (big) {
        // Put a would-be key only in the tail beyond the bound: a truncated
        // read must never let the caller believe it parsed the whole line.
        memset(big, 'x', big_len);
        memcpy(big + big_len - 16, "floe.epoch=12345", 16);
        CHECK(write_temp_file(path, big, big_len) == 0);
        CHECK(floe_cmdline_read_bounded(path, buf, sizeof buf, &len, &truncated) == 0);
        CHECK(len == sizeof buf - 1);
        CHECK(truncated == 1);
        CHECK(buf[len] == '\0');
        {
            int64_t epoch = 0;
            floe_epoch_status got = floe_epoch_parse(buf, len, &epoch);
            CHECK(got == FLOE_EPOCH_MISSING);
        }
        unlink(path);
        free(big);
    }
}

static void test_reader_failures(void) {
    char buf[64];
    size_t len = 0;
    int truncated = -1;

    errno = 0;
    CHECK(floe_cmdline_read_bounded("/tmp/floe-clock-check-does-not-exist",
                                    buf, sizeof buf, &len, &truncated) == -1);
    CHECK(errno == ENOENT);
    CHECK(len == 0);
    CHECK(truncated == 0);

    errno = 0;
    CHECK(floe_cmdline_read_bounded("/proc/cmdline", buf, 0, &len, &truncated) == -1);
    CHECK(errno == EINVAL);
}

int main(void) {
    test_parse_accepts();
    test_parse_rejects();
    test_status_text();
    test_reader_small_file();
    test_reader_exact_fit();
    test_reader_truncates();
    test_reader_failures();

    printf("clock_arg_check: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
