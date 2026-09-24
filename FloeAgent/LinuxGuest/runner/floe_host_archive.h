/* floe_host_archive.h — guest side of the optional floe-host archive bridge.
 *
 * The Floe archive engine lives on the host. A Linux guest that has no
 * archive tooling (or whose packages must not be replaced) can delegate
 * create/extract/list/decompress work to the host instead:
 *
 *   HELLO:   host → guest  \x1eFLOE-HELLO <token> archive=create,extract,list,decompress\x1e
 *   CAPS:    guest → host  \x1eFLOE-CAPS <token> … hostArchive=create,extract,list,decompress\x1e
 *   request: guest → host  \x1eFLOE-HOSTREQ <token> <base64 control payload>\x1e
 *   reply:   host → guest  \x1eFLOE-HOSTREPLY <token> <base64 small reply>\x1e
 *
 * Only small control messages cross the channel. Paths name shared-directory
 * entries; the file bytes stay in the 9p share, and `list` writes its listing
 * into the share and returns the path.
 *
 * This header is pure (no I/O, no allocation) so it can be checked natively
 * for the host build and by `host_archive_check.c`, and inlined into the
 * static riscv64 runner.
 *
 * SPDX-License-Identifier: MPL-2.0
 */
#ifndef FLOE_HOST_ARCHIVE_H
#define FLOE_HOST_ARCHIVE_H

#include <stddef.h>
#include <stdio.h>
#include <string.h>

#define FLOE_HOST_TOKEN_MAX 64
#define FLOE_HOST_ACTION_MAX 16
#define FLOE_HOST_FORMAT_MAX 16
#define FLOE_HOST_PATH_MAX 512
#define FLOE_HOST_PAYLOAD_MAX 2048
#define FLOE_HOST_CAPS_MAX 64
#define FLOE_HOST_REPLY_MAX 2048

typedef struct {
    char value[FLOE_HOST_CAPS_MAX]; /* canonical "create,extract,…" or "" */
} floe_host_caps;

typedef struct {
    char action[FLOE_HOST_ACTION_MAX];
    char format[FLOE_HOST_FORMAT_MAX];
    char source[FLOE_HOST_PATH_MAX];
    char destination[FLOE_HOST_PATH_MAX];
} floe_host_request;

typedef struct {
    int ok;          /* 1 status=ok, 0 status=error */
    int exit_code;   /* 0 on ok, 125 on a host-side failure */
    char code[48];   /* error code when !ok */
} floe_host_reply;

/* ------------------------------------------------------------------ caps */

static inline int floe_host_action_known(const char *action) {
    return action &&
           (strcmp(action, "create") == 0 || strcmp(action, "extract") == 0 ||
            strcmp(action, "list") == 0 || strcmp(action, "decompress") == 0);
}

/* Parses a host capability list. Accepts "archive=create,extract" (all known
 * actions when the value is exactly "archive") or "archive". Unknown entries
 * are ignored; an absent key leaves the set empty (bridge unavailable). */
static inline int floe_host_caps_parse(const char *args, size_t len, floe_host_caps *out) {
    if (!out) return -1;
    out->value[0] = '\0';
    if (!args) return 0;
    const char *end = args + len;
    const char *cursor = args;
    while (cursor < end) {
        while (cursor < end && (*cursor == ' ' || *cursor == '\t')) cursor++;
        const char *field = cursor;
        while (cursor < end && *cursor != ' ' && *cursor != '\t') cursor++;
        const char *equals = NULL;
        for (const char *p = field; p < cursor; p++) {
            if (*p == '=') { equals = p; break; }
        }
        if (!equals) continue;
        size_t key_len = (size_t)(equals - field);
        if (key_len != 7 || strncmp(field, "archive", 7) != 0) continue;
        const char *value = equals + 1;
        size_t value_len = (size_t)(cursor - value);
        char buffer[FLOE_HOST_CAPS_MAX];
        if (value_len >= sizeof buffer) value_len = sizeof buffer - 1;
        memcpy(buffer, value, value_len);
        buffer[value_len] = '\0';
        if (strcmp(buffer, "archive") == 0) {
            snprintf(out->value, sizeof out->value, "create,extract,list,decompress");
            return 0;
        }
        /* Keep only known actions, canonical order. */
        floe_host_caps parsed;
        parsed.value[0] = '\0';
        static const char *order[] = {"create", "extract", "list", "decompress"};
        for (size_t i = 0; i < 4; i++) {
            const char *needle = order[i];
            const char *scan = buffer;
            while ((scan = strstr(scan, needle)) != NULL) {
                int boundary_before = (scan == buffer) || (scan[-1] == ',');
                char after = scan[strlen(needle)];
                int boundary_after = (after == '\0' || after == ',');
                if (boundary_before && boundary_after) {
                    size_t used = strlen(parsed.value);
                    snprintf(parsed.value + used, sizeof parsed.value - used, "%s%s",
                             used ? "," : "", needle);
                    break;
                }
                scan += strlen(needle);
            }
        }
        snprintf(out->value, sizeof out->value, "%s", parsed.value);
        return 0;
    }
    return 0;
}

static inline int floe_host_caps_allows(const floe_host_caps *caps, const char *action) {
    if (!caps || !action || caps->value[0] == '\0') return 0;
    const char *scan = caps->value;
    size_t action_len = strlen(action);
    while ((scan = strstr(scan, action)) != NULL) {
        int boundary_before = (scan == caps->value) || (scan[-1] == ',');
        char after = scan[action_len];
        int boundary_after = (after == '\0' || after == ',');
        if (boundary_before && boundary_after) return 1;
        scan += action_len;
    }
    return 0;
}

/* ----------------------------------------------------------------- parse */

static inline int floe_host_path_valid(const char *path) {
    if (!path || path[0] == '\0') return 0;
    if (path[0] == '~') return 0;
    size_t len = strlen(path);
    if (len >= FLOE_HOST_PATH_MAX) return 0;
    for (size_t i = 0; i < len; i++) {
        unsigned char c = (unsigned char)path[i];
        if (c < 0x20 || c == 0x7f || c == '\\') return 0;
    }
    /* Reject any ".." path component. */
    const char *scan = path;
    while (*scan) {
        if (scan[0] == '.' && scan[1] == '.' &&
            (scan == path || scan[-1] == '/') &&
            (scan[2] == '\0' || scan[2] == '/')) {
            return 0;
        }
        scan++;
    }
    return 1;
}

static inline int floe_host_format_known(const char *format) {
    static const char *known[] = {"zip", "tar", "tgz", "tbz2", "txz", "gz", "bz2", "xz", "7z", "rar"};
    if (!format) return 0;
    for (size_t i = 0; i < sizeof known / sizeof known[0]; i++) {
        if (strcmp(format, known[i]) == 0) return 1;
    }
    return 0;
}

/* Infers a format from a file name, mirroring the host tool's rules.
 * Returns 0 when nothing matched. */
static inline int floe_host_format_infer(const char *path, char *out, size_t cap) {
    if (!path || !out || cap == 0) return -1;
    size_t len = strlen(path);
    struct { const char *suffix; const char *format; } table[] = {
        {".tar.gz", "tgz"}, {".tgz", "tgz"}, {".tar.bz2", "tbz2"}, {".tbz2", "tbz2"},
        {".tar.xz", "txz"}, {".txz", "txz"}, {".zip", "zip"}, {".tar", "tar"},
        {".gz", "gz"}, {".bz2", "bz2"}, {".xz", "xz"}, {".7z", "7z"}, {".rar", "rar"}
    };
    for (size_t i = 0; i < sizeof table / sizeof table[0]; i++) {
        size_t suffix_len = strlen(table[i].suffix);
        if (len > suffix_len) {
            const char *tail = path + (len - suffix_len);
            int match = 1;
            for (size_t j = 0; j < suffix_len; j++) {
                char a = tail[j];
                char b = table[i].suffix[j];
                if (a >= 'A' && a <= 'Z') a = (char)(a - 'A' + 'a');
                if (b >= 'A' && b <= 'Z') b = (char)(b - 'A' + 'a');
                if (a != b) { match = 0; break; }
            }
            if (match) {
                snprintf(out, cap, "%s", table[i].format);
                return 0;
            }
        }
    }
    return -1;
}

/* Parses `floe-host archive …` argv (argv[0] is "floe-host"). Accepts flags
 * in any order plus one positional source when --source is absent. */
static inline int floe_host_request_parse(int argc, char **argv, floe_host_request *out) {
    if (!out) return -1;
    memset(out, 0, sizeof *out);
    if (argc < 3 || !argv) return -2;
    if (strcmp(argv[1], "archive") != 0) return -2;
    if (!floe_host_action_known(argv[2])) return -3;
    snprintf(out->action, sizeof out->action, "%s", argv[2]);
    const char *format = NULL;
    const char *source = NULL;
    const char *destination = NULL;
    for (int i = 3; i < argc; i++) {
        const char *arg = argv[i];
        if (strcmp(arg, "--format") == 0 || strcmp(arg, "-f") == 0) {
            if (++i >= argc) return -4;
            format = argv[i];
        } else if (strcmp(arg, "--source") == 0 || strcmp(arg, "-s") == 0) {
            if (++i >= argc) return -4;
            source = argv[i];
        } else if (strcmp(arg, "--destination") == 0 || strcmp(arg, "-d") == 0) {
            if (++i >= argc) return -4;
            destination = argv[i];
        } else if (arg[0] == '-') {
            return -4;
        } else if (!source) {
            source = arg;
        } else if (!destination) {
            destination = arg;
        } else {
            return -4;
        }
    }
    if (!source) return -5;
    if (!floe_host_path_valid(source)) return -6;
    /* create names its output format on the destination; every other action
     * reads the format from the source it opens. */
    const char *infer_from = strcmp(out->action, "create") == 0 ? (destination ? destination : source) : source;
    if (!format) {
        if (floe_host_format_infer(infer_from, out->format, sizeof out->format) != 0) return -7;
    } else {
        if (!floe_host_format_known(format)) return -7;
        snprintf(out->format, sizeof out->format, "%s", format);
    }
    snprintf(out->source, sizeof out->source, "%s", source);
    if (strcmp(out->action, "list") == 0) {
        return destination ? -4 : 0;
    }
    if (!destination) return -5;
    if (!floe_host_path_valid(destination)) return -6;
    snprintf(out->destination, sizeof out->destination, "%s", destination);
    return 0;
}

/* --------------------------------------------------------------- payload */

static inline int floe_host_hex(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

/* Percent-encodes into `out` (bounded); separators, spaces and non-ASCII stay
 * inside the encoded field so the payload is one small line. */
static inline int floe_host_encode_field(const char *value, char *out, size_t cap) {
    static const char hex[] = "0123456789ABCDEF";
    size_t used = 0;
    for (const unsigned char *p = (const unsigned char *)value; *p; p++) {
        unsigned char c = *p;
        int safe = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') ||
                   c == '-' || c == '.' || c == '_' || c == '/' || c == '~';
        if (safe) {
            if (used + 1 >= cap) return -1;
            out[used++] = (char)c;
        } else {
            if (used + 3 >= cap) return -1;
            out[used++] = '%';
            out[used++] = hex[c >> 4];
            out[used++] = hex[c & 0x0f];
        }
    }
    if (used >= cap) return -1;
    out[used] = '\0';
    return 0;
}

static inline int floe_host_request_encode(const floe_host_request *req, const char *token,
                                           char *out, size_t cap) {
    if (!req || !token || !out || cap == 0) return -1;
    if (!floe_host_action_known(req->action) || !floe_host_format_known(req->format)) return -1;
    if (!floe_host_path_valid(req->source)) return -1;
    if (strcmp(req->action, "list") != 0 && !floe_host_path_valid(req->destination)) return -1;
    char encoded_source[FLOE_HOST_PATH_MAX * 3];
    char encoded_destination[FLOE_HOST_PATH_MAX * 3];
    char encoded_token[FLOE_HOST_TOKEN_MAX * 3];
    if (floe_host_encode_field(req->source, encoded_source, sizeof encoded_source) != 0) return -1;
    if (floe_host_encode_field(token, encoded_token, sizeof encoded_token) != 0) return -1;
    int written;
    if (strcmp(req->action, "list") == 0) {
        written = snprintf(out, cap, "v1 token=%s action=%s format=%s source=%s",
                           encoded_token, req->action, req->format, encoded_source);
    } else {
        if (floe_host_encode_field(req->destination, encoded_destination, sizeof encoded_destination) != 0) return -1;
        written = snprintf(out, cap, "v1 token=%s action=%s format=%s source=%s destination=%s",
                           encoded_token, req->action, req->format, encoded_source, encoded_destination);
    }
    if (written <= 0 || (size_t)written >= cap || (size_t)written > FLOE_HOST_PAYLOAD_MAX) return -1;
    return written;
}

/* Base64 (standard alphabet, padded) for the small control payload. */
static inline int floe_host_b64_encode(const unsigned char *in, size_t len, char *out, size_t cap) {
    static const char alphabet[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    size_t needed = ((len + 2) / 3) * 4;
    if (!in || !out || cap == 0 || needed + 1 > cap) return -1;
    size_t written = 0;
    for (size_t i = 0; i < len; i += 3) {
        unsigned int chunk = (unsigned int)in[i] << 16;
        if (i + 1 < len) chunk |= (unsigned int)in[i + 1] << 8;
        if (i + 2 < len) chunk |= (unsigned int)in[i + 2];
        out[written++] = alphabet[(chunk >> 18) & 0x3f];
        out[written++] = alphabet[(chunk >> 12) & 0x3f];
        out[written++] = (i + 1 < len) ? alphabet[(chunk >> 6) & 0x3f] : '=';
        out[written++] = (i + 2 < len) ? alphabet[chunk & 0x3f] : '=';
    }
    out[written] = '\0';
    return (int)written;
}

/* Parses the host's small reply line. */
static inline int floe_host_reply_parse(const char *reply, floe_host_reply *out) {
    if (!reply || !out) return -1;
    memset(out, 0, sizeof *out);
    out->exit_code = 125;
    if (strncmp(reply, "status=ok", 9) == 0) {
        out->ok = 1;
        out->exit_code = 0;
    } else if (strncmp(reply, "status=error", 12) == 0) {
        out->ok = 0;
    } else {
        return -1;
    }
    const char *code = strstr(reply, "code=");
    if (code) {
        code += 5;
        size_t i = 0;
        while (code[i] && code[i] != ' ' && i + 1 < sizeof out->code) {
            out->code[i] = code[i];
            i++;
        }
        out->code[i] = '\0';
    }
    return 0;
}

/* Human-readable text the guest command prints for a reply. */
static inline int floe_host_reply_text(const char *reply, char *out, size_t cap) {
    if (!reply || !out || cap == 0) return -1;
    floe_host_reply parsed;
    if (floe_host_reply_parse(reply, &parsed) != 0) return -1;
    if (parsed.ok) {
        return snprintf(out, cap, "archive ok: %s\n", reply);
    }
    return snprintf(out, cap, "archive failed (%s): %s\n",
                    parsed.code[0] ? parsed.code : "error", reply);
}

#endif /* FLOE_HOST_ARCHIVE_H */
