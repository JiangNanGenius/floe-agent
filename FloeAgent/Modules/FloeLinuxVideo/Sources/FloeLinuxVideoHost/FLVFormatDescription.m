/* SPDX-License-Identifier: MPL-2.0 */
#import "FLVFormatDescription.h"

int flv_create_format_description_from_param_sets(uint32_t codec,
                                                  const FLVParamSets *ps,
                                                  CMFormatDescriptionRef *out) {
    if (!ps || !out) return FLV_INVALID;
    OSStatus err = noErr;
    /* Both public APIs take ONE combined parameter-set array. */
    if (codec == FLV_H264) {
        if (ps->sps_count < 1 || ps->pps_count < 1) return FLV_CORRUPT;
        const uint8_t *ptrs[2 * FLV_MAX_PARAM_SETS]; size_t sizes[2 * FLV_MAX_PARAM_SETS];
        size_t n = 0;
        for (uint32_t i = 0; i < ps->sps_count && n < FLV_ARRAY_COUNT(ptrs); i++) { ptrs[n] = ps->sps[i]; sizes[n] = ps->sps_len[i]; n++; }
        for (uint32_t i = 0; i < ps->pps_count && n < FLV_ARRAY_COUNT(ptrs); i++) { ptrs[n] = ps->pps[i]; sizes[n] = ps->pps_len[i]; n++; }
        err = CMVideoFormatDescriptionCreateFromH264ParameterSets(
            kCFAllocatorDefault, n, ptrs, sizes,
            ps->length_size ? (int)ps->length_size : 4, out);
    } else if (codec == FLV_HEVC) {
        if (ps->sps_count < 1 || ps->pps_count < 1) return FLV_CORRUPT;
        const uint8_t *ptrs[3 * FLV_MAX_PARAM_SETS]; size_t sizes[3 * FLV_MAX_PARAM_SETS];
        size_t n = 0;
        for (uint32_t i = 0; i < ps->vps_count && n < FLV_ARRAY_COUNT(ptrs); i++) { ptrs[n] = ps->vps[i]; sizes[n] = ps->vps_len[i]; n++; }
        for (uint32_t i = 0; i < ps->sps_count && n < FLV_ARRAY_COUNT(ptrs); i++) { ptrs[n] = ps->sps[i]; sizes[n] = ps->sps_len[i]; n++; }
        for (uint32_t i = 0; i < ps->pps_count && n < FLV_ARRAY_COUNT(ptrs); i++) { ptrs[n] = ps->pps[i]; sizes[n] = ps->pps_len[i]; n++; }
        err = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
            kCFAllocatorDefault, n, ptrs, sizes,
            ps->length_size ? (int)ps->length_size : 4, NULL, out);
    } else {
        return FLV_UNSUPPORTED;
    }
    if (err != noErr) return FLV_UNSUPPORTED;
    return FLV_OK;
}

int flv_create_format_description(uint32_t codec,
                                  const uint8_t *codec_config, size_t codec_config_bytes,
                                  uint32_t width, uint32_t height,
                                  CMFormatDescriptionRef *out) {
    if (!out) return FLV_INVALID;
    *out = NULL;
    CMVideoCodecType cmType = 0;
    switch (codec) {
        case FLV_H264: cmType = kCMVideoCodecType_H264; break;
        case FLV_HEVC: cmType = kCMVideoCodecType_HEVC; break;
        case FLV_VP9: cmType = kCMVideoCodecType_VP9; break;
        case FLV_AV1: cmType = kCMVideoCodecType_AV1; break;
        case FLV_MJPEG: cmType = kCMVideoCodecType_JPEG; break;
        case FLV_MPEG2: cmType = kCMVideoCodecType_MPEG2Video; break;
        case FLV_MPEG4: cmType = kCMVideoCodecType_MPEG4Video; break;
        case FLV_PRORES422: cmType = kCMVideoCodecType_AppleProRes422; break;
        case FLV_PRORES4444: cmType = kCMVideoCodecType_AppleProRes4444; break;
        case FLV_H263: cmType = kCMVideoCodecType_H263; break;
        /* No public VP8 fourcc constant; unreachable (descriptor has no paths). */
        default: return FLV_UNSUPPORTED;
    }
    OSStatus err = noErr;
    if (codec == FLV_H264 || codec == FLV_HEVC) {
        if (!codec_config || codec_config_bytes == 0) return FLV_INVALID;
        FLVParamSets ps;
        int rc = (codec == FLV_H264) ? flv_avcc_parse(codec_config, codec_config_bytes, &ps)
                                     : flv_hvcc_parse(codec_config, codec_config_bytes, &ps);
        if (rc != FLV_OK) return rc;
        return flv_create_format_description_from_param_sets(codec, &ps, out);
    }
    /* codecs that carry their configuration in-band or in a record atom */
    CFMutableDictionaryRef atoms = NULL;
    uint8_t built[64]; size_t built_len = 0;
    if (codec_config && codec_config_bytes > 0) {
        atoms = CFDictionaryCreateMutable(kCFAllocatorDefault, 1,
                                          &kCFTypeDictionaryKeyCallBacks,
                                          &kCFTypeDictionaryValueCallBacks);
        CFDataRef data = CFDataCreate(kCFAllocatorDefault, codec_config, (CFIndex)codec_config_bytes);
        if (codec == FLV_VP9) CFDictionarySetValue(atoms, CFSTR("vpcC"), data);
        else if (codec == FLV_AV1) CFDictionarySetValue(atoms, CFSTR("av1C"), data);
        CFRelease(data);
    } else if (codec == FLV_VP9) {
        /* No caller record: build the 12-byte VT vpcC with explicit
         * unknowns (level Undefined, colour unspecified); width/height are
         * the format-description dims, never packed into the record. */
        int rc = flv_vpcc_build(0, 0, 8, 1, 0, 2, 2, 2,
                                built, sizeof(built), &built_len);
        if (rc == FLV_OK) {
            atoms = CFDictionaryCreateMutable(kCFAllocatorDefault, 1,
                                              &kCFTypeDictionaryKeyCallBacks,
                                              &kCFTypeDictionaryValueCallBacks);
            CFDataRef data = CFDataCreate(kCFAllocatorDefault, built, (CFIndex)built_len);
            CFDictionarySetValue(atoms, CFSTR("vpcC"), data);
            CFRelease(data);
        }
    } else if (codec == FLV_AV1) {
        int rc = flv_av1c_build(0, 10, 0, 0, built, sizeof(built), &built_len);
        if (rc == FLV_OK) {
            atoms = CFDictionaryCreateMutable(kCFAllocatorDefault, 1,
                                              &kCFTypeDictionaryKeyCallBacks,
                                              &kCFTypeDictionaryValueCallBacks);
            CFDataRef data = CFDataCreate(kCFAllocatorDefault, built, (CFIndex)built_len);
            CFDictionarySetValue(atoms, CFSTR("av1C"), data);
            CFRelease(data);
        }
    }
    if (atoms) {
        CFTypeRef keys[1]; CFTypeRef vals[1];
        keys[0] = kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms;
        vals[0] = atoms;
        CFDictionaryRef ext = CFDictionaryCreate(kCFAllocatorDefault, keys, vals, 1,
                                                 &kCFTypeDictionaryKeyCallBacks,
                                                 &kCFTypeDictionaryValueCallBacks);
        err = CMVideoFormatDescriptionCreate(kCFAllocatorDefault, cmType,
                                             (int32_t)width, (int32_t)height, ext, out);
        CFRelease(ext);
        CFRelease(atoms);
    } else {
        err = CMVideoFormatDescriptionCreate(kCFAllocatorDefault, cmType,
                                             (int32_t)width, (int32_t)height, NULL, out);
    }
    if (err != noErr) return FLV_UNSUPPORTED;
    return FLV_OK;
}
