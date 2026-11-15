/* SPDX-License-Identifier: MPL-2.0 */
#import "FLVBitstream.h"

/* Locate start code (0x000001 with optional leading zeros). On success,
 * *cursor is advanced just past the start code and the returned pointer is
 * the NALU payload start. */
const uint8_t *flv_annexb_next_nalu(const uint8_t **cursor, const uint8_t *end,
                                    size_t *nalu_bytes, uint8_t *nal_trailing_zero_count) {
    const uint8_t *p = *cursor;
    if (nal_trailing_zero_count) *nal_trailing_zero_count = 0;
    while (p + 3 <= end) {
        if (p[0] == 0 && p[1] == 0 && p[2] == 1) {
            const uint8_t *payload = p + 3;
            /* find next start code */
            const uint8_t *q = payload;
            const uint8_t *nalu_end = end;
            while (q + 3 <= end) {
                if (q[0] == 0 && q[1] == 0 && q[2] == 1) { nalu_end = q; break; }
                q++;
            }
            /* strip trailing zero bytes before next start code */
            const uint8_t *trim = nalu_end;
            while (trim > payload && trim[-1] == 0) trim--;
            if (nal_trailing_zero_count) *nal_trailing_zero_count = (uint8_t)(nalu_end - trim);
            *nalu_bytes = (size_t)(trim - payload);
            *cursor = payload;
            return payload;
        }
        p++;
    }
    return NULL;
}

size_t flv_annexb_split(const uint8_t *data, size_t bytes,
                        FLVNalu *out, size_t capacity) {
    if (!data || bytes == 0) return 0;
    size_t count = 0;
    const uint8_t *cursor = data;
    const uint8_t *end = data + bytes;
    while (count < capacity) {
        size_t nalu_bytes = 0;
        const uint8_t *payload = flv_annexb_next_nalu(&cursor, end, &nalu_bytes, NULL);
        if (!payload) break;
        out[count].data = payload;
        out[count].bytes = nalu_bytes;
        out[count].nal_type = 0xFF;
        if (nalu_bytes >= 1) {
            uint8_t b0 = payload[0];
            /* codec resolved by caller via flv_h264/hevc_nal_type */
            out[count].nal_type = b0;
        }
        count++;
        cursor = payload + nalu_bytes;
    }
    return count;
}

uint8_t flv_h264_nal_type(const FLVNalu *n) {
    return (n->bytes >= 1) ? (n->data[0] & 0x1F) : 0xFF;
}

uint8_t flv_hevc_nal_type(const FLVNalu *n) {
    return (n->bytes >= 2) ? ((n->data[0] >> 1) & 0x3F) : 0xFF;
}

int flv_nal_is_vcl(uint32_t codec, uint8_t nal_type) {
    switch (codec) {
        case FLV_H264: return nal_type >= 1 && nal_type <= 5;
        case FLV_HEVC: return nal_type >= 0 && nal_type <= 31;
        default: return 0;
    }
}

size_t flv_annexb_to_lenpref_size(const uint8_t *src, size_t src_bytes) {
    FLVNalu nals[64];
    size_t count = flv_annexb_split(src, src_bytes, nals, FLV_ARRAY_COUNT(nals));
    size_t total = 0;
    for (size_t i = 0; i < count; i++) total += 4 + nals[i].bytes;
    return total;
}

int flv_annexb_to_lenpref(const uint8_t *src, size_t src_bytes,
                          uint8_t *dst, size_t dst_capacity, size_t *out_bytes) {
    FLVNalu nals[64];
    size_t count = flv_annexb_split(src, src_bytes, nals, FLV_ARRAY_COUNT(nals));
    size_t needed = 0;
    for (size_t i = 0; i < count; i++) needed += 4 + nals[i].bytes;
    if (needed > dst_capacity) return FLV_LIMIT;
    uint8_t *w = dst;
    for (size_t i = 0; i < count; i++) {
        uint32_t len = (uint32_t)nals[i].bytes;
        w[0] = (uint8_t)(len >> 24); w[1] = (uint8_t)(len >> 16);
        w[2] = (uint8_t)(len >> 8); w[3] = (uint8_t)len;
        memcpy(w + 4, nals[i].data, nals[i].bytes);
        w += 4 + nals[i].bytes;
    }
    *out_bytes = needed;
    return FLV_OK;
}

static size_t param_sets_annexb_size(const FLVParamSets *ps, uint32_t codec) {
    size_t total = 0;
    if (codec == FLV_HEVC) {
        for (uint32_t i = 0; i < ps->vps_count; i++) total += 4 + ps->vps_len[i];
    }
    for (uint32_t i = 0; i < ps->sps_count && i < 1; i++) total += 4 + ps->sps_len[i];
    for (uint32_t i = 0; i < ps->pps_count && i < 1; i++) total += 4 + ps->pps_len[i];
    return total;
}

size_t flv_lenpref_to_annexb_size(const uint8_t *src, size_t src_bytes,
                                  uint32_t codec, const FLVParamSets *ps,
                                  int is_key, int inject_param_sets) {
    (void)src;
    size_t total = src_bytes; /* length fields replaced 1:1 by start codes */
    if (inject_param_sets && is_key && ps) total += param_sets_annexb_size(ps, codec);
    return total;
}

/* Length-prefixed NAL stream: repeating [4-byte BE length][NALU]. */
int flv_lenpref_to_annexb(const uint8_t *src, size_t src_bytes,
                          uint32_t codec, const FLVParamSets *ps,
                          int is_key, int inject_param_sets,
                          uint8_t *dst, size_t dst_capacity, size_t *out_bytes) {
    size_t needed = flv_lenpref_to_annexb_size(src, src_bytes, codec, ps, is_key, inject_param_sets);
    if (needed > dst_capacity) return FLV_LIMIT;
    uint8_t *w = dst;
    if (inject_param_sets && is_key && ps) {
        const uint8_t zero3[3] = {0, 0, 0};
        if (codec == FLV_HEVC) {
            for (uint32_t i = 0; i < ps->vps_count; i++) {
                w[0] = 0; w[1] = 0; w[2] = 0; w[3] = 1;
                memcpy(w + 4, ps->vps[i], ps->vps_len[i]);
                w += 4 + ps->vps_len[i];
            }
        }
        if (ps->sps_count > 0) {
            (void)zero3;
            w[0] = 0; w[1] = 0; w[2] = 0; w[3] = 1;
            memcpy(w + 4, ps->sps[0], ps->sps_len[0]);
            w += 4 + ps->sps_len[0];
        }
        if (ps->pps_count > 0) {
            w[0] = 0; w[1] = 0; w[2] = 0; w[3] = 1;
            memcpy(w + 4, ps->pps[0], ps->pps_len[0]);
            w += 4 + ps->pps_len[0];
        }
    }
    const uint8_t *r = src;
    const uint8_t *end = src + src_bytes;
    while (r + 4 <= end) {
        uint32_t len = ((uint32_t)r[0] << 24) | ((uint32_t)r[1] << 16) |
                       ((uint32_t)r[2] << 8) | r[3];
        r += 4;
        if ((size_t)(end - r) < len) return FLV_CORRUPT;
        w[0] = 0; w[1] = 0; w[2] = 0; w[3] = 1;
        memcpy(w + 4, r, len);
        w += 4 + len;
        r += len;
    }
    if (r != end) return FLV_CORRUPT;
    *out_bytes = (size_t)(w - dst);
    return FLV_OK;
}

int flv_annexb_extract_param_sets(const uint8_t *data, size_t bytes,
                                  uint32_t codec, FLVParamSets *ps) {
    memset(ps, 0, sizeof(*ps));
    ps->length_size = 4;
    FLVNalu nals[64];
    size_t count = flv_annexb_split(data, bytes, nals, FLV_ARRAY_COUNT(nals));
    int found = 0;
    for (size_t i = 0; i < count; i++) {
        uint8_t type;
        if (codec == FLV_H264) type = flv_h264_nal_type(&nals[i]);
        else if (codec == FLV_HEVC) type = flv_hevc_nal_type(&nals[i]);
        else return FLV_UNSUPPORTED;
        const uint8_t *arr = NULL; uint32_t *arr_len = NULL; uint32_t *arr_cnt = NULL;
        if (codec == FLV_H264 && type == 7 && ps->sps_count < FLV_MAX_PARAM_SETS) {
            arr = ps->sps[ps->sps_count]; arr_len = &ps->sps_len[ps->sps_count]; arr_cnt = &ps->sps_count;
        } else if (codec == FLV_H264 && type == 8 && ps->pps_count < FLV_MAX_PARAM_SETS) {
            arr = ps->pps[ps->pps_count]; arr_len = &ps->pps_len[ps->pps_count]; arr_cnt = &ps->pps_count;
        } else if (codec == FLV_HEVC && type == 32 && ps->vps_count < FLV_MAX_PARAM_SETS) {
            arr = ps->vps[ps->vps_count]; arr_len = &ps->vps_len[ps->vps_count]; arr_cnt = &ps->vps_count;
        } else if (codec == FLV_HEVC && type == 33 && ps->sps_count < FLV_MAX_PARAM_SETS) {
            arr = ps->sps[ps->sps_count]; arr_len = &ps->sps_len[ps->sps_count]; arr_cnt = &ps->sps_count;
        } else if (codec == FLV_HEVC && type == 34 && ps->pps_count < FLV_MAX_PARAM_SETS) {
            arr = ps->pps[ps->pps_count]; arr_len = &ps->pps_len[ps->pps_count]; arr_cnt = &ps->pps_count;
        }
        if (arr && nals[i].bytes <= 512) {
            memcpy((void *)arr, nals[i].data, nals[i].bytes);
            *arr_len = (uint32_t)nals[i].bytes;
            (*arr_cnt)++;
            found = 1;
        }
    }
    return found ? FLV_OK : FLV_CORRUPT;
}

/* ---- avcC ---- */

int flv_avcc_parse(const uint8_t *cfg, size_t bytes, FLVParamSets *ps) {
    memset(ps, 0, sizeof(*ps));
    if (!cfg || bytes < 8) return FLV_CORRUPT;
    if (cfg[0] != 1) return FLV_CORRUPT;
    uint8_t len_size_minus_one = cfg[4] & 0x03;
    if (len_size_minus_one == 0) return FLV_CORRUPT;
    ps->length_size = (uint32_t)len_size_minus_one + 1;
    uint32_t num_sps = cfg[5] & 0x1F;
    size_t off = 6;
    for (uint32_t i = 0; i < num_sps; i++) {
        if (off + 2 > bytes) return FLV_CORRUPT;
        uint32_t len = ((uint32_t)cfg[off] << 8) | cfg[off + 1];
        off += 2;
        if (off + len > bytes || len > 512) return FLV_CORRUPT;
        if (ps->sps_count < FLV_MAX_PARAM_SETS) {
            memcpy(ps->sps[ps->sps_count], cfg + off, len);
            ps->sps_len[ps->sps_count] = len;
            ps->sps_count++;
        }
        off += len;
    }
    if (off + 1 > bytes) return FLV_CORRUPT;
    uint32_t num_pps = cfg[off]; off += 1;
    for (uint32_t i = 0; i < num_pps; i++) {
        if (off + 2 > bytes) return FLV_CORRUPT;
        uint32_t len = ((uint32_t)cfg[off] << 8) | cfg[off + 1];
        off += 2;
        if (off + len > bytes || len > 512) return FLV_CORRUPT;
        if (ps->pps_count < FLV_MAX_PARAM_SETS) {
            memcpy(ps->pps[ps->pps_count], cfg + off, len);
            ps->pps_len[ps->pps_count] = len;
            ps->pps_count++;
        }
        off += len;
    }
    if (ps->sps_count == 0 || ps->pps_count == 0) return FLV_CORRUPT;
    return FLV_OK;
}

int flv_avcc_build(const FLVParamSets *ps, uint8_t *dst, size_t cap, size_t *out_bytes) {
    if (ps->sps_count == 0 || ps->pps_count == 0) return FLV_CORRUPT;
    size_t needed = 6;
    for (uint32_t i = 0; i < ps->sps_count && i < FLV_MAX_PARAM_SETS; i++) needed += 2 + ps->sps_len[i];
    needed += 1;
    for (uint32_t i = 0; i < ps->pps_count && i < FLV_MAX_PARAM_SETS; i++) needed += 2 + ps->pps_len[i];
    if (needed > cap) return FLV_LIMIT;
    uint8_t *w = dst;
    *w++ = 1;
    /* derive profile/compat/level from first SPS when present */
    if (ps->sps_len[0] >= 4) { *w++ = ps->sps[0][1]; *w++ = ps->sps[0][2]; *w++ = ps->sps[0][3]; }
    else { *w++ = 0x64; *w++ = 0; *w++ = 0x1F; }
    *w++ = (uint8_t)(0xFC | ((4 - 1) & 0x03)); /* lengthSizeMinusOne=3 */
    uint32_t sps_n = ps->sps_count > FLV_MAX_PARAM_SETS ? FLV_MAX_PARAM_SETS : ps->sps_count;
    *w++ = (uint8_t)(0xE0 | sps_n);
    for (uint32_t i = 0; i < sps_n; i++) {
        *w++ = (uint8_t)(ps->sps_len[i] >> 8); *w++ = (uint8_t)ps->sps_len[i];
        memcpy(w, ps->sps[i], ps->sps_len[i]); w += ps->sps_len[i];
    }
    uint32_t pps_n = ps->pps_count > FLV_MAX_PARAM_SETS ? FLV_MAX_PARAM_SETS : ps->pps_count;
    *w++ = (uint8_t)pps_n;
    for (uint32_t i = 0; i < pps_n; i++) {
        *w++ = (uint8_t)(ps->pps_len[i] >> 8); *w++ = (uint8_t)ps->pps_len[i];
        memcpy(w, ps->pps[i], ps->pps_len[i]); w += ps->pps_len[i];
    }
    *out_bytes = (size_t)(w - dst);
    return FLV_OK;
}

/* ---- hvcC ---- */

int flv_hvcc_parse(const uint8_t *cfg, size_t bytes, FLVParamSets *ps) {
    memset(ps, 0, sizeof(*ps));
    if (!cfg || bytes < 23) return FLV_CORRUPT;
    if (cfg[0] != 1) return FLV_CORRUPT;
    uint8_t len_size_minus_one = cfg[21] & 0x03;
    if (len_size_minus_one == 0) return FLV_CORRUPT;
    ps->length_size = (uint32_t)len_size_minus_one + 1;
    uint32_t num_arrays = cfg[22];
    size_t off = 23;
    for (uint32_t a = 0; a < num_arrays; a++) {
        if (off + 3 > bytes) return FLV_CORRUPT;
        uint8_t nal_type = cfg[off] & 0x3F;
        uint32_t num_nalus = ((uint32_t)cfg[off + 1] << 8) | cfg[off + 2];
        off += 3;
        for (uint32_t i = 0; i < num_nalus; i++) {
            if (off + 2 > bytes) return FLV_CORRUPT;
            uint32_t len = ((uint32_t)cfg[off] << 8) | cfg[off + 1];
            off += 2;
            if (off + len > bytes || len > 512) return FLV_CORRUPT;
            uint8_t *arr = NULL; uint32_t *arr_len = NULL; uint32_t *arr_cnt = NULL;
            if (nal_type == 32 && ps->vps_count < FLV_MAX_PARAM_SETS) {
                arr = ps->vps[ps->vps_count]; arr_len = &ps->vps_len[ps->vps_count]; arr_cnt = &ps->vps_count;
            } else if (nal_type == 33 && ps->sps_count < FLV_MAX_PARAM_SETS) {
                arr = ps->sps[ps->sps_count]; arr_len = &ps->sps_len[ps->sps_count]; arr_cnt = &ps->sps_count;
            } else if (nal_type == 34 && ps->pps_count < FLV_MAX_PARAM_SETS) {
                arr = ps->pps[ps->pps_count]; arr_len = &ps->pps_len[ps->pps_count]; arr_cnt = &ps->pps_count;
            }
            if (arr) {
                memcpy(arr, cfg + off, len);
                *arr_len = len;
                (*arr_cnt)++;
            }
            off += len;
        }
    }
    if (ps->sps_count == 0 || ps->pps_count == 0) return FLV_CORRUPT;
    if (ps->vps_count == 0 && bytes >= 23) { /* HEVC strictly needs VPS; tolerate */
    }
    return FLV_OK;
}

int flv_hvcc_build(const FLVParamSets *ps, uint8_t *dst, size_t cap, size_t *out_bytes) {
    if (ps->sps_count == 0 || ps->pps_count == 0) return FLV_CORRUPT;
    uint32_t sps_n = ps->sps_count > FLV_MAX_PARAM_SETS ? FLV_MAX_PARAM_SETS : ps->sps_count;
    uint32_t pps_n = ps->pps_count > FLV_MAX_PARAM_SETS ? FLV_MAX_PARAM_SETS : ps->pps_count;
    uint32_t vps_n = ps->vps_count > FLV_MAX_PARAM_SETS ? FLV_MAX_PARAM_SETS : ps->vps_count;
    size_t needed = 23;
    if (vps_n) { needed += 3; for (uint32_t i = 0; i < vps_n; i++) needed += 2 + ps->vps_len[i]; }
    needed += 3; for (uint32_t i = 0; i < sps_n; i++) needed += 2 + ps->sps_len[i];
    needed += 3; for (uint32_t i = 0; i < pps_n; i++) needed += 2 + ps->pps_len[i];
    if (needed > cap) return FLV_LIMIT;
    uint8_t *w = dst;
    *w++ = 1;
    uint8_t profile_byte = 0x01; uint8_t level = 0x78;
    if (ps->sps_len[0] >= 12) {
        profile_byte = ps->sps[0][1];
        level = ps->sps[0][12];
    }
    *w++ = profile_byte;
    /* general_profile_compatibility_flags */
    *w++ = 0; *w++ = 0; *w++ = 0; *w++ = 0;
    /* general_constraint_indicator_flags */
    for (int i = 0; i < 6; i++) *w++ = 0;
    *w++ = level;
    *w++ = 0xF0; *w++ = 0x00; /* min_spatial_segmentation_idc */
    *w++ = 0xFC;              /* parallelismType */
    *w++ = 0xFD;              /* chromaFormat 4:2:0 */
    *w++ = 0xF8;              /* bitDepthLumaMinus8 */
    *w++ = 0xF8;              /* bitDepthChromaMinus8 */
    *w++ = 0x00; *w++ = 0x00; /* avgFrameRate */
    *w++ = (uint8_t)(0x0F);   /* constantFrameRate 0, numTemporalLayers 1, nested, lengthSizeMinusOne 3 */
    uint8_t num_arrays = (uint8_t)((vps_n ? 1 : 0) + 1 + 1);
    *w++ = num_arrays;
    if (vps_n) {
        *w++ = 32; *w++ = (uint8_t)(vps_n >> 8); *w++ = (uint8_t)vps_n;
        for (uint32_t i = 0; i < vps_n; i++) {
            *w++ = (uint8_t)(ps->vps_len[i] >> 8); *w++ = (uint8_t)ps->vps_len[i];
            memcpy(w, ps->vps[i], ps->vps_len[i]); w += ps->vps_len[i];
        }
    }
    *w++ = 33; *w++ = (uint8_t)(sps_n >> 8); *w++ = (uint8_t)sps_n;
    for (uint32_t i = 0; i < sps_n; i++) {
        *w++ = (uint8_t)(ps->sps_len[i] >> 8); *w++ = (uint8_t)ps->sps_len[i];
        memcpy(w, ps->sps[i], ps->sps_len[i]); w += ps->sps_len[i];
    }
    *w++ = 34; *w++ = (uint8_t)(pps_n >> 8); *w++ = (uint8_t)pps_n;
    for (uint32_t i = 0; i < pps_n; i++) {
        *w++ = (uint8_t)(ps->pps_len[i] >> 8); *w++ = (uint8_t)ps->pps_len[i];
        memcpy(w, ps->pps[i], ps->pps_len[i]); w += ps->pps_len[i];
    }
    *out_bytes = (size_t)(w - dst);
    return FLV_OK;
}

/* ---- SPS dimension parsing (RBSP with emulation-prevention removal) ---- */

typedef struct {
    const uint8_t *data;
    size_t bytes;   /* RBSP length after EPB removal */
    uint8_t buf[4096];
    size_t bit_pos;
} FLVRbsp;

static int flv_rbsp_init(FLVRbsp *r, const uint8_t *nalu_payload, size_t bytes) {
    if (bytes > sizeof(r->buf)) return FLV_CORRUPT;
    size_t w = 0;
    for (size_t i = 0; i < bytes; i++) {
        if (i >= 2 && nalu_payload[i] == 0x03 && r->buf[w - 1] == 0x00 && r->buf[w - 2] == 0x00) {
            continue; /* emulation_prevention_three_byte */
        }
        r->buf[w++] = nalu_payload[i];
    }
    r->data = r->buf;
    r->bytes = w;
    r->bit_pos = 0;
    return FLV_OK;
}

static int flv_rbsp_u(FLVRbsp *r, unsigned n, uint32_t *out) {
    if (n > 32) return FLV_CORRUPT;
    uint32_t v = 0;
    for (unsigned i = 0; i < n; i++) {
        if (r->bit_pos >= r->bytes * 8) return FLV_CORRUPT;
        v = (v << 1) | ((r->buf[r->bit_pos >> 3] >> (7 - (r->bit_pos & 7))) & 1u);
        r->bit_pos++;
    }
    *out = v;
    return FLV_OK;
}

static int flv_rbsp_ue(FLVRbsp *r, uint32_t *out) {
    uint32_t leading = 0;
    uint32_t bit = 0;
    do {
        if (flv_rbsp_u(r, 1, &bit) != FLV_OK) return FLV_CORRUPT;
        if (bit == 0) {
            leading++;
            if (leading > 31) return FLV_CORRUPT;
        }
    } while (bit == 0);
    uint32_t suffix = 0;
    if (leading > 0 && flv_rbsp_u(r, leading, &suffix) != FLV_OK) return FLV_CORRUPT;
    *out = ((1u << leading) - 1u) + suffix;
    return FLV_OK;
}

static int flv_rbsp_se(FLVRbsp *r, int32_t *out) {
    uint32_t code;
    if (flv_rbsp_ue(r, &code) != FLV_OK) return FLV_CORRUPT;
    int32_t v = (int32_t)((code + 1) >> 1);
    *out = (code & 1) ? v : -v;
    return FLV_OK;
}

static int flv_rbsp_skip_scaling_list(FLVRbsp *r, int size) {
    int last_scale = 8, next_scale = 8;
    for (int j = 0; j < size; j++) {
        if (next_scale != 0) {
            int32_t delta;
            if (flv_rbsp_se(r, &delta) != FLV_OK) return FLV_CORRUPT;
            next_scale = (last_scale + delta + 256) % 256;
        }
        last_scale = (next_scale == 0) ? last_scale : next_scale;
    }
    return FLV_OK;
}

int flv_h264_sps_dimensions(const uint8_t *sps_nalu, size_t sps_bytes,
                            uint32_t *width, uint32_t *height) {
    if (!sps_nalu || sps_bytes < 4) return FLV_CORRUPT;
    FLVRbsp r;
    if (flv_rbsp_init(&r, sps_nalu + 1, sps_bytes - 1) != FLV_OK) return FLV_CORRUPT;
    uint32_t profile_idc, constraint, level_idc, sps_id;
    if (flv_rbsp_u(&r, 8, &profile_idc) || flv_rbsp_u(&r, 8, &constraint) || flv_rbsp_u(&r, 8, &level_idc)) return FLV_CORRUPT;
    (void)constraint; (void)level_idc;
    if (flv_rbsp_ue(&r, &sps_id)) return FLV_CORRUPT;
    uint32_t chroma_format_idc = 1;
    uint32_t separate_colour_plane = 0;
    const int high_profiles[] = {100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135};
    int is_high = 0;
    for (size_t i = 0; i < FLV_ARRAY_COUNT(high_profiles); i++)
        if ((int)profile_idc == high_profiles[i]) is_high = 1;
    if (is_high) {
        if (flv_rbsp_ue(&r, &chroma_format_idc)) return FLV_CORRUPT;
        if (chroma_format_idc == 3) { if (flv_rbsp_u(&r, 1, &separate_colour_plane)) return FLV_CORRUPT; }
        uint32_t tmp;
        if (flv_rbsp_ue(&r, &tmp) || flv_rbsp_ue(&r, &tmp)) return FLV_CORRUPT; /* bit depths */
        uint32_t bypass, scaling_present;
        if (flv_rbsp_u(&r, 1, &bypass) || flv_rbsp_u(&r, 1, &scaling_present)) return FLV_CORRUPT;
        if (scaling_present) {
            uint32_t count = (chroma_format_idc != 3) ? 8 : 12;
            for (uint32_t i = 0; i < count; i++) {
                uint32_t present;
                if (flv_rbsp_u(&r, 1, &present)) return FLV_CORRUPT;
                if (present) {
                    int rc = flv_rbsp_skip_scaling_list(&r, i < 6 ? 16 : 64);
                    if (rc != FLV_OK) return rc;
                }
            }
        }
    }
    uint32_t log2_max_frame_num_minus4, poc_type;
    if (flv_rbsp_ue(&r, &log2_max_frame_num_minus4)) return FLV_CORRUPT;
    if (flv_rbsp_ue(&r, &poc_type)) return FLV_CORRUPT;
    if (poc_type == 0) {
        uint32_t t; if (flv_rbsp_ue(&r, &t)) return FLV_CORRUPT;
    } else if (poc_type == 1) {
        uint32_t t; int32_t st;
        if (flv_rbsp_u(&r, 1, &t) || flv_rbsp_se(&r, &st) || flv_rbsp_se(&r, &st)) return FLV_CORRUPT;
        if (flv_rbsp_ue(&r, &t)) return FLV_CORRUPT;
        for (uint32_t i = 0; i < t; i++) { if (flv_rbsp_se(&r, &st)) return FLV_CORRUPT; }
    }
    uint32_t max_ref, gaps, w_mbs, h_map, frame_only, direct8;
    if (flv_rbsp_ue(&r, &max_ref) || flv_rbsp_u(&r, 1, &gaps)) return FLV_CORRUPT;
    if (flv_rbsp_ue(&r, &w_mbs) || flv_rbsp_ue(&r, &h_map)) return FLV_CORRUPT;
    if (flv_rbsp_u(&r, 1, &frame_only)) return FLV_CORRUPT;
    if (!frame_only) { uint32_t t; if (flv_rbsp_u(&r, 1, &t)) return FLV_CORRUPT; }
    if (flv_rbsp_u(&r, 1, &direct8)) return FLV_CORRUPT;
    uint32_t cropping = 0, cl = 0, cr = 0, ct = 0, cb = 0;
    if (flv_rbsp_u(&r, 1, &cropping)) return FLV_CORRUPT;
    if (cropping) {
        if (flv_rbsp_ue(&r, &cl) || flv_rbsp_ue(&r, &cr) || flv_rbsp_ue(&r, &ct) || flv_rbsp_ue(&r, &cb)) return FLV_CORRUPT;
    }
    (void)max_ref; (void)gaps; (void)direct8;
    uint32_t chroma_array_type = separate_colour_plane ? 0 : chroma_format_idc;
    uint32_t sub_w_c = (chroma_array_type == 1 || chroma_array_type == 2) ? 2 : 1;
    uint32_t sub_h_c = (chroma_array_type == 1) ? 2 : 1;
    uint32_t crop_unit_x = sub_w_c;
    uint32_t crop_unit_y = sub_h_c * (2 - frame_only);
    uint32_t w = (w_mbs + 1) * 16;
    uint32_t h = (h_map + 1) * 16 * (2 - frame_only);
    if (w < crop_unit_x * (cl + cr) || h < crop_unit_y * (ct + cb)) return FLV_CORRUPT;
    *width = w - crop_unit_x * (cl + cr);
    *height = h - crop_unit_y * (ct + cb);
    return FLV_OK;
}

int flv_hevc_sps_dimensions(const uint8_t *sps_nalu, size_t sps_bytes,
                            uint32_t *width, uint32_t *height) {
    if (!sps_nalu || sps_bytes < 4) return FLV_CORRUPT;
    FLVRbsp r;
    if (flv_rbsp_init(&r, sps_nalu + 2, sps_bytes - 2) != FLV_OK) return FLV_CORRUPT;
    uint32_t vps_id, max_sub_layers_minus1, nesting;
    if (flv_rbsp_u(&r, 4, &vps_id) || flv_rbsp_u(&r, 3, &max_sub_layers_minus1) || flv_rbsp_u(&r, 1, &nesting)) return FLV_CORRUPT;
    (void)vps_id; (void)nesting;
    if (max_sub_layers_minus1 > 6) return FLV_CORRUPT;
    /* profile_tier_level(general, max_sub_layers_minus1): general part is
     * exactly 96 bits (12 bytes); each present sub-layer adds 88 or 8 bits. */
    {
        uint32_t t;
        if (flv_rbsp_u(&r, 96 - 88, &t)) return FLV_CORRUPT; /* 2+1+5: space/tier/profile */
        for (int i = 0; i < 88; i += 8) { if (flv_rbsp_u(&r, 8, &t)) return FLV_CORRUPT; } /* 32 compat + 4 flags + 44 reserved + 8 level */
        uint32_t sub_profile[7] = {0}, sub_level[7] = {0};
        for (uint32_t i = 0; i < max_sub_layers_minus1; i++) {
            if (flv_rbsp_u(&r, 1, &sub_profile[i]) || flv_rbsp_u(&r, 1, &sub_level[i])) return FLV_CORRUPT;
        }
        if (max_sub_layers_minus1 > 0) {
            for (uint32_t i = max_sub_layers_minus1; i < 8; i++) { if (flv_rbsp_u(&r, 2, &t)) return FLV_CORRUPT; }
        }
        for (uint32_t i = 0; i < max_sub_layers_minus1; i++) {
            if (sub_profile[i]) {
                if (flv_rbsp_u(&r, 8, &t)) return FLV_CORRUPT;            /* space/tier/profile */
                for (int k = 0; k < 80; k += 8) { if (flv_rbsp_u(&r, 8, &t)) return FLV_CORRUPT; } /* compat+flags+reserved */
            }
            if (sub_level[i]) { if (flv_rbsp_u(&r, 8, &t)) return FLV_CORRUPT; }
        }
    }
    uint32_t sps_id, chroma_format_idc = 1, separate = 0;
    if (flv_rbsp_ue(&r, &sps_id)) return FLV_CORRUPT;
    if (flv_rbsp_ue(&r, &chroma_format_idc)) return FLV_CORRUPT;
    if (chroma_format_idc == 3) { if (flv_rbsp_u(&r, 1, &separate)) return FLV_CORRUPT; }
    (void)separate;
    uint32_t pic_w, pic_h, conf_flag;
    if (flv_rbsp_ue(&r, &pic_w) || flv_rbsp_ue(&r, &pic_h)) return FLV_CORRUPT;
    if (flv_rbsp_u(&r, 1, &conf_flag)) return FLV_CORRUPT;
    uint32_t cl = 0, cr = 0, ct = 0, cb = 0;
    if (conf_flag) {
        if (flv_rbsp_ue(&r, &cl) || flv_rbsp_ue(&r, &cr) || flv_rbsp_ue(&r, &ct) || flv_rbsp_ue(&r, &cb)) return FLV_CORRUPT;
    }
    uint32_t sub_w_c = (chroma_format_idc == 1 || chroma_format_idc == 2) ? 2 : 1;
    uint32_t sub_h_c = (chroma_format_idc == 1) ? 2 : 1;
    if (pic_w < sub_w_c * (cl + cr) || pic_h < sub_h_c * (ct + cb)) return FLV_CORRUPT;
    *width = pic_w - sub_w_c * (cl + cr);
    *height = pic_h - sub_h_c * (ct + cb);
    return FLV_OK;
}

/* ---- vpcC (VP9 codec configuration as VideoToolbox consumes it) ----
 *
 * Layout per FFmpeg n7.1.5 libavcodec/videotoolbox_vp9.c
 * (ff_videotoolbox_vpcc_extradata_create), 12 bytes:
 *   u8 version (1), u24 flags (0), u8 profile, u8 level (0 = Undefined),
 *   u8 (bit_depth << 4) | (chroma_subsampling << 1) | full_range,
 *   u8 colour_primaries, u8 transfer_characteristics, u8 matrix_coefficients,
 *   u16 codec_initialization_data_size (0, big-endian).
 * Width/height are carried by the CMFormatDescription, not the record; the
 * previous 11-byte layout packed dimensions into the record and was rejected
 * by VT session creation. Colour fields must be verified stream metadata or
 * the explicit "unspecified" (2) value — never invented. */

int flv_vpcc_build(uint8_t profile, uint8_t level, uint8_t bit_depth,
                   uint8_t chroma_subsampling, uint8_t full_range,
                   uint8_t colour_primaries, uint8_t transfer_characteristics,
                   uint8_t matrix_coefficients,
                   uint8_t *dst, size_t cap, size_t *out_bytes) {
    if (cap < 12) return FLV_LIMIT;
    dst[0] = 1;  /* version */
    dst[1] = 0; dst[2] = 0; dst[3] = 0;  /* flags */
    dst[4] = profile;
    dst[5] = level; /* 0 = Undefined */
    dst[6] = (uint8_t)(((bit_depth & 0x0F) << 4) |
                       ((chroma_subsampling & 0x07) << 1) | (full_range & 1));
    dst[7] = colour_primaries;
    dst[8] = transfer_characteristics;
    dst[9] = matrix_coefficients;
    dst[10] = 0; dst[11] = 0; /* codec_initialization_data_size, big-endian */
    *out_bytes = 12;
    return FLV_OK;
}

/* ---- av1C (ISOBMFF AV1 codec configuration, no config OBUs) ---- */

int flv_av1c_build(uint8_t profile, uint8_t level_idx, uint8_t high_bitdepth,
                   uint8_t twelve_bit, uint8_t *dst, size_t cap, size_t *out_bytes) {
    if (cap < 4) return FLV_LIMIT;
    dst[0] = 0x81; /* marker=1, version=1 */
    dst[1] = (uint8_t)(((profile & 0x07) << 5) | (level_idx & 0x1F));
    dst[2] = (uint8_t)(((high_bitdepth & 1) << 6) | ((twelve_bit & 1) << 5) |
                       (1 << 3) | (1 << 2)); /* 4:2:0, position 0 */
    dst[3] = 0; /* no initial presentation delay */
    *out_bytes = 4;
    return FLV_OK;
}
