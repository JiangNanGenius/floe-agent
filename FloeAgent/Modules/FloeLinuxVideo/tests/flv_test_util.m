/* SPDX-License-Identifier: MPL-2.0 */
#import "flv_test_util.h"

void flv_test_notify(void *opaque, uint64_t session_tag, uint32_t events) {
    (void)session_tag;
    FLVTestNotifyState *st = (FLVTestNotifyState *)opaque;
    if (!st) return;
    atomic_fetch_add(&st->total_calls, 1u);
    if (events & FLV_EVENT_OUTPUT_READY) atomic_fetch_add(&st->output_ready, 1u);
    if (events & FLV_EVENT_INPUT_READY) atomic_fetch_add(&st->input_ready, 1u);
    if (events & FLV_EVENT_ERROR) atomic_fetch_add(&st->error_events, 1u);
}

int flv_test_make_host(FLVHost **host_out, uint32_t max_sessions,
                       uint32_t max_inflight, FLVTestNotifyState *notify_state) {
    FLVHostConfig cfg;
    memset(&cfg, 0, sizeof(cfg));
    cfg.abi_version = FLV_ABI_VERSION;
    cfg.max_sessions = max_sessions ? max_sessions : 4;
    cfg.max_inflight_per_session = max_inflight ? max_inflight : 4;
    cfg.max_packet_bytes = 64ull * 1024ull * 1024ull;
    cfg.max_frame_bytes = 128ull * 1024ull * 1024ull;
    cfg.max_owned_bytes = 512ull * 1024ull * 1024ull;
    cfg.notify = flv_test_notify;
    cfg.notify_opaque = notify_state;
    return flv_host_create(&cfg, host_out);
}

uint8_t *flv_test_load_file(const char *path, size_t *out_bytes) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (n < 0) { fclose(f); return NULL; }
    uint8_t *buf = malloc((size_t)n + 1);
    if (!buf) { fclose(f); return NULL; }
    if (fread(buf, 1, (size_t)n, f) != (size_t)n) { free(buf); fclose(f); return NULL; }
    fclose(f);
    *out_bytes = (size_t)n;
    return buf;
}

int flv_test_sha256(const uint8_t *data, size_t bytes, char hex_out[65]) {
    if (!hex_out) return -1;
    if (bytes && !data) return -1;
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data, (CC_LONG)bytes, digest);
    for (size_t i = 0; i < CC_SHA256_DIGEST_LENGTH; i++)
        sprintf(hex_out + i * 2, "%02x", digest[i]);
    hex_out[64] = '\0';
    return 0;
}

uint32_t flv_test_drain(FLVSession *s, FLVOutput *last) {
    uint32_t n = 0;
    for (;;) {
        FLVOutput out;
        int rc = flv_session_dequeue(s, &out);
        if (rc == FLV_AGAIN) break;
        if (rc != FLV_OK) break;
        if (last) *last = out;
        flv_session_release_output(s, &out);
        n++;
    }
    return n;
}

int flv_test_nal_is_aud(uint32_t codec, const uint8_t *nal, size_t bytes_available) {
    if (!nal || bytes_available < 5) return 0;
    const uint8_t *p = nal;
    /* skip 3- or 4-byte start code */
    if (p[0] == 0 && p[1] == 0 && p[2] == 1) p += 3;
    else if (p[0] == 0 && p[1] == 0 && p[2] == 0 && p[3] == 1) p += 4;
    else return 0;
    /* p[0] is the NAL header byte; require it to be inside the buffer. */
    if ((size_t)(p - nal) >= bytes_available) return 0;
    if (codec == FLV_H264) return (*p & 0x1F) == 9;
    if (codec == FLV_HEVC) return ((*p >> 1) & 0x3F) == 35;
    return 0;
}

int flv_test_split_annexb_aus(const uint8_t *data, size_t bytes, uint32_t codec,
                              const uint8_t ***aus_out, size_t **sizes_out, size_t *count_out) {
    /* Locate every start code first. */
    size_t cap = 64, nsc = 0;
    size_t *sc = malloc(cap * sizeof(size_t));
    for (size_t i = 0; i + 3 <= bytes; i++) {
        if (data[i] == 0 && data[i+1] == 0 && data[i+2] == 1) {
            if (nsc == cap) { cap *= 2; sc = realloc(sc, cap * sizeof(size_t)); }
            sc[nsc++] = i;
            i += 2;
        }
    }
    /* Group into AUs: boundary at each AUD; everything before the first AUD
     * is AU 0. */
    size_t acap = 16, acount = 0;
    const uint8_t **aus = malloc(acap * sizeof(*aus));
    size_t *asizes = malloc(acap * sizeof(*asizes));
    size_t au_start = 0;
    int have_au = 0;
    for (size_t k = 0; k < nsc; k++) {
        if (flv_test_nal_is_aud(codec, data + sc[k], bytes - sc[k])) {
            if (have_au) {
                if (acount == acap) { acap *= 2; aus = realloc(aus, acap * sizeof(*aus)); asizes = realloc(asizes, acap * sizeof(*asizes)); }
                aus[acount] = data + au_start;
                asizes[acount] = sc[k] - au_start;
                acount++;
            }
            au_start = sc[k];
            have_au = 1;
        }
    }
    if (have_au) {
        if (acount == acap) { acap *= 2; aus = realloc(aus, acap * sizeof(*aus)); asizes = realloc(asizes, acap * sizeof(*asizes)); }
        aus[acount] = data + au_start;
        asizes[acount] = bytes - au_start;
        acount++;
    } else {
        /* No AUD at all: whole stream is one access unit. */
        aus[0] = data;
        asizes[0] = bytes;
        acount = 1;
    }
    free(sc);
    *aus_out = aus; *sizes_out = asizes; *count_out = acount;
    return 0;
}

void flv_test_frame_from_nv12(const uint8_t *nv12, uint32_t w, uint32_t h,
                              int64_t pts_ns, int64_t duration_ns, uint64_t tag,
                              int keyframe, FLVFrame *frame_out) {
    memset(frame_out, 0, sizeof(*frame_out));
    frame_out->data = nv12;
    frame_out->bytes = (size_t)w * h * 3 / 2;
    frame_out->width = w;
    frame_out->height = h;
    frame_out->pixel_format = FLV_NV12;
    frame_out->plane_count = 2;
    frame_out->plane_offsets[0] = 0;
    frame_out->plane_bytes[0] = (uint64_t)w * h;
    frame_out->plane_strides[0] = w;
    frame_out->plane_offsets[1] = (uint64_t)w * h;
    frame_out->plane_bytes[1] = (uint64_t)w * h / 2;
    frame_out->plane_strides[1] = w;
    frame_out->pts_ns = pts_ns;
    frame_out->duration_ns = duration_ns;
    frame_out->tag = tag;
    frame_out->flags = keyframe ? FLV_KEYFRAME : 0;
}
