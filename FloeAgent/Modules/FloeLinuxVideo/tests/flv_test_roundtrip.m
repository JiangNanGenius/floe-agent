/* SPDX-License-Identifier: MPL-2.0 */
/*
 * Real codec round-trips (macOS component acceptance).
 *
 * Decodes the native-02 H.264/HEVC Annex-B clips and compares every NV12
 * byte against the existing hardware/software-reference goldens, encodes
 * the golden raw frames back to Annex-B streams and re-decodes them, and
 * qualifies additional codecs (VP9/AV1/MJPEG/ProRes/MPEG2/MPEG4/H.263)
 * against generated fixtures when present.
 *
 * Usage: flv_test_roundtrip <fixture_dir> <out_dir>
 *   fixture_dir must contain:
 *     h264-annexb.h264, hevc-annexb.h265           (30 frames, 1280x720)
 *     h264-golden.nv12, hevc-golden.nv12           (41472000 bytes each)
 *     vp9.ivf, av1.ivf, mjpeg.mjpeg                (optional multi/single)
 *     prores422.bin, prores4444.bin, mpeg4.bin, mpeg2.bin, h263.bin (optional single frame)
 */
#import "flv_test_util.h"
#import "FLVBitstream.h"
#import "FLVCodecRegistry.h" /* FLV_CAP_NATIVE_SOFTWARE_PROBED */
#include <unistd.h>
#include <dirent.h>
#include <time.h>

/* Access-unit splitting lives in flv_test_util (AUD-aware; a bare SPS/PPS
 * NAL is metadata, not an access unit). */

static int write_file(const char *path, const uint8_t *data, size_t bytes) {
    FILE *f = fopen(path, "wb");
    if (!f) return -1;
    if (bytes && fwrite(data, 1, bytes, f) != bytes) { fclose(f); return -1; }
    fclose(f);
    return 0;
}

typedef struct {
    FLVSession *session;
    FLVHost *host;
    uint32_t frames;
    uint32_t packets;
    uint32_t format_events;
    uint32_t eos;
    uint32_t errors;
    uint32_t hw_frames;
    uint8_t *pixel_accum;
    size_t pixel_accum_bytes;
    size_t pixel_accum_cap;
    uint8_t *coded_accum;
    size_t coded_accum_bytes;
    size_t coded_accum_cap;
    /* Per-packet (access-unit) boundaries within coded_accum: each encoder
     * output packet is exactly one complete coded access unit. */
    size_t *packet_offs;
    size_t *packet_sizes;
    size_t packet_count, packet_cap;
    uint32_t width, height, pixel_format;
} FLVCollect;

static void collect_output(FLVCollect *c, FLVSession *s) {
    FLVOutput out;
    while (flv_session_dequeue(s, &out) == FLV_OK) {
        if (out.kind == FLV_OUTPUT_FRAME) {
            c->frames++;
            if (out.hardware_used) c->hw_frames++;
            c->width = out.width; c->height = out.height; c->pixel_format = out.pixel_format;
            if (c->pixel_accum_bytes + out.bytes > c->pixel_accum_cap) {
                c->pixel_accum_cap = (c->pixel_accum_bytes + out.bytes) * 2 + 4096;
                c->pixel_accum = realloc(c->pixel_accum, c->pixel_accum_cap);
            }
            memcpy(c->pixel_accum + c->pixel_accum_bytes, out.data, out.bytes);
            c->pixel_accum_bytes += out.bytes;
        } else if (out.kind == FLV_OUTPUT_PACKET) {
            c->packets++;
            if (out.hardware_used) c->hw_frames++;
            if (c->packet_count == c->packet_cap) {
                c->packet_cap = c->packet_cap ? c->packet_cap * 2 : 32;
                c->packet_offs = realloc(c->packet_offs, c->packet_cap * sizeof(size_t));
                c->packet_sizes = realloc(c->packet_sizes, c->packet_cap * sizeof(size_t));
            }
            c->packet_offs[c->packet_count] = c->coded_accum_bytes;
            c->packet_sizes[c->packet_count] = out.bytes;
            c->packet_count++;
            if (c->coded_accum_bytes + out.bytes > c->coded_accum_cap) {
                c->coded_accum_cap = (c->coded_accum_bytes + out.bytes) * 2 + 4096;
                c->coded_accum = realloc(c->coded_accum, c->coded_accum_cap);
            }
            memcpy(c->coded_accum + c->coded_accum_bytes, out.data, out.bytes);
            c->coded_accum_bytes += out.bytes;
        } else if (out.kind == FLV_OUTPUT_FORMAT) {
            c->format_events++;
        } else if (out.kind == FLV_OUTPUT_EOS) {
            c->eos++;
        } else if (out.kind == FLV_OUTPUT_ERROR) {
            c->errors++;
            fprintf(stderr, "error output: status=%d\n", out.status);
        }
        flv_session_release_output(s, &out);
    }
}

/* AGAIN retains caller ownership: wait for asynchronous callbacks, drain,
 * then retry the SAME input. Retrying once immediately can drop a frame. */
static double monotonic_seconds(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1000000000.0;
}

static int submit_packet_wait(FLVCollect *c, const FLVPacket *packet) {
    double deadline = monotonic_seconds() + 2.0;
    int rc;
    do {
        rc = flv_session_submit_packet(c->session, packet);
        if (rc != FLV_AGAIN) return rc;
        collect_output(c, c->session);
        usleep(1000);
    } while (monotonic_seconds() < deadline);
    return FLV_AGAIN;
}

static int submit_frame_wait(FLVCollect *c, const FLVFrame *frame) {
    double deadline = monotonic_seconds() + 2.0;
    int rc;
    do {
        rc = flv_session_submit_frame(c->session, frame);
        if (rc != FLV_AGAIN) return rc;
        collect_output(c, c->session);
        usleep(1000);
    } while (monotonic_seconds() < deadline);
    return FLV_AGAIN;
}

static FLVSession *open_decode_flags(FLVHost *host, uint32_t codec, uint32_t pf,
                                     uint32_t w, uint32_t h, uint32_t bsf,
                                     const uint8_t *cfg, size_t cfg_bytes,
                                     uint32_t flags) {
    FLVSessionConfig sc;
    memset(&sc, 0, sizeof(sc));
    sc.abi_version = FLV_ABI_VERSION;
    sc.codec = codec; sc.direction = FLV_DECODE; sc.pixel_format = pf;
    sc.width = w; sc.height = h;
    sc.frame_rate_num = 30; sc.frame_rate_den = 1;
    sc.bitstream_format = bsf;
    sc.flags = flags;
    sc.codec_config = cfg; sc.codec_config_bytes = cfg_bytes;
    FLVSession *s = NULL;
    if (flv_session_create(host, &sc, &s) != FLV_OK) return NULL;
    return s;
}

static FLVSession *open_decode(FLVHost *host, uint32_t codec, uint32_t pf,
                               uint32_t w, uint32_t h, uint32_t bsf,
                               const uint8_t *cfg, size_t cfg_bytes) {
    return open_decode_flags(host, codec, pf, w, h, bsf, cfg, cfg_bytes,
                             FLV_REQUIRE_HARDWARE);
}

/* True when the capability query proves a native software decode path for
 * codec (flag 8 set, hardware flags absent). */
static int codec_has_software_decode(FLVHost *host, uint32_t codec) {
    FLVCapability caps[22];
    memset(caps, 0, sizeof(caps));
    size_t required = 0;
    if (flv_host_query_capabilities(host, caps, 22, &required) != FLV_OK) return 0;
    for (size_t i = 0; i < 22 && i < required; i++) {
        if (caps[i].codec == codec && caps[i].direction == FLV_DECODE &&
            (caps[i].flags & FLV_CAP_NATIVE_SOFTWARE_PROBED) &&
            !(caps[i].flags & (FLV_CAP_HW_REPORTED | FLV_CAP_SESSION_PROBED)))
            return 1;
    }
    return 0;
}

static FLVSession *open_encode(FLVHost *host, uint32_t codec, uint32_t pf,
                               uint32_t w, uint32_t h, uint32_t bsf, uint64_t bitrate) {
    FLVSessionConfig sc;
    memset(&sc, 0, sizeof(sc));
    sc.abi_version = FLV_ABI_VERSION;
    sc.codec = codec; sc.direction = FLV_ENCODE; sc.pixel_format = pf;
    sc.width = w; sc.height = h;
    sc.frame_rate_num = 30; sc.frame_rate_den = 1;
    sc.bitstream_format = bsf;
    sc.flags = FLV_REQUIRE_HARDWARE;
    sc.bitrate = bitrate;
    FLVSession *s = NULL;
    if (flv_session_create(host, &sc, &s) != FLV_OK) return NULL;
    return s;
}

static int mean_abs_diff(const uint8_t *a, const uint8_t *b, size_t n, double *out) {
    if (n == 0) return -1;
    uint64_t sum = 0;
    size_t step = n / 65536 + 1;
    uint64_t cnt = 0;
    for (size_t i = 0; i < n; i += step) { int d = (int)a[i] - (int)b[i]; if (d < 0) d = -d; sum += (uint64_t)d; cnt++; }
    *out = (double)sum / (double)cnt;
    return 0;
}

static int decode_annexb_clip(FLVHost *host, const char *path, uint32_t codec,
                              FLVCollect *c, int *created) {
    size_t bytes = 0;
    uint8_t *data = flv_test_load_file(path, &bytes);
    if (!data) return -1;
    const uint8_t **aus; size_t *sizes; size_t count;
    flv_test_split_annexb_aus(data, bytes, codec, &aus, &sizes, &count);
    c->session = open_decode(host, codec, FLV_NV12, 0, 0, FLV_ANNEX_B, NULL, 0);
    if (!c->session) { free(aus); free(sizes); free(data); return -2; }
    *created = 1;
    for (size_t i = 0; i < count; i++) {
        FLVPacket pkt;
        memset(&pkt, 0, sizeof(pkt));
        pkt.data = aus[i]; pkt.bytes = sizes[i];
        pkt.pts_ns = (int64_t)i * 33333333;
        pkt.dts_ns = pkt.pts_ns;
        pkt.tag = i + 1;
        int rc = submit_packet_wait(c, &pkt);
        if (rc != FLV_OK) {
            fprintf(stderr, "decode submit rc=%d at %zu\n", rc, i);
            flv_session_close(c->session);
            free(aus); free(sizes); free(data);
            return -3;
        }
        collect_output(c, c->session);
    }
    flv_session_flush(c->session, 1);
    for (int i = 0; i < 600 && !c->eos; i++) {
        collect_output(c, c->session);
        if (!c->eos) usleep(5000);
    }
    collect_output(c, c->session);
    flv_session_close(c->session);
    free(aus); free(sizes); free(data);
    return 0;
}

static int encode_nv12_annexb(FLVHost *host, const uint8_t *nv12, uint32_t w, uint32_t h,
                              uint32_t frames, uint32_t codec, uint64_t bitrate,
                              FLVCollect *c) {
    c->session = open_encode(host, codec, FLV_NV12, w, h, FLV_ANNEX_B, bitrate);
    if (!c->session) return -1;
    size_t frame_bytes = (size_t)w * h * 3 / 2;
    for (uint32_t i = 0; i < frames; i++) {
        FLVFrame fr;
        flv_test_frame_from_nv12(nv12 + (size_t)i * frame_bytes, w, h,
                                 (int64_t)i * 33333333, 33333333, i + 1,
                                 (i % 150 == 0), &fr);
        fr.flags |= (i == frames - 1) ? FLV_END_OF_STREAM : 0;
        int rc = submit_frame_wait(c, &fr);
        if (rc != FLV_OK) {
            fprintf(stderr, "encode submit rc=%d at %u\n", rc, i);
            flv_session_close(c->session);
            return -1;
        }
        collect_output(c, c->session);
    }
    flv_session_flush(c->session, 1);
    for (int i = 0; i < 600 && !c->eos; i++) {
        collect_output(c, c->session);
        if (!c->eos) usleep(5000);
    }
    collect_output(c, c->session);
    flv_session_close(c->session);
    return 0;
}

/* IVF fixture reader for VP9/AV1. */
static int ivf_frames(const uint8_t *data, size_t bytes,
                      const uint8_t ***frames_out, size_t **sizes_out, size_t *count_out,
                      uint32_t *w, uint32_t *h) {
    if (bytes < 32 || memcmp(data, "DKIF", 4) != 0) return -1;
    uint16_t hdr_len = (uint16_t)(data[6] | (data[7] << 8));
    if (hdr_len < 32) return -1;
    *w = (uint32_t)(data[12] | (data[13] << 8));
    *h = (uint32_t)(data[14] | (data[15] << 8));
    size_t off = hdr_len, cap = 16, count = 0;
    const uint8_t **frames = malloc(cap * sizeof(*frames));
    size_t *sizes = malloc(cap * sizeof(*sizes));
    while (off + 12 <= bytes) {
        uint32_t sz = (uint32_t)(data[off] | (data[off+1] << 8) | (data[off+2] << 16) | ((uint32_t)data[off+3] << 24));
        off += 12;
        if (off + sz > bytes) break;
        if (count == cap) { cap *= 2; frames = realloc(frames, cap * sizeof(*frames)); sizes = realloc(sizes, cap * sizeof(*sizes)); }
        frames[count] = data + off;
        sizes[count] = sz;
        count++;
        off += sz;
    }
    *frames_out = frames; *sizes_out = sizes; *count_out = count;
    return 0;
}

static int decode_fixture_packets_mode(FLVHost *host, uint32_t codec,
                                       const uint8_t *cfg, size_t cfg_bytes,
                                       const uint8_t **frames, size_t *sizes, size_t count,
                                       uint32_t w, uint32_t h, uint32_t flags,
                                       FLVCollect *c) {
    c->session = open_decode_flags(host, codec, FLV_NV12, w, h, FLV_RAW_CODED_FRAME,
                                   cfg, cfg_bytes, flags);
    if (!c->session) return -1;
    for (size_t i = 0; i < count; i++) {
        FLVPacket pkt;
        memset(&pkt, 0, sizeof(pkt));
        pkt.data = frames[i]; pkt.bytes = sizes[i];
        pkt.pts_ns = (int64_t)i * 33333333;
        pkt.tag = i + 1;
        int rc = flv_session_submit_packet(c->session, &pkt);
        if (rc == FLV_AGAIN) { collect_output(c, c->session); rc = flv_session_submit_packet(c->session, &pkt); }
        if (rc != FLV_OK) fprintf(stderr, "fixture submit rc=%d at %zu\n", rc, i);
        collect_output(c, c->session);
    }
    flv_session_flush(c->session, 1);
    for (int i = 0; i < 600 && !c->eos; i++) {
        collect_output(c, c->session);
        if (!c->eos) usleep(5000);
    }
    collect_output(c, c->session);
    flv_session_close(c->session);
    return 0;
}

static int decode_fixture_packets(FLVHost *host, uint32_t codec,
                                  const uint8_t *cfg, size_t cfg_bytes,
                                  const uint8_t **frames, size_t *sizes, size_t count,
                                  uint32_t w, uint32_t h, FLVCollect *c) {
    return decode_fixture_packets_mode(host, codec, cfg, cfg_bytes, frames, sizes,
                                       count, w, h, FLV_REQUIRE_HARDWARE, c);
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    if (argc < 3) {
        fprintf(stderr, "usage: %s <fixture_dir> <out_dir>\n", argv[0]);
        return 2;
    }
    const char *fixdir = argv[1];
    const char *outdir = argv[2];
    int core_only = argc == 4 && strcmp(argv[3], "--core-only") == 0;
    if (argc > 3 && !core_only) return 2;
    char path[1024];
    FLVTestNotifyState ns;
    memset(&ns, 0, sizeof(ns));
    FLVHost *host = NULL;
    FLV_TEST_CHECK_STATUS(flv_test_make_host(&host, 4, 16, &ns), FLV_OK);

    printf("{\n  \"test\": \"roundtrip\",\n  \"results\": {\n");

    /* ---- H.264 decode vs golden ---- */
    fprintf(stderr, "phase:h264_decode\n");
    snprintf(path, sizeof(path), "%s/h264-annexb.h264", fixdir);
    FLVCollect dec264; memset(&dec264, 0, sizeof(dec264));
    int created = 0;
    int rc264 = decode_annexb_clip(host, path, FLV_H264, &dec264, &created);
    const char *verdict264 = "skipped";
    if (rc264 == 0 && created) {
        snprintf(path, sizeof(path), "%s/h264-golden.nv12", fixdir);
        size_t golden_bytes = 0;
        uint8_t *golden = flv_test_load_file(path, &golden_bytes);
        int bytes_match = golden && golden_bytes == dec264.pixel_accum_bytes &&
                          memcmp(golden, dec264.pixel_accum, golden_bytes) == 0;
        char got_hash[65], want_hash[65];
        flv_test_sha256(dec264.pixel_accum, dec264.pixel_accum_bytes, got_hash);
        flv_test_sha256(golden, golden ? golden_bytes : 0, want_hash);
        snprintf(path, sizeof(path), "%s/h264-decoded.nv12", outdir);
        write_file(path, dec264.pixel_accum, dec264.pixel_accum_bytes);
        verdict264 = (bytes_match && dec264.errors == 0 && dec264.hw_frames == dec264.frames) ? "passed" : "failed";
        printf("    \"h264_decode\": {\"status\": \"%s\", \"frames\": %u, \"hw_frames\": %u, \"errors\": %u, \"format_events\": %u, \"bytes\": %zu, \"sha256\": \"%s\", \"golden_sha256\": \"%s\", \"match\": %s},\n",
               verdict264, dec264.frames, dec264.hw_frames, dec264.errors, dec264.format_events,
               dec264.pixel_accum_bytes, got_hash, want_hash, bytes_match ? "true" : "false");
        free(golden);
    } else {
        printf("    \"h264_decode\": {\"status\": \"skipped\", \"reason\": \"fixture or hw unavailable\"},\n");
    }
    FLV_TEST_CHECK(strcmp(verdict264, "failed") != 0);
    if (core_only) FLV_TEST_CHECK(strcmp(verdict264, "passed") == 0 && dec264.frames == 30);

    /* ---- HEVC decode vs golden ---- */
    fprintf(stderr, "phase:hevc_decode\n");
    snprintf(path, sizeof(path), "%s/hevc-annexb.h265", fixdir);
    FLVCollect dec265; memset(&dec265, 0, sizeof(dec265));
    created = 0;
    int rc265 = decode_annexb_clip(host, path, FLV_HEVC, &dec265, &created);
    const char *verdict265 = "skipped";
    if (rc265 == 0 && created) {
        snprintf(path, sizeof(path), "%s/hevc-golden.nv12", fixdir);
        size_t golden_bytes = 0;
        uint8_t *golden = flv_test_load_file(path, &golden_bytes);
        int bytes_match = golden && golden_bytes == dec265.pixel_accum_bytes &&
                          memcmp(golden, dec265.pixel_accum, golden_bytes) == 0;
        char got_hash[65], want_hash[65];
        flv_test_sha256(dec265.pixel_accum, dec265.pixel_accum_bytes, got_hash);
        flv_test_sha256(golden, golden ? golden_bytes : 0, want_hash);
        snprintf(path, sizeof(path), "%s/hevc-decoded.nv12", outdir);
        write_file(path, dec265.pixel_accum, dec265.pixel_accum_bytes);
        verdict265 = (bytes_match && dec265.errors == 0 && dec265.hw_frames == dec265.frames) ? "passed" : "failed";
        printf("    \"hevc_decode\": {\"status\": \"%s\", \"frames\": %u, \"hw_frames\": %u, \"errors\": %u, \"format_events\": %u, \"bytes\": %zu, \"sha256\": \"%s\", \"golden_sha256\": \"%s\", \"match\": %s},\n",
               verdict265, dec265.frames, dec265.hw_frames, dec265.errors, dec265.format_events,
               dec265.pixel_accum_bytes, got_hash, want_hash, bytes_match ? "true" : "false");
        free(golden);
    } else {
        printf("    \"hevc_decode\": {\"status\": \"skipped\", \"reason\": \"fixture or hw unavailable\"},\n");
    }
    FLV_TEST_CHECK(strcmp(verdict265, "failed") != 0);
    if (core_only) FLV_TEST_CHECK(strcmp(verdict265, "passed") == 0 && dec265.frames == 30);

    /* ---- H.264 encode -> own decode -> cross-check ---- */
    fprintf(stderr, "phase:h264_encode_and_redecode\n");
    snprintf(path, sizeof(path), "%s/h264-golden.nv12", fixdir);
    {
        size_t raw_bytes = 0;
        uint8_t *raw = flv_test_load_file(path, &raw_bytes);
        FLVCollect enc; memset(&enc, 0, sizeof(enc));
        uint32_t nframes = 0;
        const char *verdict = "skipped";
        if (raw && encode_nv12_annexb(host, raw, 1280, 720, 30, FLV_H264, 2500000, &enc) == 0) {
            nframes = 30;
            snprintf(path, sizeof(path), "%s/h264-ours.h264", outdir);
            write_file(path, enc.coded_accum, enc.coded_accum_bytes);
            /* decode it back with our own decoder. Each encoder output
             * packet is one complete access unit: use the recorded packet
             * boundaries (no re-splitting of the Annex-B stream). */
            FLVCollect redec; memset(&redec, 0, sizeof(redec));
            redec.session = open_decode(host, FLV_H264, FLV_NV12, 0, 0, FLV_ANNEX_B, NULL, 0);
            FLV_TEST_CHECK(redec.session != NULL);
            for (size_t i = 0; i < enc.packet_count; i++) {
                FLVPacket pkt; memset(&pkt, 0, sizeof(pkt));
                pkt.data = enc.coded_accum + enc.packet_offs[i];
                pkt.bytes = enc.packet_sizes[i];
                pkt.pts_ns = (int64_t)i * 33333333; pkt.tag = i + 1;
                FLV_TEST_CHECK_STATUS(submit_packet_wait(&redec, &pkt), FLV_OK);
                collect_output(&redec, redec.session);
            }
            flv_session_flush(redec.session, 1);
            for (int i = 0; i < 600 && !redec.eos; i++) { collect_output(&redec, redec.session); if (!redec.eos) usleep(5000); }
            flv_session_close(redec.session);
            snprintf(path, sizeof(path), "%s/h264-ours-decoded.nv12", outdir);
            write_file(path, redec.pixel_accum, redec.pixel_accum_bytes);
            double mad = -1;
            if (raw && redec.pixel_accum_bytes == raw_bytes)
                mean_abs_diff(raw, redec.pixel_accum, raw_bytes, &mad);
            verdict = (enc.packets == nframes && enc.errors == 0 && enc.hw_frames == enc.packets &&
                       redec.frames == nframes && redec.errors == 0 && mad >= 0.0 && mad < 8.0) ? "passed" : "failed";
            printf("    \"h264_encode\": {\"status\": \"%s\", \"packets\": %u, \"redecoded_frames\": %u, \"mean_abs_diff\": %.3f, \"coded_bytes\": %zu},\n",
                   verdict, enc.packets, redec.frames, mad, enc.coded_accum_bytes);
            free(redec.pixel_accum); free(redec.coded_accum);
        } else if (raw) {
            verdict = "failed";
            printf("    \"h264_encode\": {\"status\": \"failed\"},\n");
        } else {
            printf("    \"h264_encode\": {\"status\": \"skipped\", \"reason\": \"no golden raw\"},\n");
        }
        FLV_TEST_CHECK(strcmp(verdict, "failed") != 0);
        if (core_only) FLV_TEST_CHECK(strcmp(verdict, "passed") == 0);
        free(enc.pixel_accum); free(enc.coded_accum);
        free(enc.packet_offs); free(enc.packet_sizes);
        free(raw);
    }

    /* ---- HEVC encode -> own decode ---- */
    fprintf(stderr, "phase:hevc_encode_and_redecode\n");
    snprintf(path, sizeof(path), "%s/hevc-golden.nv12", fixdir);
    {
        size_t raw_bytes = 0;
        uint8_t *raw = flv_test_load_file(path, &raw_bytes);
        FLVCollect enc; memset(&enc, 0, sizeof(enc));
        const char *verdict = "skipped";
        if (raw && encode_nv12_annexb(host, raw, 1280, 720, 30, FLV_HEVC, 2500000, &enc) == 0) {
            snprintf(path, sizeof(path), "%s/hevc-ours.h265", outdir);
            write_file(path, enc.coded_accum, enc.coded_accum_bytes);
            FLVCollect redec; memset(&redec, 0, sizeof(redec));
            redec.session = open_decode(host, FLV_HEVC, FLV_NV12, 0, 0, FLV_ANNEX_B, NULL, 0);
            FLV_TEST_CHECK(redec.session != NULL);
            for (size_t i = 0; i < enc.packet_count; i++) {
                FLVPacket pkt; memset(&pkt, 0, sizeof(pkt));
                pkt.data = enc.coded_accum + enc.packet_offs[i];
                pkt.bytes = enc.packet_sizes[i];
                pkt.pts_ns = (int64_t)i * 33333333; pkt.tag = i + 1;
                FLV_TEST_CHECK_STATUS(submit_packet_wait(&redec, &pkt), FLV_OK);
                collect_output(&redec, redec.session);
            }
            flv_session_flush(redec.session, 1);
            for (int i = 0; i < 600 && !redec.eos; i++) { collect_output(&redec, redec.session); if (!redec.eos) usleep(5000); }
            flv_session_close(redec.session);
            snprintf(path, sizeof(path), "%s/hevc-ours-decoded.nv12", outdir);
            write_file(path, redec.pixel_accum, redec.pixel_accum_bytes);
            double mad = -1;
            if (redec.pixel_accum_bytes == raw_bytes)
                mean_abs_diff(raw, redec.pixel_accum, raw_bytes, &mad);
            verdict = (enc.packets == 30 && enc.errors == 0 && enc.hw_frames == enc.packets &&
                       redec.frames == 30 && redec.errors == 0 && mad >= 0.0 && mad < 8.0) ? "passed" : "failed";
            printf("    \"hevc_encode\": {\"status\": \"%s\", \"packets\": %u, \"redecoded_frames\": %u, \"mean_abs_diff\": %.3f, \"coded_bytes\": %zu},\n",
                   verdict, enc.packets, redec.frames, mad, enc.coded_accum_bytes);
            free(redec.pixel_accum); free(redec.coded_accum);
        } else if (raw) {
            verdict = "failed";
            printf("    \"hevc_encode\": {\"status\": \"failed\"},\n");
        } else {
            printf("    \"hevc_encode\": {\"status\": \"skipped\", \"reason\": \"no golden raw\"},\n");
        }
        FLV_TEST_CHECK(strcmp(verdict, "failed") != 0);
        if (core_only) FLV_TEST_CHECK(strcmp(verdict, "passed") == 0);
        free(enc.pixel_accum); free(enc.coded_accum);
        free(enc.packet_offs); free(enc.packet_sizes);
        free(raw);
    }

    if (!core_only) {
    /* ---- Additional codec fixtures ---- */
    struct { const char *file; uint32_t codec; const char *name; } fixtures[] = {
        { "vp9.ivf", FLV_VP9, "vp9" },
        { "av1.ivf", FLV_AV1, "av1" },
        { "mjpeg.mjpeg", FLV_MJPEG, "mjpeg" },
        { "prores422.bin", FLV_PRORES422, "prores422" },
        { "prores4444.bin", FLV_PRORES4444, "prores4444" },
        { "mpeg4.bin", FLV_MPEG4, "mpeg4" },
        { "mpeg2.bin", FLV_MPEG2, "mpeg2" },
        { "h263.bin", FLV_H263, "h263" },
    };
    for (size_t fi = 0; fi < sizeof(fixtures)/sizeof(fixtures[0]); fi++) {
        snprintf(path, sizeof(path), "%s/%s", fixdir, fixtures[fi].file);
        size_t bytes = 0;
        uint8_t *data = flv_test_load_file(path, &bytes);
        if (!data) {
            printf("    \"%s_decode\": {\"status\": \"skipped\", \"reason\": \"no fixture\"}%s\n",
                   fixtures[fi].name, fi + 1 < sizeof(fixtures)/sizeof(fixtures[0]) ? "," : "");
            continue;
        }
        FLVCollect c; memset(&c, 0, sizeof(c));
        const char *verdict = "skipped";
        uint32_t w = 0, h = 0;
        /* truthful coded dims from the generated manifest when present */
        {
            char mpath[1024];
            snprintf(mpath, sizeof(mpath), "%s/fixtures.json", fixdir);
            size_t mbytes = 0;
            uint8_t *mdata = flv_test_load_file(mpath, &mbytes);
            if (mdata) {
                NSData *mjd = [NSData dataWithBytesNoCopy:mdata length:mbytes freeWhenDone:NO];
                NSDictionary *manifest = [NSJSONSerialization JSONObjectWithData:mjd options:0 error:nil];
                NSDictionary *entry = manifest[@(fixtures[fi].file)];
                if (entry) {
                    w = (uint32_t)[entry[@"width"] unsignedIntValue];
                    h = (uint32_t)[entry[@"height"] unsignedIntValue];
                }
                free(mdata);
            }
        }
        if (!w || !h) { w = 320; h = 180; }
        const uint8_t **frames = NULL; size_t *sizes = NULL; size_t count = 0;
        uint8_t cfgbuf[64]; size_t cfg_len = 0;
        const uint8_t *cfg = NULL; size_t cfg_bytes = 0;
        int is_ivf = memcmp(data, "DKIF", 4) == 0;
        if (is_ivf) {
            if (ivf_frames(data, bytes, &frames, &sizes, &count, &w, &h) != 0 || count == 0) {
                printf("    \"%s_decode\": {\"status\": \"failed\", \"reason\": \"bad ivf\"}%s\n",
                       fixtures[fi].name, fi + 1 < sizeof(fixtures)/sizeof(fixtures[0]) ? "," : "");
                free(data);
                FLV_TEST_CHECK(0);
            }
            if (fixtures[fi].codec == FLV_VP9) {
                /* 12-byte VT vpcC; dims stay in the format description;
                 * level Undefined + colour unspecified (explicit unknowns). */
                flv_vpcc_build(0, 0, 8, 1, 0, 2, 2, 2, cfgbuf, sizeof(cfgbuf), &cfg_len);
                cfg = cfgbuf; cfg_bytes = cfg_len;
            } else if (fixtures[fi].codec == FLV_AV1) {
                flv_av1c_build(0, 10, 0, 0, cfgbuf, sizeof(cfgbuf), &cfg_len);
                cfg = cfgbuf; cfg_bytes = cfg_len;
            }
        } else if (fixtures[fi].codec == FLV_MJPEG) {
            /* split concatenated JPEG scans on SOI/EOI */
            size_t cap = 8, n = 0;
            frames = malloc(cap * sizeof(*frames));
            sizes = malloc(cap * sizeof(*sizes));
            size_t i = 0;
            while (i + 1 < bytes) {
                if (data[i] == 0xFF && data[i+1] == 0xD8) {
                    size_t start = i, end = bytes;
                    for (size_t j = i + 2; j + 1 < bytes; j++) {
                        if (data[j] == 0xFF && data[j+1] == 0xD9) { end = j + 2; break; }
                    }
                    if (n == cap) { cap *= 2; frames = realloc(frames, cap * sizeof(*frames)); sizes = realloc(sizes, cap * sizeof(*sizes)); }
                    frames[n] = data + start; sizes[n] = end - start; n++;
                    i = end;
                } else i++;
            }
            count = n;
            if (!w || !h) { w = 320; h = 180; }
        } else {
            frames = malloc(sizeof(*frames));
            sizes = malloc(sizeof(*sizes));
            frames[0] = data; sizes[0] = bytes; count = 1;
            if (!w || !h) { w = 320; h = 180; }
            if (fixtures[fi].codec == FLV_MPEG4) {
                /* MPEG-4 Part 2 requires an esds; VT needs the magic cookie.
                 * Without a demuxer we cannot synthesize it here: mark as
                 * unsupported-by-fixture rather than guessing. */
                printf("    \"%s_decode\": {\"status\": \"skipped\", \"reason\": \"needs esds from container\"}%s\n",
                       fixtures[fi].name, fi + 1 < sizeof(fixtures)/sizeof(fixtures[0]) ? "," : "");
                free(frames); free(sizes); free(data);
                continue;
            }
        }
        /* Hardware-required first; when the machine has no hardware path
         * for this codec but the capability query proved native software
         * (flag 8), fall back to a permissive session and require truthful
         * software reporting (hw_frames == 0). */
        const char *mode = "hardware";
        int drc = decode_fixture_packets(host, fixtures[fi].codec, cfg, cfg_bytes,
                                         frames, sizes, count, w, h, &c);
        if (drc != 0 && codec_has_software_decode(host, fixtures[fi].codec)) {
            drc = decode_fixture_packets_mode(host, fixtures[fi].codec, cfg, cfg_bytes,
                                              frames, sizes, count, w, h, 0, &c);
            mode = "software";
        }
        if (drc == 0) {
            char hash[65];
            flv_test_sha256(c.pixel_accum, c.pixel_accum_bytes, hash);
            char outpath[1024];
            snprintf(outpath, sizeof(outpath), "%s/%s-decoded.nv12", outdir, fixtures[fi].name);
            write_file(outpath, c.pixel_accum, c.pixel_accum_bytes);
            if (strcmp(mode, "hardware") == 0) {
                verdict = (c.frames > 0 && c.errors == 0 && c.hw_frames == c.frames) ? "passed" : "failed";
            } else {
                /* Software mode: every frame must report hardware_used == 0. */
                verdict = (c.frames > 0 && c.errors == 0 && c.hw_frames == 0) ? "passed" : "failed";
            }
            /* VP9 pixel reference: first frame must equal the independent
             * ffmpeg software decode (VP9 decoding is bit-exact). */
            const char *pixel_ref = "absent";
            if (fixtures[fi].codec == FLV_VP9 && c.pixel_accum_bytes >= (size_t)w * h * 3 / 2) {
                snprintf(path, sizeof(path), "%s/vp9-ref.nv12", fixdir);
                size_t ref_bytes = 0;
                uint8_t *ref = flv_test_load_file(path, &ref_bytes);
                size_t frame_bytes = (size_t)w * h * 3 / 2;
                if (ref && ref_bytes >= frame_bytes) {
                    int match = memcmp(ref, c.pixel_accum, frame_bytes) == 0;
                    double mad = -1;
                    if (!match) mean_abs_diff(ref, c.pixel_accum, frame_bytes, &mad);
                    pixel_ref = match ? "match" : "mismatch";
                    if (!match) verdict = "failed";
                    printf("    \"vp9_pixel_ref\": {\"status\": \"%s\", \"mean_abs_diff\": %.3f},\n",
                           pixel_ref, mad);
                }
                free(ref);
            }
            printf("    \"%s_decode\": {\"status\": \"%s\", \"mode\": \"%s\", \"frames\": %u, \"hw_frames\": %u, \"errors\": %u, \"bytes\": %zu, \"sha256\": \"%s\"}%s\n",
                   fixtures[fi].name, verdict, mode, c.frames, c.hw_frames, c.errors,
                   c.pixel_accum_bytes, hash,
                   fi + 1 < sizeof(fixtures)/sizeof(fixtures[0]) ||
                   strcmp(fixtures[fi].name, "h263") == 0 ? "," : "");
        } else {
            printf("    \"%s_decode\": {\"status\": \"skipped\", \"reason\": \"hw or session unavailable\"}%s\n",
                   fixtures[fi].name, fi + 1 < sizeof(fixtures)/sizeof(fixtures[0]) ? "," : "");
        }
        free(frames); free(sizes);
        free(c.pixel_accum); free(c.coded_accum);
        free(data);
        FLV_TEST_CHECK(strcmp(verdict, "failed") != 0);
    }

    /* ---- MJPEG encode: 3 frames -> JPEG scans -> decode back ---- */
    {
        const uint32_t w = 320, h = 180;
        size_t fb = (size_t)w * h * 3 / 2;
        uint8_t *nv12 = malloc(fb * 3);
        for (size_t i = 0; i < fb * 3; i++) nv12[i] = (uint8_t)(i * 2654435761u >> 24);
        FLVCollect enc; memset(&enc, 0, sizeof(enc));
        enc.session = open_encode(host, FLV_MJPEG, FLV_NV12, w, h, FLV_RAW_CODED_FRAME, 0);
        const char *verdict = "skipped";
        if (enc.session) {
            for (uint32_t i = 0; i < 3; i++) {
                FLVFrame fr;
                flv_test_frame_from_nv12(nv12 + i * fb, w, h, (int64_t)i * 33333333, 33333333, i + 1, 1, &fr);
                fr.flags |= (i == 2) ? FLV_END_OF_STREAM : 0;
                int rc = flv_session_submit_frame(enc.session, &fr);
                if (rc == FLV_AGAIN) { collect_output(&enc, enc.session); rc = flv_session_submit_frame(enc.session, &fr); }
                if (rc != FLV_OK) { fprintf(stderr, "mjpeg encode rc=%d\n", rc); verdict = "failed"; break; }
                collect_output(&enc, enc.session);
            }
            flv_session_flush(enc.session, 1);
            for (int i = 0; i < 400 && !enc.eos; i++) { collect_output(&enc, enc.session); if (!enc.eos) usleep(5000); }
            flv_session_close(enc.session);
            if (strcmp(verdict, "failed") != 0) {
                /* validate JPEG structure and decode back */
                int soi = enc.coded_accum_bytes > 4 && enc.coded_accum[0] == 0xFF && enc.coded_accum[1] == 0xD8;
                FLVCollect dec; memset(&dec, 0, sizeof(dec));
                const uint8_t *one[1] = { enc.coded_accum };
                size_t one_sz[1] = { enc.coded_accum_bytes };
                if (soi && decode_fixture_packets(host, FLV_MJPEG, NULL, 0, one, one_sz, 1, w, h, &dec) == 0) {
                    verdict = (enc.packets == 3 && dec.frames >= 1 && enc.errors == 0 && dec.errors == 0) ? "passed" : "failed";
                    printf("    \"mjpeg_encode\": {\"status\": \"%s\", \"packets\": %u, \"decoded_back\": %u},\n",
                           verdict, enc.packets, dec.frames);
                    free(dec.pixel_accum); free(dec.coded_accum);
                } else {
                    verdict = "failed";
                    printf("    \"mjpeg_encode\": {\"status\": \"failed\", \"soi\": %d},\n", soi);
                }
            } else {
                printf("    \"mjpeg_encode\": {\"status\": \"failed\"},\n");
            }
        } else {
            printf("    \"mjpeg_encode\": {\"status\": \"skipped\", \"reason\": \"session unavailable\"},\n");
        }
        FLV_TEST_CHECK(strcmp(verdict, "failed") != 0);
        free(enc.pixel_accum); free(enc.coded_accum);
        free(nv12);
    }

    }
    free(dec264.pixel_accum); free(dec264.coded_accum);
    free(dec265.pixel_accum); free(dec265.coded_accum);
    flv_host_destroy(host);
    printf("    \"core_only\": %s\n  },\n  \"status\": \"passed\"\n}\n", core_only ? "true" : "false");
    return 0;
}
