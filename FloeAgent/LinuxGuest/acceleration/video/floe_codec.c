/* SPDX-License-Identifier: MPL-2.0
 *
 * floe-codec — the installed Linux client for the Floe video service.
 *
 * Two real backends share one command surface:
 *   v4l2   standard single-planar V4L2 M2M nodes (/dev/videoN), used by
 *          existing applications unchanged; this client also uses them for
 *          H.264/HEVC decode/encode;
 *   native the typed app-owned broker for formats without a standard
 *          stateful V4L2 mapping (AV1 decode, ProRes 422/4444, and an
 *          explicit generic path for every host-supported codec).
 *
 * `list --json` reports measured availability; it never invents hardware or
 * a working codec. `decode`/`encode` perform real work and fail explicitly.
 *
 * The primary dispatcher may exec this binary with its original argv; the
 * invocation contract is documented in README.md.
 */
#include "floe_codec_broker.h"
#include "floe_codec_v4l2.h"
#include "floe_linux_video.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <strings.h>
#include <unistd.h>

#define FLOE_CODEC_VERSION "1.0.0"
#define FLOE_MAX_INPUT_BYTES (512u * 1024u * 1024u)
#define FLOE_MAX_PACKETS 100000u

typedef struct {
    const char *name;
    uint32_t id;
    const char *fourcc;
    int v4l2_cli; /* this client implements the standard M2M path */
} codec_entry;

static const codec_entry codecs[] = {
    { "h264",       1,  "H264", 1 },
    { "hevc",       2,  "HEVC", 1 },
    { "vp9",        3,  "VP90", 0 },
    { "av1",        4,  NULL,   0 },
    { "mjpeg",      5,  "MJPG", 0 },
    { "mpeg2",      6,  "MPG2", 0 },
    { "mpeg4",      7,  "MPG4", 0 },
    { "prores422",  8,  NULL,   0 },
    { "prores4444", 9,  NULL,   0 },
    { "h263",      10,  "H263", 0 },
    { "vp8",       11,  "VP80", 0 },
};
static const size_t codec_count = sizeof(codecs) / sizeof(codecs[0]);

static const codec_entry *codec_by_name(const char *name) {
    for (size_t i = 0; i < codec_count; i++)
        if (strcasecmp(name, codecs[i].name) == 0) return &codecs[i];
    return NULL;
}

static const codec_entry *codec_by_id(uint32_t id) {
    for (size_t i = 0; i < codec_count; i++)
        if (codecs[i].id == id) return &codecs[i];
    return NULL;
}

static uint32_t parse_fourcc(const char *text) {
    if (!text || strlen(text) < 4) return 0;
    return (uint32_t)(uint8_t)text[0] | ((uint32_t)(uint8_t)text[1] << 8) |
           ((uint32_t)(uint8_t)text[2] << 16) | ((uint32_t)(uint8_t)text[3] << 24);
}

static uint8_t *read_file(const char *path, size_t *bytes_out) {
    FILE *f = fopen(path, "rb");
    if (!f) { perror(path); return NULL; }
    if (fseek(f, 0, SEEK_END)) { fclose(f); return NULL; }
    long size = ftell(f);
    if (size <= 0 || (unsigned long)size > FLOE_MAX_INPUT_BYTES) {
        fprintf(stderr, "floe-codec: %s: unsupported input size\n", path);
        fclose(f);
        return NULL;
    }
    rewind(f);
    uint8_t *data = malloc((size_t)size);
    if (!data || fread(data, 1, (size_t)size, f) != (size_t)size) {
        fclose(f);
        free(data);
        return NULL;
    }
    fclose(f);
    *bytes_out = (size_t)size;
    return data;
}

typedef struct {
    const uint8_t **data;
    size_t *bytes;
    size_t count, capacity;
    uint8_t *blob;
} packet_list;

static int packet_push(packet_list *list, const uint8_t *data, size_t bytes) {
    if (!data || !bytes || list->count >= FLOE_MAX_PACKETS) return -1;
    if (list->count == list->capacity) {
        size_t cap = list->capacity ? list->capacity * 2 : 64;
        if (cap > FLOE_MAX_PACKETS) cap = FLOE_MAX_PACKETS;
        const uint8_t **nd = malloc(cap * sizeof(*nd));
        size_t *nb = malloc(cap * sizeof(*nb));
        if (!nd || !nb) { free((void *)nd); free(nb); return -1; }
        if (list->count) {
            memcpy(nd, list->data, list->count * sizeof(*nd));
            memcpy(nb, list->bytes, list->count * sizeof(*nb));
        }
        free((void *)list->data);
        free(list->bytes);
        list->data = nd;
        list->bytes = nb;
        list->capacity = cap;
    }
    list->data[list->count] = data;
    list->bytes[list->count] = bytes;
    list->count++;
    return 0;
}

/* Annex-B split on AUD: 0 has AUs, 1 has no AUD, -1 is a framing/allocation error.
 * The caller's blob owns the bytes; entries point into it. */
static int split_annexb(packet_list *list, uint8_t *data, size_t bytes, uint32_t codec) {
    size_t start = 0, pos = 0, first = 0;
    int auds = 0;
    while (pos + 3 < bytes) {
        size_t sc = bytes;
        for (size_t i = pos + 2; i < bytes; i++) {
            if (data[i] == 1 && data[i - 1] == 0 && data[i - 2] == 0) {
                sc = i - 2 - (i >= 3 && data[i - 3] == 0 ? 1 : 0);
                break;
            }
        }
        if (sc >= bytes) break;
        size_t header = sc + (data[sc + 2] == 0 ? 4 : 3);
        int is_aud = 0;
        if (header < bytes) {
            if (codec == 1) is_aud = (data[header] & 0x1f) == 9;
            else if (codec == 2) is_aud = ((data[header] >> 1) & 0x3f) == 35;
        }
        if (is_aud) {
            if (auds == 0) first = sc;
            else if (packet_push(list, data + start, sc - start)) return -1;
            start = sc;
            auds++;
        }
        pos = sc + 3;
    }
    if (!auds) return 1;
    if (start < bytes && packet_push(list, data + start, bytes - start)) return -1;
    (void)first;
    return list->count ? 0 : -1;
}

static int load_packets(const char *path, uint32_t codec, size_t frame_hint, packet_list *list) {
    size_t bytes = 0;
    uint8_t *blob = read_file(path, &bytes);
    if (!blob) return -1;
    list->blob = blob;
    if (bytes >= 12 && memcmp(blob, "FVMP", 4) == 0) {
        uint32_t version = 0, count = 0;
        memcpy(&version, blob + 4, 4);
        memcpy(&count, blob + 8, 4);
        if (version != 1 || count > FLOE_MAX_PACKETS) return -1;
        size_t pos = 12;
        for (uint32_t i = 0; i < count; i++) {
            uint32_t len = 0;
            if (pos + 4 > bytes) return -1;
            memcpy(&len, blob + pos, 4);
            pos += 4;
            if (pos + len > bytes || packet_push(list, blob + pos, len)) return -1;
            pos += len;
        }
        return 0;
    }
    if (bytes >= 32 && memcmp(blob, "DKIF", 4) == 0) {
        size_t pos = 32;
        while (pos + 12 <= bytes && list->count < FLOE_MAX_PACKETS) {
            uint32_t len = 0;
            memcpy(&len, blob + pos, 4);
            pos += 12;
            if (pos + len > bytes || packet_push(list, blob + pos, len)) return -1;
            pos += len;
        }
        return list->count ? 0 : -1;
    }
    if (codec == 1 || codec == 2) {
        int split = split_annexb(list, blob, bytes, codec);
        if (split <= 0) return split;
        /* No AUD: the whole file is one access-unit candidate. This is
         * explicit and bounded; multi-frame raw ES without AUD is not
         * silently claimed to work. */
        return packet_push(list, blob, bytes);
    }
    if (frame_hint) {
        for (size_t pos = 0; pos + frame_hint <= bytes; pos += frame_hint)
            if (packet_push(list, blob + pos, frame_hint)) return -1;
        return list->count ? 0 : -1;
    }
    return packet_push(list, blob, bytes);
}

static void free_packets(packet_list *list) {
    free((void *)list->data);
    free(list->bytes);
    free(list->blob);
    memset(list, 0, sizeof(*list));
}

static int cmdline_token(char *out, size_t cap) {
    FILE *f = fopen("/proc/cmdline", "r");
    if (!f) return -1;
    char line[4096];
    size_t n = fread(line, 1, sizeof(line) - 1, f);
    fclose(f);
    line[n] = 0;
    const char *key = "floe.video.broker=";
    char *hit = strstr(line, key);
    if (!hit) return -1;
    hit += strlen(key);
    size_t len = strcspn(hit, " \n");
    if (len == 0 || len >= cap) return -1;
    memcpy(out, hit, len);
    out[len] = 0;
    return 0;
}

static int resolve_endpoint(const char *explicit_endpoint, const char *device,
                            char *host, size_t host_cap, uint16_t *port, uint64_t *token) {
    if (explicit_endpoint) return floe_codec_parse_endpoint(explicit_endpoint, host, host_cap, port, token);
    const char *env = getenv("FLOE_CODEC_ENDPOINT");
    if (env && *env) return floe_codec_parse_endpoint(env, host, host_cap, port, token);
    char cmd[256];
    if (cmdline_token(cmd, sizeof(cmd)) == 0 &&
        floe_codec_parse_endpoint(cmd, host, host_cap, port, token) == 0) return 0;
    return floe_codec_discover_endpoint(device, host, host_cap, port, token);
}

static int open_broker(floe_codec_broker *client, const char *endpoint, const char *device) {
    char host[64];
    uint16_t port = 0;
    uint64_t token = 0;
    if (resolve_endpoint(endpoint, device, host, sizeof(host), &port, &token)) {
        fprintf(stderr, "floe-codec: no native broker endpoint discovered "
                        "(pass --endpoint host:port:token)\n");
        return -1;
    }
    if (floe_codec_broker_open(client, host, port, token)) {
        fprintf(stderr, "floe-codec: cannot connect to %s:%u\n", host, port);
        return -1;
    }
    return 0;
}

static const char *backend_name(uint32_t flags) {
    if ((flags & (FLV_CAP_HW_REPORTED | FLV_CAP_SESSION_PROBED)) ==
        (FLV_CAP_HW_REPORTED | FLV_CAP_SESSION_PROBED)) return "hardware";
    if (flags & FLV_CAP_NATIVE_SOFTWARE_PROBED) return "native-software";
    if (flags & FLV_CAP_IMPLEMENTED) return "implemented-unproven";
    return "unsupported";
}

static void print_limits(uint32_t max_width, uint32_t max_height) {
    printf("\"max_width\":%u,\"max_height\":%u", max_width, max_height);
}

static int cmd_list(const char *device, const char *endpoint, int json) {
    floe_v4l2_device_info devices[64];
    size_t device_count = 0;
    floe_codec_v4l2_scan(devices, 64, &device_count);
    floe_codec_broker broker;
    int broker_ok = open_broker(&broker, endpoint, device) == 0;
    floe_codec_capability caps[FLOE_CODEC_MAX_CAPS];
    size_t cap_count = 0;
    uint32_t native_enabled = 0;
    if (broker_ok &&
        floe_codec_broker_list(&broker, caps, FLOE_CODEC_MAX_CAPS, &cap_count, &native_enabled)) {
        broker_ok = 0;
        cap_count = 0;
    }
    if (!json) {
        printf("floe-codec %s\n", FLOE_CODEC_VERSION);
        for (size_t i = 0; i < device_count; i++) {
            printf("v4l2 %s card=%s bus=%s formats=0x%08x\n",
                   devices[i].path, devices[i].card, devices[i].bus, (devices[i].decode_formats | devices[i].encode_formats));
        }
        printf("native endpoint=%s connected=%d policy=%s\n",
               broker_ok ? broker.host : "unavailable", broker_ok,
               native_enabled ? "allow-native-software" : "hardware-only");
        for (size_t i = 0; i < cap_count; i++) {
            const codec_entry *c = codec_by_id(caps[i].codec);
            printf("%-10s %-6s %-20s flags=%u probe=%d %ux%u\n",
                   c ? c->name : "?", caps[i].direction == FLV_ENCODE ? "encode" : "decode",
                   backend_name(caps[i].flags), caps[i].flags, caps[i].probe_status,
                   caps[i].max_width, caps[i].max_height);
        }
        if (broker_ok) floe_codec_broker_close(&broker);
        return 0;
    }

    printf("{\"schema\":\"floe-codec/1\",\"version\":\"%s\",\"devices\":[", FLOE_CODEC_VERSION);
    for (size_t i = 0; i < device_count; i++) {
        if (i) putchar(',');
        printf("{\"path\":\"%s\",\"card\":\"%s\",\"bus\":\"%s\",\"m2m\":%s,\"formats\":%u}",
               devices[i].path, devices[i].card, devices[i].bus,
               devices[i].m2m ? "true" : "false", (devices[i].decode_formats | devices[i].encode_formats));
    }
    printf("],\"native\":{\"connected\":%s,\"endpoint\":\"%s\",\"policy\":\"%s\","
           "\"capabilities\":[",
           broker_ok ? "true" : "false", broker_ok ? broker.host : "",
           native_enabled ? "allow-native-software" : "hardware-only");
    for (size_t i = 0; i < cap_count; i++) {
        const codec_entry *c = codec_by_id(caps[i].codec);
        if (i) putchar(',');
        printf("{\"codec\":\"%s\",\"codec_id\":%u,\"direction\":\"%s\","
               "\"flags\":%u,\"backend\":\"%s\",\"probe_status\":%d,"
               "\"native_software_allowed\":%s,",
               c ? c->name : "unknown", caps[i].codec,
               caps[i].direction == FLV_ENCODE ? "encode" : "decode",
               caps[i].flags, backend_name(caps[i].flags), caps[i].probe_status,
               ((caps[i].flags & FLV_CAP_NATIVE_SOFTWARE_PROBED) && native_enabled) ? "true" : "false");
        print_limits(caps[i].max_width, caps[i].max_height);
        putchar('}');
    }
    printf("]},\"codecs\":[");
    int first_codec = 1;
    for (size_t ci = 0; ci < codec_count; ci++) {
        const codec_entry *c = &codecs[ci];
        int wrote = 0;
        for (uint32_t dir = 0; dir < 2; dir++) {
            uint32_t direction = dir == 0 ? FLV_ENCODE : FLV_DECODE;
            const floe_codec_capability *cap = NULL;
            for (size_t i = 0; i < cap_count; i++)
                if (caps[i].codec == c->id && caps[i].direction == direction) { cap = &caps[i]; break; }
            int v4l2 = 0;
            if (c->fourcc) {
                for (size_t i = 0; i < device_count; i++)
                    if ((direction == FLV_ENCODE ? devices[i].encode_formats : devices[i].decode_formats) & (1u << c->id)) { v4l2 = 1; break; }
            }
            int hardware = cap &&
                (cap->flags & (FLV_CAP_HW_REPORTED | FLV_CAP_SESSION_PROBED)) ==
                (FLV_CAP_HW_REPORTED | FLV_CAP_SESSION_PROBED);
            int software = cap && (cap->flags & FLV_CAP_NATIVE_SOFTWARE_PROBED);
            int usable = v4l2 || hardware || (software && native_enabled) ||
                         (cap && direction == FLV_ENCODE && c->v4l2_cli && hardware);
            if (!wrote) { if (!first_codec) putchar(','); printf("{\"codec\":\"%s\",\"codec_id\":%u,", c->name, c->id); first_codec = 0; wrote = 1; }
            if (dir != 0) putchar(',');
            printf("\"%s\":{\"v4l2\":%s,\"native\":%s,\"hardware\":%s,\"native_software\":%s,"
                   "\"native_software_allowed\":%s,\"usable\":%s,\"flags\":%u}",
                   direction == FLV_ENCODE ? "encode" : "decode",
                   v4l2 ? "true" : "false", cap ? "true" : "false",
                   hardware ? "true" : "false", software ? "true" : "false",
                   (software && native_enabled) ? "true" : "false",
                   usable ? "true" : "false", cap ? cap->flags : 0);
        }
        if (wrote) putchar('}');
    }
    printf("]}\n");
    if (broker_ok) floe_codec_broker_close(&broker);
    return 0;
}

static int drain_native(floe_codec_broker *broker, uint64_t session, FILE *output,
                        uint64_t *packets, uint64_t *frames, uint64_t *bytes,
                        uint64_t *hardware, uint64_t *software, int wait_ms, int stop_on_eos) {
    for (int spin = 0; spin < 10000; spin++) {
        flvb_reply reply;
        uint8_t *payload = NULL;
        int status = floe_codec_broker_dequeue(broker, session, &reply, &payload, (uint32_t)wait_ms);
        if (status == FLV_AGAIN) return 0;
        if (status != FLV_OK) { free(payload); return -1; }
        if (reply.kind == FLV_OUTPUT_PACKET || reply.kind == FLV_OUTPUT_FRAME) {
            if (reply.length && output) {
                if (fwrite(payload, 1, reply.length, output) != reply.length) { free(payload); return -1; }
            }
            *bytes += reply.length;
            if (reply.kind == FLV_OUTPUT_PACKET) (*packets)++;
            else (*frames)++;
            if (reply.hardware_used) (*hardware)++;
            else (*software)++;
        } else if (reply.kind == FLV_OUTPUT_ERROR) {
            free(payload);
            return -1;
        }
        int eos = reply.kind == FLV_OUTPUT_EOS;
        free(payload);
        if (eos && stop_on_eos) return 1;
        wait_ms = 0;
    }
    return 0;
}

static int native_decode(const char *endpoint, const char *device, const codec_entry *codec,
                         const char *input, const char *output, uint32_t width, uint32_t height,
                         size_t frame_hint, uint32_t limit, const char *config_path,
                         int require_hardware, int json) {
    floe_codec_broker broker;
    if (open_broker(&broker, endpoint, device)) return 1;
    packet_list packets;
    memset(&packets, 0, sizeof(packets));
    if (load_packets(input, codec->id, frame_hint, &packets)) {
        fprintf(stderr, "floe-codec: cannot frame input %s\n", input);
        free_packets(&packets);
        floe_codec_broker_close(&broker);
        return 1;
    }
    uint8_t *config = NULL;
    size_t config_bytes = 0;
    if (config_path) config = read_file(config_path, &config_bytes);
    uint32_t bitstream = (codec->id == FLV_H264 || codec->id == FLV_HEVC)
                         ? FLV_ANNEX_B : FLV_RAW_CODED_FRAME;
    uint32_t flags = require_hardware ? FLV_REQUIRE_HARDWARE : 0;
    uint64_t session = 0;
    if (floe_codec_broker_create(&broker, codec->id, FLV_DECODE, FLV_NV12,
                                 width, height, bitstream, flags, 0,
                                 config, config_bytes, &session)) {
        fprintf(stderr, "floe-codec: native decode session refused (codec=%s w=%u h=%u)\n",
                codec->name, width, height);
        free(config); free_packets(&packets); floe_codec_broker_close(&broker);
        return 1;
    }
    FILE *out = strcmp(output, "-") ? fopen(output, "wb") : stdout;
    if (!out) { perror(output); floe_codec_broker_destroy(&broker, session); free(config); free_packets(&packets); floe_codec_broker_close(&broker); return 1; }
    uint64_t packets_out = 0, frames_out = 0, bytes_out = 0, hardware = 0, software = 0;
    size_t packets_in = packets.count;
    int failed = 0;
    for (size_t i = 0; i < packets.count && !failed; i++) {
        int rc;
        do {
            rc = floe_codec_broker_submit_packet(&broker, session, packets.data[i], packets.bytes[i],
                                                 (int64_t)i * 33333333, (int64_t)i * 33333333,
                                                 33333333, 0);
            if (rc == FLV_AGAIN) drain_native(&broker, session, out, &packets_out, &frames_out,
                                              &bytes_out, &hardware, &software, 1, 0);
        } while (rc == FLV_AGAIN);
        if (rc != FLV_OK) { failed = 1; break; }
        drain_native(&broker, session, out, &packets_out, &frames_out, &bytes_out,
                     &hardware, &software, 1, 0);
        if (limit && frames_out >= limit) break;
    }
    if (!failed) {
        floe_codec_broker_flush(&broker, session, 1);
        for (int spin = 0; spin < 200; spin++) {
            if (drain_native(&broker, session, out, &packets_out, &frames_out, &bytes_out,
                             &hardware, &software, 5, 1)) break;
        }
    }
    if (out != stdout) fclose(out);
    floe_codec_broker_destroy(&broker, session);
    free(config);
    free_packets(&packets);
    floe_codec_broker_close(&broker);
    if (json) {
        fprintf(stderr, "{\"command\":\"decode\",\"backend\":\"native\",\"codec\":\"%s\","
                "\"packets_in\":%zu,\"frames_out\":%llu,\"bytes_out\":%llu,"
                "\"hardware_outputs\":%llu,\"native_software_outputs\":%llu,\"ok\":%s}\n",
                codec->name, packets_in, (unsigned long long)frames_out,
                (unsigned long long)bytes_out, (unsigned long long)hardware,
                (unsigned long long)software, (failed || frames_out == 0) ? "false" : "true");
    }
    return (failed || frames_out == 0) ? 1 : 0;
}

static int native_encode(const char *endpoint, const char *device, const codec_entry *codec,
                         const char *input, const char *output, uint32_t width, uint32_t height,
                         uint32_t limit, uint64_t bitrate, int require_hardware, int json) {
    uint64_t frame_bytes = (uint64_t)width * height * 3 / 2;
    if (!frame_bytes) { fprintf(stderr, "floe-codec: width/height are required\n"); return 1; }
    floe_codec_broker broker;
    if (open_broker(&broker, endpoint, device)) return 1;
    uint32_t bitstream = (codec->id == FLV_H264 || codec->id == FLV_HEVC)
                         ? FLV_ANNEX_B : FLV_RAW_CODED_FRAME;
    uint32_t flags = require_hardware ? FLV_REQUIRE_HARDWARE : 0;
    uint64_t session = 0;
    if (floe_codec_broker_create(&broker, codec->id, FLV_ENCODE, FLV_NV12,
                                 width, height, bitstream, flags, bitrate,
                                 NULL, 0, &session)) {
        fprintf(stderr, "floe-codec: native encode session refused (codec=%s w=%u h=%u)\n",
                codec->name, width, height);
        floe_codec_broker_close(&broker);
        return 1;
    }
    FILE *in = strcmp(input, "-") ? fopen(input, "rb") : stdin;
    FILE *out = strcmp(output, "-") ? fopen(output, "wb") : stdout;
    if (!in || !out) { if (in && in != stdin) fclose(in); if (out && out != stdout) fclose(out);
        floe_codec_broker_destroy(&broker, session); floe_codec_broker_close(&broker); return 1; }
    uint8_t *frame = malloc((size_t)frame_bytes);
    uint64_t packets_out = 0, frames_out = 0, bytes_out = 0, hardware = 0, software = 0;
    int failed = !frame;
    uint64_t index = 0;
    while (!failed && (!limit || index < limit)) {
        if (fread(frame, 1, (size_t)frame_bytes, in) != frame_bytes) break;
        int rc;
        do {
            rc = floe_codec_broker_submit_frame(&broker, session, frame, (size_t)frame_bytes,
                                               (int64_t)index * 33333333, 33333333,
                                               index == 0 ? FLV_KEYFRAME : 0);
            if (rc == FLV_AGAIN) drain_native(&broker, session, out, &packets_out, &frames_out,
                                              &bytes_out, &hardware, &software, 1, 0);
        } while (rc == FLV_AGAIN);
        if (rc != FLV_OK) { failed = 1; break; }
        index++;
        drain_native(&broker, session, out, &packets_out, &frames_out, &bytes_out,
                     &hardware, &software, 1, 0);
    }
    if (!failed) {
        floe_codec_broker_flush(&broker, session, 1);
        for (int spin = 0; spin < 200; spin++) {
            if (drain_native(&broker, session, out, &packets_out, &frames_out, &bytes_out,
                             &hardware, &software, 5, 1)) break;
        }
    }
    free(frame);
    if (in != stdin) fclose(in);
    if (out != stdout) fclose(out);
    floe_codec_broker_destroy(&broker, session);
    floe_codec_broker_close(&broker);
    if (json) {
        fprintf(stderr, "{\"command\":\"encode\",\"backend\":\"native\",\"codec\":\"%s\","
                "\"frames_in\":%llu,\"packets_out\":%llu,\"bytes_out\":%llu,"
                "\"hardware_outputs\":%llu,\"native_software_outputs\":%llu,\"ok\":%s}\n",
                codec->name, (unsigned long long)index, (unsigned long long)packets_out,
                (unsigned long long)bytes_out, (unsigned long long)hardware,
                (unsigned long long)software, (failed || packets_out == 0) ? "false" : "true");
    }
    return (failed || packets_out == 0) ? 1 : 0;
}

static int standard_decode(const char *device, const codec_entry *codec,
                           const char *input, const char *output, uint32_t width, uint32_t height,
                           size_t frame_hint, uint32_t limit, int json) {
    floe_v4l2_device_info info;
    if (floe_codec_v4l2_find(device, 1, codec->id, &info)) {
        fprintf(stderr, "floe-codec: no V4L2 decoder node\n");
        return 1;
    }
    packet_list packets;
    memset(&packets, 0, sizeof(packets));
    if (load_packets(input, codec->id, frame_hint, &packets)) {
        fprintf(stderr, "floe-codec: cannot frame input %s\n", input);
        free_packets(&packets);
        return 1;
    }
    floe_au *aus = calloc(packets.count, sizeof(*aus));
    if (!aus || !packets.count) { free(aus); free_packets(&packets); return 1; }
    for (size_t i = 0; i < packets.count; i++) {
        aus[i].data = packets.data[i];
        aus[i].bytes = packets.bytes[i];
    }
    FILE *out = strcmp(output, "-") ? fopen(output, "wb") : stdout;
    if (!out) { perror(output); free(aus); free_packets(&packets); return 1; }
    uint64_t frames = 0, bytes = 0;
    int rc = floe_codec_v4l2_decode(info.path, parse_fourcc(codec->fourcc), aus,
                                    packets.count, width, height, out, limit, &frames, &bytes);
    if (out != stdout) fclose(out);
    free(aus);
    free_packets(&packets);
    if (json) {
        fprintf(stderr, "{\"command\":\"decode\",\"backend\":\"v4l2\",\"codec\":\"%s\","
                "\"device\":\"%s\",\"frames_out\":%llu,\"bytes_out\":%llu,\"ok\":%s}\n",
                codec->name, info.path, (unsigned long long)frames,
                (unsigned long long)bytes, (rc == 0 && frames > 0) ? "true" : "false");
    }
    return (rc == 0 && frames > 0) ? 0 : 1;
}

static int standard_encode(const char *device, const codec_entry *codec,
                           const char *input, const char *output, uint32_t width, uint32_t height,
                           uint32_t limit, int json) {
    floe_v4l2_device_info info;
    if (floe_codec_v4l2_find(device, 0, codec->id, &info)) {
        fprintf(stderr, "floe-codec: no V4L2 encoder node\n");
        return 1;
    }
    FILE *in = strcmp(input, "-") ? fopen(input, "rb") : stdin;
    FILE *out = strcmp(output, "-") ? fopen(output, "wb") : stdout;
    if (!in || !out) { if (in && in != stdin) fclose(in); if (out && out != stdout) fclose(out); return 1; }
    uint64_t frame_bytes = (uint64_t)width * height * 3 / 2;
    uint64_t chunks = 0, bytes = 0;
    int rc = floe_codec_v4l2_encode(info.path, parse_fourcc(codec->fourcc), in,
                                    width, height, frame_bytes, limit, out, &chunks, &bytes);
    if (in != stdin) fclose(in);
    if (out != stdout) fclose(out);
    if (json) {
        fprintf(stderr, "{\"command\":\"encode\",\"backend\":\"v4l2\",\"codec\":\"%s\","
                "\"device\":\"%s\",\"chunks_out\":%llu,\"bytes_out\":%llu,\"ok\":%s}\n",
                codec->name, info.path, (unsigned long long)chunks,
                (unsigned long long)bytes, (rc == 0 && bytes > 0) ? "true" : "false");
    }
    return (rc == 0 && bytes > 0) ? 0 : 1;
}

static void usage(void) {
    fprintf(stderr,
        "floe-codec %s — Floe Linux video client\n"
        "usage:\n"
        "  floe-codec node-roles\n"
        "  floe-codec list [--json] [--device DEV] [--endpoint HOST:PORT:TOKEN]\n"
        "  floe-codec decode --codec NAME --input FILE --output FILE [--width N --height N]\n"
        "                  [--backend auto|v4l2|native] [--device DEV] [--endpoint ...]\n"
        "                  [--frame-bytes N] [--limit N] [--config RECORD] [--require-hardware] [--json]\n"
        "  floe-codec encode --codec NAME --input RAW --output FILE --width N --height N\n"
        "                  [--backend auto|v4l2|native] [--device DEV] [--endpoint ...]\n"
        "                  [--bitrate N] [--limit N] [--require-hardware] [--json]\n"
        "codecs: h264 hevc vp9 av1 mjpeg mpeg2 mpeg4 prores422 prores4444 h263 vp8\n"
        "input framing: FVMP manifest, IVF (decode), Annex-B AUD (H.264/HEVC), or --frame-bytes.\n",
        FLOE_CODEC_VERSION);
}

int main(int argc, char **argv) {
    if (argc < 2) { usage(); return 2; }
    const char *command = argv[1];
    const char *codec_name = NULL, *input = NULL, *output = NULL;
    const char *backend = "auto", *device = NULL, *endpoint = NULL, *config_path = NULL;
    uint32_t width = 0, height = 0, limit = 0;
    uint64_t bitrate = 8 * 1000 * 1000;
    size_t frame_hint = 0;
    int json = 0, require_hardware = 0;
    for (int i = 2; i < argc; i++) {
        const char *arg = argv[i];
        if (!strcmp(arg, "--json")) json = 1;
        else if (!strcmp(arg, "--require-hardware")) require_hardware = 1;
        else if (!strcmp(arg, "--codec") && i + 1 < argc) codec_name = argv[++i];
        else if (!strcmp(arg, "--input") && i + 1 < argc) input = argv[++i];
        else if (!strcmp(arg, "--output") && i + 1 < argc) output = argv[++i];
        else if (!strcmp(arg, "--backend") && i + 1 < argc) backend = argv[++i];
        else if (!strcmp(arg, "--device") && i + 1 < argc) device = argv[++i];
        else if (!strcmp(arg, "--endpoint") && i + 1 < argc) endpoint = argv[++i];
        else if (!strcmp(arg, "--config") && i + 1 < argc) config_path = argv[++i];
        else if (!strcmp(arg, "--width") && i + 1 < argc) width = (uint32_t)strtoul(argv[++i], NULL, 10);
        else if (!strcmp(arg, "--height") && i + 1 < argc) height = (uint32_t)strtoul(argv[++i], NULL, 10);
        else if (!strcmp(arg, "--limit") && i + 1 < argc) limit = (uint32_t)strtoul(argv[++i], NULL, 10);
        else if (!strcmp(arg, "--bitrate") && i + 1 < argc) bitrate = strtoull(argv[++i], NULL, 10);
        else if (!strcmp(arg, "--frame-bytes") && i + 1 < argc) frame_hint = (size_t)strtoull(argv[++i], NULL, 10);
        else if (!strcmp(arg, "--help") || !strcmp(arg, "-h")) { usage(); return 0; }
        else { fprintf(stderr, "floe-codec: unknown argument %s\n", arg); usage(); return 2; }
    }
    if (!strcmp(command, "node-roles")) {
        floe_v4l2_device_info devices[64];
        size_t count = 0;
        if (floe_codec_v4l2_scan(devices, 64, &count) != 0) return 1;
        uint32_t decode = 0, encode = 0;
        for (size_t i = 0; i < count; i++) {
            decode |= devices[i].decode_formats;
            encode |= devices[i].encode_formats;
        }
        printf("%s %s\n", decode ? "decode" : "-", encode ? "encode" : "-");
        return 0;
    }
    if (!strcmp(command, "list")) return cmd_list(device, endpoint, json);
    if (!input || !output) { usage(); return 2; }
    if (!codec_name) { fprintf(stderr, "floe-codec: --codec is required\n"); return 2; }
    const codec_entry *codec = codec_by_name(codec_name);
    if (!codec) { fprintf(stderr, "floe-codec: unknown codec %s\n", codec_name); return 2; }

    int decode = !strcmp(command, "decode");
    int encode = !strcmp(command, "encode");
    if (!decode && !encode) { usage(); return 2; }
    if (encode && (!width || !height)) {
        fprintf(stderr, "floe-codec: encode requires --width and --height\n");
        return 2;
    }

    int use_v4l2 = 0;
    if (!strcmp(backend, "v4l2")) use_v4l2 = 1;
    else if (!strcmp(backend, "auto") && codec->fourcc && codec->v4l2_cli) {
        floe_v4l2_device_info info;
        if (floe_codec_v4l2_find(device, decode, codec->id, &info) == 0) use_v4l2 = 1;
    } else if (!strcmp(backend, "native")) use_v4l2 = 0;
    else if (strcmp(backend, "auto")) {
        fprintf(stderr, "floe-codec: --backend must be auto, v4l2 or native\n");
        return 2;
    }

    if (decode) {
        if (use_v4l2) return standard_decode(device, codec, input, output, width, height,
                                             frame_hint, limit, json);
        return native_decode(endpoint, device, codec, input, output, width, height,
                             frame_hint, limit, config_path, require_hardware, json);
    }
    if (use_v4l2) return standard_encode(device, codec, input, output, width, height, limit, json);
    return native_encode(endpoint, device, codec, input, output, width, height,
                         limit, bitrate, require_hardware, json);
}
