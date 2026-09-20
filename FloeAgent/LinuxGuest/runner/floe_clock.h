// floe_clock.h — Floe Linux guest boot wall clock (`floe.epoch=`) parsing.
//
// The pinned TinyEMU guest kernel has no usable RTC (CONFIG_RTC_CLASS is not
// enabled), so without help the guest starts at the image build date and
// HTTPS/apt signature checks fail. The host always appends exactly one
// parameter to the kernel command line:
//
//     floe.epoch=<unix seconds>
//
// (host side: LinuxGuestBootArguments.commandLine). This header owns the
// bounded /proc/cmdline reader and the strict, side-effect-free parser for
// that single parameter. Applying the value to CLOCK_REALTIME is deliberately
// NOT here: floe_exec.c does that, on Linux only and only when the process is
// PID 1, so the native host build and host-side checks can never change the
// developer machine's clock. The parser performs no I/O, no allocation and
// never runs a shell; it accepts no parameter other than floe.epoch=.
//
// Contract (host and guest must agree):
//   - exactly one `floe.epoch=` token, anchored at a token boundary
//     (buffer start or after whitespace/NUL), so `foo=floe.epoch=1` and
//     `xfloe.epoch=1` do not match;
//   - value is `[0-9]+` in canonical form: no sign (`-`/`+`), no leading
//     zeros unless the value is exactly "0", no trailing characters;
//   - value <= FLOE_EPOCH_MAX_SECONDS (9999-12-31T23:59:59Z);
//   - a second occurrence makes the whole line ambiguous and is rejected
//     (neither value is used);
//   - missing/empty/invalid/out-of-range/duplicated all mean "clock not
//     set": the caller must say so and must not claim a synchronized clock.

#ifndef FLOE_CLOCK_H
#define FLOE_CLOCK_H

#include <errno.h>
#include <fcntl.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>

// Bound on the bytes read from /proc/cmdline. The kernel caps a real command
// line well below this; a longer file is truncated and reported, never
// buffered without limit.
#ifndef FLOE_EPOCH_CMDLINE_MAX
#define FLOE_EPOCH_CMDLINE_MAX 4096
#endif

// Inclusive upper bound on an accepted epoch: 9999-12-31T23:59:59Z. Later
// values are nonsense for a device clock and are rejected, not wrapped.
#define FLOE_EPOCH_MAX_SECONDS ((int64_t)253402300799LL)

typedef enum {
    FLOE_EPOCH_OK = 0,
    FLOE_EPOCH_MISSING,   // no floe.epoch= token at all
    FLOE_EPOCH_EMPTY,     // floe.epoch= with no digits
    FLOE_EPOCH_INVALID,   // sign, leading zero, non-digit or trailing junk
    FLOE_EPOCH_RANGE,     // above FLOE_EPOCH_MAX_SECONDS (never wraps)
    FLOE_EPOCH_DUPLICATE  // more than one floe.epoch= token: ambiguous
} floe_epoch_status;

static inline const char *floe_epoch_status_text(floe_epoch_status status) {
    switch (status) {
    case FLOE_EPOCH_OK: return "ok";
    case FLOE_EPOCH_MISSING: return "missing";
    case FLOE_EPOCH_EMPTY: return "empty";
    case FLOE_EPOCH_INVALID: return "invalid";
    case FLOE_EPOCH_RANGE: return "out of range";
    case FLOE_EPOCH_DUPLICATE: return "duplicated";
    }
    return "unknown";
}

// Kernel command line fields are separated by whitespace; a NUL byte ends the
// field as well (the buffer is a NUL-terminated C string in practice).
static inline int floe_epoch_is_space(unsigned char c) {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r' ||
           c == '\v' || c == '\f' || c == '\0';
}

// floe_epoch_parse — find and validate the single `floe.epoch=<digits>` token
// in a bounded command-line buffer.
//
// On FLOE_EPOCH_OK writes the value to *out_epoch (0 otherwise). *out_epoch
// may be NULL. The function reads `len` bytes and never trusts a NUL terminator
// inside them beyond treating it as a field separator.
static inline floe_epoch_status floe_epoch_parse(const char *cmdline, size_t len,
                                                 int64_t *out_epoch) {
    static const char key[] = "floe.epoch=";
    const size_t key_len = sizeof key - 1;
    size_t occurrences = 0;
    floe_epoch_status first = FLOE_EPOCH_MISSING;
    uint64_t first_value = 0;

    if (out_epoch) *out_epoch = 0;
    if (!cmdline) return FLOE_EPOCH_MISSING;

    size_t i = 0;
    while (i < len) {
        while (i < len && floe_epoch_is_space((unsigned char)cmdline[i])) i++;
        size_t start = i;
        while (i < len && !floe_epoch_is_space((unsigned char)cmdline[i])) i++;
        size_t token_len = i - start;
        if (token_len < key_len) continue;
        if (memcmp(cmdline + start, key, key_len) != 0) continue;

        occurrences++;
        const char *digits = cmdline + start + key_len;
        size_t digits_len = token_len - key_len;
        floe_epoch_status status = FLOE_EPOCH_OK;
        uint64_t value = 0;
        if (digits_len == 0) {
            status = FLOE_EPOCH_EMPTY;
        } else if (digits[0] == '0' && digits_len > 1) {
            status = FLOE_EPOCH_INVALID; // non-canonical leading zeros
        } else {
            for (size_t k = 0; k < digits_len; k++) {
                unsigned char c = (unsigned char)digits[k];
                if (c < '0' || c > '9') {
                    status = FLOE_EPOCH_INVALID;
                    break;
                }
                // Pre-check before multiplying so no digit sequence can wrap
                // uint64_t; the final check enforces the exact bound.
                if (value > (uint64_t)FLOE_EPOCH_MAX_SECONDS / 10) {
                    status = FLOE_EPOCH_RANGE;
                    break;
                }
                value = value * 10 + (uint64_t)(c - '0');
                if (value > (uint64_t)FLOE_EPOCH_MAX_SECONDS) {
                    status = FLOE_EPOCH_RANGE;
                    break;
                }
            }
        }
        if (occurrences == 1) {
            first = status;
            first_value = value;
        }
    }

    if (occurrences == 0) {
        if (out_epoch) *out_epoch = 0;
        return FLOE_EPOCH_MISSING;
    }
    if (occurrences > 1) {
        if (out_epoch) *out_epoch = 0;
        return FLOE_EPOCH_DUPLICATE;
    }
    if (first != FLOE_EPOCH_OK) {
        if (out_epoch) *out_epoch = 0;
        return first;
    }
    if (out_epoch) *out_epoch = (int64_t)first_value;
    return FLOE_EPOCH_OK;
}

// floe_cmdline_read_bounded — read at most cap-1 bytes of `path` into `buf`
// (always NUL-terminated) so a pathological or stale command line can never
// make the runner allocate or block on an unbounded buffer.
//
// *out_truncated is set when more bytes existed than were stored: the caller
// must treat that as "possibly incomplete" and must not claim a successful
// parse of a parameter that may sit in the dropped tail. Returns 0 on success,
// -1 on failure (errno set).
static inline int floe_cmdline_read_bounded(const char *path, char *buf, size_t cap,
                                            size_t *out_len, int *out_truncated) {
    size_t len = 0;
    int truncated = 0;
    if (out_len) *out_len = 0;
    if (out_truncated) *out_truncated = 0;
    if (!path || !buf || cap == 0) {
        errno = EINVAL;
        return -1;
    }
    int fd = open(path, O_RDONLY);
    if (fd < 0) return -1;
    for (;;) {
        if (len == cap - 1) {
            char probe;
            ssize_t n = read(fd, &probe, 1);
            if (n > 0) {
                truncated = 1;
                break;
            }
            if (n < 0) {
                if (errno == EINTR) continue;
                int saved = errno;
                close(fd);
                errno = saved;
                return -1;
            }
            break;
        }
        ssize_t n = read(fd, buf + len, cap - 1 - len);
        if (n < 0) {
            if (errno == EINTR) continue;
            int saved = errno;
            close(fd);
            errno = saved;
            return -1;
        }
        if (n == 0) break;
        len += (size_t)n;
    }
    close(fd);
    buf[len] = '\0';
    if (out_len) *out_len = len;
    if (out_truncated) *out_truncated = truncated;
    return 0;
}

#endif // FLOE_CLOCK_H
