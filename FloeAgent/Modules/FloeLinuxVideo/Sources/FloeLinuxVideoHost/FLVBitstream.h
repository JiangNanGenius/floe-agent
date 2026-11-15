/* SPDX-License-Identifier: MPL-2.0 */
/*
 * Coded-bitstream helpers: Annex B <-> length-prefixed NAL unit access
 * units, plus avcC / hvcC / vpcC / av1C configuration-record parsing and
 * construction. All pure C; no VideoToolbox types. Every function is
 * bounds-checked and reports corrupt input with FLV_CORRUPT.
 */
#ifndef FLV_BITSTREAM_H
#define FLV_BITSTREAM_H

#include "FLVInternal.h"

#define FLV_MAX_PARAM_SETS 8u

typedef struct {
    const uint8_t *data; /* points into caller buffer, not retained */
    size_t bytes;
    uint8_t nal_type;
} FLVNalu;

typedef struct {
    uint8_t sps[FLV_MAX_PARAM_SETS][512]; uint32_t sps_len[FLV_MAX_PARAM_SETS]; uint32_t sps_count;
    uint8_t pps[FLV_MAX_PARAM_SETS][512]; uint32_t pps_len[FLV_MAX_PARAM_SETS]; uint32_t pps_count;
    uint8_t vps[FLV_MAX_PARAM_SETS][512]; uint32_t vps_len[FLV_MAX_PARAM_SETS]; uint32_t vps_count;
    uint32_t length_size; /* 1..4, from avcC/hvcC */
} FLVParamSets;

/* Locate the next Annex B start code at or after *cursor; *cursor is advanced
 * past it. Returns pointer to NALU payload start or NULL at end. */
const uint8_t *flv_annexb_next_nalu(const uint8_t **cursor, const uint8_t *end,
                                    size_t *nalu_bytes, uint8_t *nal_trailing_zero_count);

/* Split a whole access unit into NALUs (zero-copy). Returns count (may be 0). */
size_t flv_annexb_split(const uint8_t *data, size_t bytes,
                        FLVNalu *out, size_t capacity);

/* Required dst capacity for Annex B -> length-prefixed conversion. */
size_t flv_annexb_to_lenpref_size(const uint8_t *src, size_t src_bytes);
int flv_annexb_to_lenpref(const uint8_t *src, size_t src_bytes,
                          uint8_t *dst, size_t dst_capacity, size_t *out_bytes);

/* Length-prefixed -> Annex B. Same NALU count; start codes replace length
 * fields 1:1. When inject_param_sets && is_key, SPS/PPS(/VPS) are emitted
 * (with start codes) before the first VCL NALU. */
int flv_lenpref_to_annexb(const uint8_t *src, size_t src_bytes,
                          uint32_t codec, const FLVParamSets *ps,
                          int is_key, int inject_param_sets,
                          uint8_t *dst, size_t dst_capacity, size_t *out_bytes);
size_t flv_lenpref_to_annexb_size(const uint8_t *src, size_t src_bytes,
                                  uint32_t codec, const FLVParamSets *ps,
                                  int is_key, int inject_param_sets);

/* avcC / hvcC parse (copies parameter sets) and build. */
int flv_avcc_parse(const uint8_t *cfg, size_t bytes, FLVParamSets *ps);
int flv_avcc_build(const FLVParamSets *ps, uint8_t *dst, size_t cap, size_t *out_bytes);
int flv_hvcc_parse(const uint8_t *cfg, size_t bytes, FLVParamSets *ps);
int flv_hvcc_build(const FLVParamSets *ps, uint8_t *dst, size_t cap, size_t *out_bytes);

/* vpcC construction for VideoToolbox: the 12-byte layout FFmpeg's
 * videotoolbox_vp9.c builds (version 1, 3 flag bytes, profile, level,
 * packed bit-depth/chroma/range byte, three colour bytes, 16-bit zero
 * initialization size). Coded dimensions are NOT part of vpcC; they live in
 * the CMFormatDescription. level 0 means Undefined: pass verified metadata
 * or explicit unknowns (colour 2 = unspecified), never invented limits. */
int flv_vpcc_build(uint8_t profile, uint8_t level, uint8_t bit_depth,
                   uint8_t chroma_subsampling, uint8_t full_range,
                   uint8_t colour_primaries, uint8_t transfer_characteristics,
                   uint8_t matrix_coefficients,
                   uint8_t *dst, size_t cap, size_t *out_bytes);
int flv_av1c_build(uint8_t profile, uint8_t level_idx, uint8_t high_bitdepth,
                   uint8_t twelve_bit, uint8_t *dst, size_t cap, size_t *out_bytes);

/* Extract the first SPS/PPS(/VPS) found in an Annex B access unit. */
int flv_annexb_extract_param_sets(const uint8_t *data, size_t bytes,
                                  uint32_t codec, FLVParamSets *ps);

uint8_t flv_h264_nal_type(const FLVNalu *n);
uint8_t flv_hevc_nal_type(const FLVNalu *n);
int flv_nal_is_vcl(uint32_t codec, uint8_t nal_type);

/* Derive coded dimensions from an H.264 or HEVC SPS NAL unit (header byte
 * included). Used to configure Annex-B decode sessions created with
 * width/height 0. Returns FLV_CORRUPT on malformed SPS. */
int flv_h264_sps_dimensions(const uint8_t *sps_nalu, size_t sps_bytes,
                            uint32_t *width, uint32_t *height);
int flv_hevc_sps_dimensions(const uint8_t *sps_nalu, size_t sps_bytes,
                            uint32_t *width, uint32_t *height);

#endif /* FLV_BITSTREAM_H */
