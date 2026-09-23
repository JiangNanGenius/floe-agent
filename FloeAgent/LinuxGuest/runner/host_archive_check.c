/* host_archive_check.c — native, network-free check for the guest side of the
 * optional floe-host archive bridge (floe_host_archive.h).
 *
 * Runs on the developer host / CI:
 *   make -C FloeAgent/LinuxGuest/runner check-host-archive
 *
 * It covers capability negotiation, argv parsing, format inference, path
 * validation and payload encoding; the wire round trip with the real host is
 * part of the image/protocol qualification, not this check.
 *
 * SPDX-License-Identifier: MPL-2.0
 */
#include <assert.h>
#include <stdio.h>
#include <string.h>

#include "floe_host_archive.h"

static int failures = 0;

#define CHECK(cond, message)                                                              \
    do {                                                                                  \
        if (!(cond)) {                                                                    \
            fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, message);             \
            failures++;                                                                   \
        }                                                                                 \
    } while (0)

static void check_caps(void) {
    floe_host_caps caps;
    const char *all_caps = "archive=create,extract,list,decompress";
    floe_host_caps_parse(all_caps, strlen(all_caps), &caps);
    CHECK(strcmp(caps.value, "create,extract,list,decompress") == 0, "all actions parsed");
    CHECK(floe_host_caps_allows(&caps, "create"), "create allowed");
    CHECK(floe_host_caps_allows(&caps, "decompress"), "decompress allowed");

    const char *subset = "runner=abc protocol=2 archive=extract,list";
    floe_host_caps_parse(subset, strlen(subset), &caps);
    CHECK(strcmp(caps.value, "extract,list") == 0, "subset parsed in canonical order");
    CHECK(floe_host_caps_allows(&caps, "extract"), "extract allowed");
    CHECK(!floe_host_caps_allows(&caps, "create"), "unadvertised action refused");
    CHECK(!floe_host_caps_allows(&caps, "decompress"), "missing action refused");

    const char *none = "runner=abc protocol=2";
    floe_host_caps_parse(none, strlen(none), &caps);
    CHECK(caps.value[0] == '\0', "no capability advert -> empty set");
    CHECK(!floe_host_caps_allows(&caps, "list"), "empty set refuses everything");

    const char *shorthand = "archive=archive";
    floe_host_caps_parse(shorthand, strlen(shorthand), &caps);
    CHECK(strcmp(caps.value, "create,extract,list,decompress") == 0, "archive shorthand = all");
}

static void check_parse(void) {
    floe_host_request req;
    char *create[] = {"floe-host", "archive", "create", "--format", "zip",
                      "--source", "/workspace/notes", "--destination", "/workspace/notes.zip"};
    CHECK(floe_host_request_parse(9, create, &req) == 0, "create parsed");
    CHECK(strcmp(req.action, "create") == 0, "create action");
    CHECK(strcmp(req.format, "zip") == 0, "create format");
    CHECK(strcmp(req.source, "/workspace/notes") == 0, "create source");
    CHECK(strcmp(req.destination, "/workspace/notes.zip") == 0, "create destination");

    char *infer[] = {"floe-host", "archive", "list", "/workspace/logs.tar.gz"};
    CHECK(floe_host_request_parse(4, infer, &req) == 0, "list parsed");
    CHECK(strcmp(req.format, "tgz") == 0, "tar.gz inferred for list");
    CHECK(req.destination[0] == '\0', "list has no destination");

    char *positional[] = {"floe-host", "archive", "decompress", "notes.txt.gz", "notes.txt"};
    CHECK(floe_host_request_parse(5, positional, &req) == 0, "positional parsed");
    CHECK(strcmp(req.format, "gz") == 0, "gz inferred");
    CHECK(strcmp(req.destination, "notes.txt") == 0, "positional destination");

    char *traversal[] = {"floe-host", "archive", "extract", "--source", "../escape.tar"};
    CHECK(floe_host_request_parse(5, traversal, &req) == -6, "../ source refused");
    char *traversal2[] = {"floe-host", "archive", "create", "--source", "/workspace/a",
                          "--destination", "/workspace/../outside.zip"};
    CHECK(floe_host_request_parse(7, traversal2, &req) == -6, "../ destination refused");
    char *control[] = {"floe-host", "archive", "list", "/workspace/bad\n.tar"};
    CHECK(floe_host_request_parse(4, control, &req) == -6, "control character refused");
    char *unknown_action[] = {"floe-host", "archive", "delete", "/workspace/a.zip"};
    CHECK(floe_host_request_parse(4, unknown_action, &req) == -3, "unknown action refused");
    char *unknown_format[] = {"floe-host", "archive", "create", "--format", "lz4",
                              "--source", "/workspace/a", "--destination", "/workspace/a.lz4"};
    CHECK(floe_host_request_parse(9, unknown_format, &req) == -7, "unknown format refused");
    char *list_with_dest[] = {"floe-host", "archive", "list", "--source", "/workspace/a.tar",
                              "--destination", "/workspace/x"};
    CHECK(floe_host_request_parse(7, list_with_dest, &req) == -4, "list refuses a destination");
    char *missing_source[] = {"floe-host", "archive", "create", "--format", "zip"};
    CHECK(floe_host_request_parse(5, missing_source, &req) == -5, "missing source refused");
    char *bad_flag[] = {"floe-host", "archive", "list", "--verbose", "/workspace/a.tar"};
    CHECK(floe_host_request_parse(5, bad_flag, &req) == -4, "unknown flag refused");
    char *not_archive[] = {"floe-host", "other", "list"};
    CHECK(floe_host_request_parse(3, not_archive, &req) == -2, "non-archive subcommand refused");
}

static void check_encode(void) {
    floe_host_request req;
    char payload[FLOE_HOST_PAYLOAD_MAX];
    char *argv[] = {"floe-host", "archive", "create", "--format", "tgz",
                    "--source", "/workspace/中文 目录", "--destination", "/workspace/包.tar.gz"};
    CHECK(floe_host_request_parse(9, argv, &req) == 0, "unicode create parsed");
    int written = floe_host_request_encode(&req, "tok-1", payload, sizeof payload);
    CHECK(written > 0, "payload encoded");
    CHECK(strstr(payload, "v1 token=tok-1") == payload, "payload starts with v1+token");
    CHECK(strstr(payload, "action=create") != NULL, "payload carries the action");
    CHECK(strstr(payload, "format=tgz") != NULL, "payload carries the format");
    CHECK(strchr(payload, '\n') == NULL && strchr(payload, '\t') == NULL, "payload is a single line");
    CHECK(strstr(payload, " ") != NULL, "payload is space separated");
    CHECK((size_t)written <= FLOE_HOST_PAYLOAD_MAX, "payload respects the cap");

    floe_host_request list;
    char *list_argv[] = {"floe-host", "archive", "list", "/workspace/a.tar.xz"};
    CHECK(floe_host_request_parse(4, list_argv, &list) == 0, "list parsed for encoding");
    CHECK(floe_host_request_encode(&list, "tok-2", payload, sizeof payload) > 0, "list payload encoded");
    CHECK(strstr(payload, "destination=") == NULL, "list payload omits the destination");

    char small[16];
    CHECK(floe_host_request_encode(&list, "tok-2", small, sizeof small) == -1, "tiny buffer refused");
    CHECK(floe_host_request_encode(NULL, "tok-2", payload, sizeof payload) == -1, "null request refused");
}

static void check_base64(void) {
    char encoded[64];
    const unsigned char payload[] = "v1 token=t action=list";
    int written = floe_host_b64_encode(payload, sizeof payload - 1, encoded, sizeof encoded);
    CHECK(written > 0, "base64 encoded");
    CHECK(strcmp(encoded, "djEgdG9rZW49dCBhY3Rpb249bGlzdA==") == 0, "base64 matches the reference vector");
    CHECK(floe_host_b64_encode(payload, sizeof payload - 1, encoded, 8) == -1, "tiny base64 buffer refused");

    char encoded2[8];
    CHECK(floe_host_b64_encode((const unsigned char *)"a", 1, encoded2, sizeof encoded2) == 4, "one byte encodes");
    CHECK(strcmp(encoded2, "YQ==") == 0, "one byte padding");
}

static void check_reply(void) {
    floe_host_reply reply;
    CHECK(floe_host_reply_parse("status=ok action=create format=zip entries=3 bytes=1024 path=/workspace/a.zip",
                                &reply) == 0, "ok reply parsed");
    CHECK(reply.ok == 1 && reply.exit_code == 0, "ok reply exit code");

    CHECK(floe_host_reply_parse("status=error code=path-outside-share detail=/etc/passwd", &reply) == 0,
          "error reply parsed");
    CHECK(reply.ok == 0 && reply.exit_code == 125, "error reply exit code");
    CHECK(strcmp(reply.code, "path-outside-share") == 0, "error code parsed");

    CHECK(floe_host_reply_parse("garbage", &reply) == -1, "garbage reply rejected");

    char text[256];
    CHECK(floe_host_reply_text("status=ok action=list format=tar entries=2 bytes=40 path=/workspace/.x",
                               text, sizeof text) > 0, "ok text rendered");
    CHECK(strstr(text, "archive ok") != NULL, "ok text marker");
    CHECK(floe_host_reply_text("status=error code=malformed detail=missing source", text, sizeof text) > 0,
          "error text rendered");
    CHECK(strstr(text, "archive failed") != NULL, "error text marker");
    CHECK(strstr(text, "malformed") != NULL, "error text carries the code");
}

int main(void) {
    check_caps();
    check_parse();
    check_encode();
    check_base64();
    check_reply();
    if (failures != 0) {
        fprintf(stderr, "host-archive-check: %d failure(s)\n", failures);
        return 1;
    }
    printf("host-archive-check: all checks passed\n");
    return 0;
}
