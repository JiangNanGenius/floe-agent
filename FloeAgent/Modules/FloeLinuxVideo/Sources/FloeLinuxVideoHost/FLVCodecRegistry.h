/* SPDX-License-Identifier: MPL-2.0 */
/*
 * Codec descriptor table and the truthful device probe.
 *
 * A codec/direction is only ever advertised with FLV_CAP_HW_REPORTED and
 * FLV_CAP_SESSION_PROBED after a real hardware-required VideoToolbox
 * session probe succeeded on this machine: an actual encode of a frame
 * (readback of kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder)
 * or an actual decode of a real coded frame (creation under
 * kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder plus
 * readback of kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder).
 * Software fallbacks are never counted.
 */
#ifndef FLV_CODEC_REGISTRY_H
#define FLV_CODEC_REGISTRY_H

#import "FLVInternal.h"
#include "FLVBitstream.h"

typedef struct {
    uint32_t codec;
    uint32_t cm_codec_type;   /* CMVideoCodecType fourcc, 0 if none */
    const char *name;
    uint8_t encode_path;      /* real, generic VT encode path exists */
    uint8_t decode_path;      /* real, generic VT decode path exists */
    uint16_t native_pixel_mask; /* pixel formats the data plane copies natively */
} FLVCodecDescriptor;

extern const FLVCodecDescriptor flv_codecs[];
extern const size_t flv_codecs_count;

const FLVCodecDescriptor *flv_codec_descriptor(uint32_t codec);

/* Native software availability: FLV_CAP_NATIVE_SOFTWARE_PROBED is defined by
 * the public header (additive enum value 8). A slot carrying it always also
 * carries FLV_CAP_IMPLEMENTED (2) and never carries 1 or 4: it means "no
 * hardware path was proven on this machine, but a real software
 * encode/decode of real data succeeded and the session reported software
 * (UsingHardware readback false)". It must never satisfy an
 * FLV_REQUIRE_HARDWARE session request or count as hardware use, and old
 * hardware-only consumers filtering flags 1|4 keep strict behavior. */

/* Register supplemental decoders (VP9/AV1) once per process. */
void flv_codec_ensure_supplemental_decoders(void);

/* Fill all FLV_CAPABILITY slots (all 11 codecs x 2 directions = 22).
 * cap==NULL or capacity==0 returns the required count. Probes run once
 * per process and are cached.
 *
 * Flag semantics per slot:
 *  - hardware probe succeeded: IMPLEMENTED|HW_REPORTED|SESSION_PROBED (7),
 *    probe_status FLV_OK, dims from hardware-required session probes;
 *  - hardware probe failed but a real software session encode/decode of the
 *    shipped coded data succeeded with UsingHardware readback false:
 *    IMPLEMENTED|NATIVE_SOFTWARE_PROBED (10), probe_status FLV_OK, dims only
 *    from the measured software probe (never a hardware-probe number);
 *  - otherwise: IMPLEMENTED (2) when a generic VT path exists with the real
 *    failure status, or flags 0 when no public VT path exists (VP8). */
int flv_codec_fill_capabilities(FLVCapability *entries, size_t capacity,
                                size_t *required_count);

#endif /* FLV_CODEC_REGISTRY_H */
