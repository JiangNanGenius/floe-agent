/* SPDX-License-Identifier: MPL-2.0 */
#import "FLVCodecRegistry.h"
#import "FLVFormatDescription.h"
#import "FLVProbeSamples.h"
#import "FLVImageIOFallback.h"
#include <pthread.h>

/* Constant expressions: this table is a global initializer, so the values
 * must be compile-time constants (an inline function call is not). */
#define FLV_MASK_NV12 (1u << FLV_NV12)
#define FLV_MASK_P010 (1u << FLV_P010)

const FLVCodecDescriptor flv_codecs[] = {
    /* codec,            cm fourcc,                          name,             enc, dec, native pixels */
    { FLV_H264,          kCMVideoCodecType_H264,             "H.264",          1,   1,   FLV_MASK_NV12 | FLV_MASK_P010 },
    { FLV_HEVC,          kCMVideoCodecType_HEVC,             "HEVC",           1,   1,   FLV_MASK_NV12 | FLV_MASK_P010 },
    { FLV_VP9,           kCMVideoCodecType_VP9,              "VP9",            0,   1,   FLV_MASK_NV12 | FLV_MASK_P010 },
    { FLV_AV1,           kCMVideoCodecType_AV1,              "AV1",            0,   1,   FLV_MASK_NV12 | FLV_MASK_P010 },
    { FLV_MJPEG,         kCMVideoCodecType_JPEG,             "MJPEG",          1,   1,   FLV_MASK_NV12 },
    { FLV_MPEG2,         kCMVideoCodecType_MPEG2Video,       "MPEG-2 Video",   0,   1,   FLV_MASK_NV12 },
    { FLV_MPEG4,         kCMVideoCodecType_MPEG4Video,       "MPEG-4 Part 2",  1,   1,   FLV_MASK_NV12 },
    { FLV_PRORES422,     kCMVideoCodecType_AppleProRes422,   "ProRes 422",     1,   1,   FLV_MASK_NV12 | FLV_MASK_P010 },
    { FLV_PRORES4444,    kCMVideoCodecType_AppleProRes4444,  "ProRes 4444",    1,   1,   FLV_MASK_NV12 | FLV_MASK_P010 },
    { FLV_H263,          kCMVideoCodecType_H263,             "H.263",          0,   1,   FLV_MASK_NV12 },
    /* VP8 has no public VideoToolbox path on any Apple platform; the table
     * records it with no paths so it is never advertised. No public
     * kCMVideoCodecType_VP8 constant exists in the SDK, so the fourcc is 0
     * (never used: both paths are 0). */
    { FLV_VP8,           0,                                  "VP8",            0,   0,   0 },
};
const size_t flv_codecs_count = FLV_ARRAY_COUNT(flv_codecs);

const FLVCodecDescriptor *flv_codec_descriptor(uint32_t codec) {
    for (size_t i = 0; i < flv_codecs_count; i++) {
        if (flv_codecs[i].codec == codec) return &flv_codecs[i];
    }
    return NULL;
}

static const FLVProbeSample *flv_find_probe_sample(uint32_t codec) {
    for (size_t i = 0; i < flv_probe_samples_count; i++) {
        if (flv_probe_samples[i].codec == codec) return &flv_probe_samples[i];
    }
    return NULL;
}

/* ---- probe primitives ---- */

typedef struct {
    dispatch_semaphore_t sem;
    OSStatus status;
    int32_t frames;
    int32_t dropped;
} FLVProbeCB;

static void flv_probe_encode_cb(void *refcon, void *srcFrameRefCon, OSStatus status,
                                VTEncodeInfoFlags infoFlags, CMSampleBufferRef sampleBuffer) {
    @autoreleasepool {
        (void)srcFrameRefCon;
        FLVProbeCB *cb = (FLVProbeCB *)refcon;
        if (status != noErr) cb->status = status;
        if (infoFlags & kVTEncodeInfo_FrameDropped) cb->dropped++;
        else if (sampleBuffer) cb->frames++;
        dispatch_semaphore_signal(cb->sem);
    }
}

static void flv_probe_decode_cb(void *refcon, void *srcFrameRefCon, OSStatus status,
                                VTDecodeInfoFlags infoFlags, CVImageBufferRef imageBuffer,
                                CMTime presentationTimeStamp, CMTime presentationDuration) {
    @autoreleasepool {
        (void)srcFrameRefCon; (void)infoFlags;
        (void)presentationTimeStamp; (void)presentationDuration;
        FLVProbeCB *cb = (FLVProbeCB *)refcon;
        if (status != noErr) cb->status = status;
        if (imageBuffer) cb->frames++;
        dispatch_semaphore_signal(cb->sem);
    }
}

static CVPixelBufferRef flv_make_solid_frame(uint32_t width, uint32_t height, OSType fmt) {
    NSDictionary *attrs = @{
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferPixelFormatTypeKey: @(fmt),
        (id)kCVPixelBufferWidthKey: @(width),
        (id)kCVPixelBufferHeightKey: @(height),
    };
    CVPixelBufferRef pb = NULL;
    CVReturn cr = CVPixelBufferCreate(kCFAllocatorDefault, width, height, fmt,
                                      (__bridge CFDictionaryRef)attrs, &pb);
    if (cr != kCVReturnSuccess || !pb) return NULL;
    if (CVPixelBufferLockBaseAddress(pb, 0) != kCVReturnSuccess) { CFRelease(pb); return NULL; }
    if (fmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
        fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
        size_t ys = CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
        size_t cs = CVPixelBufferGetBytesPerRowOfPlane(pb, 1);
        uint8_t *y = CVPixelBufferGetBaseAddressOfPlane(pb, 0);
        uint8_t *c = CVPixelBufferGetBaseAddressOfPlane(pb, 1);
        for (uint32_t r = 0; r < height; r++) memset(y + r * ys, 16, width);
        for (uint32_t r = 0; r < height / 2; r++) memset(c + r * cs, 128, width);
    } else if (fmt == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange) {
        size_t ys = CVPixelBufferGetBytesPerRowOfPlane(pb, 0);
        size_t cs = CVPixelBufferGetBytesPerRowOfPlane(pb, 1);
        uint16_t *y = (uint16_t *)CVPixelBufferGetBaseAddressOfPlane(pb, 0);
        uint16_t *c = (uint16_t *)CVPixelBufferGetBaseAddressOfPlane(pb, 1);
        for (uint32_t r = 0; r < height; r++)
            for (uint32_t x = 0; x < width; x++) y[(r * ys) / 2 + x] = 16 << 6;
        for (uint32_t r = 0; r < height / 2; r++)
            for (uint32_t x = 0; x < width; x++) c[(r * cs) / 2 + x] = 512 << 6;
    }
    CVPixelBufferUnlockBaseAddress(pb, 0);
    return pb;
}

/* Strict hardware-required encode of one real frame. Returns FLV_OK only
 * when the frame completed and the encoder reported hardware acceleration. */
static int flv_probe_encode(uint32_t codec, const FLVCodecDescriptor *d, int try_p010, int *hw_used) {
    *hw_used = 0;
    const uint32_t w = 640, h = 360;
    OSType fmt = try_p010 ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                          : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    CVPixelBufferRef pb = flv_make_solid_frame(w, h, fmt);
    if (!pb) return FLV_INTERNAL;
    NSDictionary *srcAttrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(fmt),
        (id)kCVPixelBufferWidthKey: @(w),
        (id)kCVPixelBufferHeightKey: @(h),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    FLVProbeCB cb = { dispatch_semaphore_create(0), noErr, 0, 0 };
    /* Hardware requirement is a session-creation specification; there is no
     * public kVTCompressionPropertyKey_RequireHardware property. */
    NSDictionary *spec = @{
        (id)kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: @YES,
    };
    VTCompressionSessionRef s = NULL;
    OSStatus err = VTCompressionSessionCreate(NULL, (int32_t)w, (int32_t)h, d->cm_codec_type,
                                              (__bridge CFDictionaryRef)spec,
                                              (__bridge CFDictionaryRef)srcAttrs,
                                              NULL, flv_probe_encode_cb, &cb, &s);
    if (err != noErr) { CFRelease(pb); return FLV_UNSUPPORTED; }
    VTSessionSetProperty((VTSessionRef)s, kVTCompressionPropertyKey_AverageBitRate, (__bridge CFTypeRef)@1000000);
    VTSessionSetProperty((VTSessionRef)s, kVTCompressionPropertyKey_ExpectedFrameRate, (__bridge CFTypeRef)@30);
    VTSessionSetProperty((VTSessionRef)s, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, (__bridge CFTypeRef)@(2.0));
    VTEncodeInfoFlags infoFlags = 0;
    err = VTCompressionSessionEncodeFrame(s, pb, kCMTimeInvalid, kCMTimeInvalid, NULL, NULL, &infoFlags);
    int rc;
    if (err != noErr) {
        rc = FLV_UNSUPPORTED;
    } else if (dispatch_semaphore_wait(cb.sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) != 0) {
        rc = FLV_INTERNAL;
    } else if (cb.status != noErr || cb.frames < 1) {
        rc = FLV_UNSUPPORTED;
    } else {
        CFTypeRef hw = NULL;
        if (VTSessionCopyProperty((VTSessionRef)s, kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                                  kCFAllocatorDefault, &hw) == noErr && hw) {
            *hw_used = (CFBooleanGetValue((CFBooleanRef)hw) != 0);
            CFRelease(hw);
        }
        rc = *hw_used ? FLV_OK : FLV_UNSUPPORTED;
    }
    VTCompressionSessionInvalidate(s);
    CFRelease(s);
    CFRelease(pb);
    return rc;
}

/* Native software encode of one real frame: session created WITHOUT the
 * hardware-required specification. Returns FLV_OK only when the frame
 * completed AND the encoder reported UsingHardware == false, i.e. a real
 * software encode happened on this machine. A hardware-assisted result is
 * not a software proof (the hardware probe covers that case) and is
 * reported as FLV_UNSUPPORTED here. */
static int flv_probe_encode_software(uint32_t codec, const FLVCodecDescriptor *d, int *hw_seen) {
    *hw_seen = -1; /* Unknown must not become a software capability. */
    const uint32_t w = 640, h = 360;
    OSType fmt = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    CVPixelBufferRef pb = flv_make_solid_frame(w, h, fmt);
    if (!pb) return FLV_INTERNAL;
    NSDictionary *srcAttrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(fmt),
        (id)kCVPixelBufferWidthKey: @(w),
        (id)kCVPixelBufferHeightKey: @(h),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    FLVProbeCB cb = { dispatch_semaphore_create(0), noErr, 0, 0 };
    VTCompressionSessionRef s = NULL;
    OSStatus err = VTCompressionSessionCreate(NULL, (int32_t)w, (int32_t)h, d->cm_codec_type,
                                              NULL, /* no encoder specification: VT may pick
                                                     * hardware; the readback below decides
                                                     * whether software really ran. */
                                              (__bridge CFDictionaryRef)srcAttrs,
                                              NULL, flv_probe_encode_cb, &cb, &s);
    if (err != noErr) { CFRelease(pb); return FLV_UNSUPPORTED; }
    VTSessionSetProperty((VTSessionRef)s, kVTCompressionPropertyKey_AverageBitRate, (__bridge CFTypeRef)@1000000);
    VTSessionSetProperty((VTSessionRef)s, kVTCompressionPropertyKey_ExpectedFrameRate, (__bridge CFTypeRef)@30);
    VTSessionSetProperty((VTSessionRef)s, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, (__bridge CFTypeRef)@(2.0));
    err = VTCompressionSessionPrepareToEncodeFrames(s);
    int rc;
    if (err != noErr) {
        rc = FLV_UNSUPPORTED;
    } else {
        VTEncodeInfoFlags infoFlags = 0;
        err = VTCompressionSessionEncodeFrame(s, pb, kCMTimeZero, CMTimeMake(1, 30), NULL, NULL, &infoFlags);
        if (err == noErr) err = VTCompressionSessionCompleteFrames(s, kCMTimeInvalid);
        if (err != noErr) {
            rc = FLV_UNSUPPORTED;
        } else if (dispatch_semaphore_wait(cb.sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) != 0) {
            rc = FLV_INTERNAL;
        } else if (cb.status != noErr || cb.frames < 1) {
            rc = FLV_UNSUPPORTED;
        } else {
            CFTypeRef hw = NULL;
            if (VTSessionCopyProperty((VTSessionRef)s, kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                                      kCFAllocatorDefault, &hw) == noErr && hw &&
                CFGetTypeID(hw) == CFBooleanGetTypeID()) {
                *hw_seen = (CFBooleanGetValue((CFBooleanRef)hw) != 0);
            }
            if (hw) CFRelease(hw);
            /* Software availability is only proven when software did the work. */
            rc = *hw_seen == 0 ? FLV_OK : FLV_UNSUPPORTED;
        }
    }
    VTCompressionSessionInvalidate(s);
    CFRelease(s);
    CFRelease(pb);
    (void)codec;
    return rc;
}

/* Register supplemental decoders once per process (public API; required for
 * VP9/AV1 hardware decode availability on macOS). */
void flv_codec_ensure_supplemental_decoders(void) {
    static pthread_mutex_t m = PTHREAD_MUTEX_INITIALIZER;
    static int done = 0;
    pthread_mutex_lock(&m);
    if (!done) {
        if (@available(macOS 11.0, iOS 26.2, tvOS 26.2, visionOS 26.2, *)) {
            VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9);
            VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_AV1);
        }
        done = 1;
    }
    pthread_mutex_unlock(&m);
}

/* Decode of one real coded frame. require_hardware=1 is the strict probe:
 * creation must succeed under RequireHardware and the session must report
 * UsingHardware == true. require_hardware=0 is the native software probe:
 * creation leaves the choice to VT (hardware still enabled, not required)
 * and the caller decides from the readback whether software really ran. */
static int flv_probe_decode_internal(uint32_t codec, const FLVCodecDescriptor *d,
                                     const FLVProbeSample *sample,
                                     int require_hardware, int *hw_used) {
    *hw_used = -1; /* No property readback is an unproven backend. */
    CMFormatDescriptionRef fmt = NULL;
    int rc = flv_create_format_description(codec, sample->config, sample->config_bytes,
                                           sample->width, sample->height, &fmt);
    if (rc != FLV_OK) return rc;
    NSMutableDictionary *spec = [@{
        (id)kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: @YES,
    } mutableCopy];
    if (require_hardware) {
        spec[(id)kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder] = @YES;
    }
    NSDictionary *attrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    FLVProbeCB cb = { dispatch_semaphore_create(0), noErr, 0, 0 };
    VTDecompressionSessionRef s = NULL;
    VTDecompressionOutputCallbackRecord cbRecord = { flv_probe_decode_cb, &cb };
    OSStatus err = VTDecompressionSessionCreate(NULL, fmt, (__bridge CFDictionaryRef)spec,
                                                (__bridge CFDictionaryRef)attrs,
                                                &cbRecord, &s);
    if (err != noErr) {
        CFRelease(fmt);
        return FLV_UNSUPPORTED;
    }
    /* The avcC/hvcC description declares length-prefixed samples: Annex-B
     * probe AUs must be repacked before decoding (the session submit path
     * does the same; the probe previously fed Annex-B bytes directly, which
     * decoded nothing and reported FLV_INTERNAL). */
    const uint8_t *feed_data = sample->frame;
    size_t feed_bytes = sample->frame_bytes;
    uint8_t *converted = NULL;
    if (codec == FLV_H264 || codec == FLV_HEVC) {
        size_t cap = flv_annexb_to_lenpref_size(sample->frame, sample->frame_bytes);
        if (cap) {
            converted = malloc(cap);
            if (converted && flv_annexb_to_lenpref(sample->frame, sample->frame_bytes,
                                                   converted, cap, &feed_bytes) == FLV_OK) {
                feed_data = converted;
            } else {
                free(converted);
                converted = NULL;
                feed_data = sample->frame;
                feed_bytes = sample->frame_bytes;
            }
        }
    }
    CMBlockBufferRef bb = NULL;
    CMSampleBufferRef sb = NULL;
    if (CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, (void *)feed_data,
                                           (CFIndex)feed_bytes, kCFAllocatorNull,
                                           NULL, 0, (CFIndex)feed_bytes, 0, &bb) == noErr) {
        CMSampleTimingInfo timing = { .duration = kCMTimeInvalid,
                                      .presentationTimeStamp = kCMTimeZero,
                                      .decodeTimeStamp = kCMTimeInvalid };
        size_t sizes[1] = { feed_bytes };
        CMSampleBufferCreate(kCFAllocatorDefault, bb, TRUE, NULL, NULL, fmt, 1, 1,
                             &timing, 1, sizes, &sb);
    }
    if (sb) {
        err = VTDecompressionSessionDecodeFrame(s, sb, 0, NULL, NULL);
        if (err == noErr) {
            VTDecompressionSessionWaitForAsynchronousFrames(s);
            dispatch_semaphore_wait(cb.sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
        }
    }
    if (cb.frames >= 1 && cb.status == noErr) {
        CFTypeRef hw = NULL;
        if (VTSessionCopyProperty((VTSessionRef)s, kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                                  kCFAllocatorDefault, &hw) == noErr && hw &&
            CFGetTypeID(hw) == CFBooleanGetTypeID()) {
            *hw_used = (CFBooleanGetValue((CFBooleanRef)hw) != 0);
        }
        if (hw) CFRelease(hw);
        /* Strict hardware probe fails when the session ran in software; the
         * permissive probe leaves the decision to the caller so a hardware
         * assist is never misreported as a software proof. */
        rc = (*hw_used < 0 || (require_hardware && *hw_used != 1)) ? FLV_UNSUPPORTED : FLV_OK;
    } else {
        rc = (sb && err != noErr) ? FLV_UNSUPPORTED : FLV_INTERNAL;
    }
    if (sb) CFRelease(sb);
    if (bb) CFRelease(bb);
    if (converted) free(converted);
    VTDecompressionSessionInvalidate(s);
    CFRelease(s);
    CFRelease(fmt);
    return rc;
}

/* Strict hardware-required decode of one real coded frame. */
static int flv_probe_decode(uint32_t codec, const FLVCodecDescriptor *d,
                            const FLVProbeSample *sample, int *hw_used) {
    return flv_probe_decode_internal(codec, d, sample, 1, hw_used);
}

/* Native software decode probe: same real coded data, no hardware
 * requirement. FLV_OK only when the frame decoded AND the session reports
 * UsingHardware == false — a hardware-assisted decode is not a software
 * availability proof and stays FLV_UNSUPPORTED here. */
static int flv_probe_decode_software(uint32_t codec, const FLVCodecDescriptor *d,
                                     const FLVProbeSample *sample, int *hw_used) {
    int rc = flv_probe_decode_internal(codec, d, sample, 0, hw_used);
    if (rc == FLV_OK && *hw_used != 0) rc = FLV_UNSUPPORTED;
    return rc;
}

/* Largest square dimension for which a hardware-required compression session
 * can be created and configured (no frames encoded). Encode direction. */
static int flv_probe_max_dimension_encode(const FLVCodecDescriptor *d, uint32_t *out_dim) {
    const uint32_t candidates[] = { 8192, 7680, 4096, 3840, 1920, 1280, 640 };
    for (size_t i = 0; i < FLV_ARRAY_COUNT(candidates); i++) {
        uint32_t dim = candidates[i];
        VTCompressionSessionRef s = NULL;
        NSDictionary *srcAttrs = @{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            (id)kCVPixelBufferWidthKey: @(dim),
            (id)kCVPixelBufferHeightKey: @(dim),
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        };
        NSDictionary *spec = @{
            (id)kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: @YES,
        };
        OSStatus err = VTCompressionSessionCreate(NULL, (int32_t)dim, (int32_t)dim, d->cm_codec_type,
                                                  (__bridge CFDictionaryRef)spec,
                                                  (__bridge CFDictionaryRef)srcAttrs,
                                                  NULL, NULL, NULL, &s);
        if (err != noErr) continue;
        /* Session creation with the hardware-required specification is the
         * probe; there is no public require-hardware property to set. */
        VTCompressionSessionInvalidate(s);
        CFRelease(s);
        *out_dim = dim; return FLV_OK;
    }
    *out_dim = 0;
    return FLV_UNSUPPORTED;
}

/* No-op decode callback for the max-dimension probe: no frames are ever
 * decoded there, so this must never deref its (NULL) refcon. */
static void flv_probe_maxdim_decode_cb(void *refcon, void *srcFrameRefCon, OSStatus status,
                                       VTDecodeInfoFlags infoFlags, CVImageBufferRef imageBuffer,
                                       CMTime presentationTimeStamp, CMTime presentationDuration) {
    (void)refcon; (void)srcFrameRefCon; (void)status; (void)infoFlags;
    (void)imageBuffer; (void)presentationTimeStamp; (void)presentationDuration;
}

/* Largest square dimension for which a hardware-required decompression
 * session can be created. Used for the decode direction — probing the
 * ENCODER for a decode-only codec (VP9/AV1/ProRes/...) would falsely report
 * "unknown" because no encoder exists at any size. Codecs whose format
 * description requires parameter sets (H264/HEVC) cannot be synthesized at
 * arbitrary sizes here; for those, fall back to the encoder probe when an
 * encode path exists. */
static int flv_probe_max_dimension_decode(uint32_t codec, const FLVCodecDescriptor *d,
                                          uint32_t *out_dim) {
    const uint32_t candidates[] = { 8192, 7680, 4096, 3840, 1920, 1280, 640 };
    uint8_t cfgbuf[64]; size_t cfg_len = 0;
    for (size_t i = 0; i < FLV_ARRAY_COUNT(candidates); i++) {
        uint32_t dim = candidates[i];
        CMFormatDescriptionRef fmt = NULL;
        int rc;
        if (codec == FLV_VP9) {
            /* 12-byte VT vpcC, explicit unknowns: level Undefined, colour
             * unspecified; dims belong to the format description. */
            rc = flv_vpcc_build(0, 0, 8, 1, 0, 2, 2, 2, cfgbuf, sizeof(cfgbuf), &cfg_len);
            if (rc == FLV_OK) rc = flv_create_format_description(codec, cfgbuf, cfg_len, dim, dim, &fmt);
        } else if (codec == FLV_AV1) {
            rc = flv_av1c_build(0, 10, 0, 0, cfgbuf, sizeof(cfgbuf), &cfg_len);
            if (rc == FLV_OK) rc = flv_create_format_description(codec, cfgbuf, cfg_len, dim, dim, &fmt);
        } else {
            rc = flv_create_format_description(codec, NULL, 0, dim, dim, &fmt);
        }
        if (rc != FLV_OK || !fmt) continue;
        NSDictionary *spec = @{
            (id)kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: @YES,
            (id)kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: @YES,
        };
        NSDictionary *attrs = @{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        };
        VTDecompressionSessionRef s = NULL;
        VTDecompressionOutputCallbackRecord cbRecord = { flv_probe_maxdim_decode_cb, NULL };
        OSStatus err = VTDecompressionSessionCreate(NULL, fmt,
                                                    (__bridge CFDictionaryRef)spec,
                                                    (__bridge CFDictionaryRef)attrs,
                                                    &cbRecord, &s);
        CFRelease(fmt);
        if (err != noErr || !s) continue;
        VTDecompressionSessionInvalidate(s);
        CFRelease(s);
        *out_dim = dim; return FLV_OK;
    }
    *out_dim = 0;
    return FLV_UNSUPPORTED;
}

/* ---- cached public probe ---- */

#define FLV_PROBE_SLOT_COUNT 22u /* 11 codecs x 2 directions */
typedef char flv_probe_slot_count_check[(FLV_ARRAY_COUNT(flv_codecs) * 2 == FLV_PROBE_SLOT_COUNT) ? 1 : -1];

static pthread_mutex_t flv_probe_mutex = PTHREAD_MUTEX_INITIALIZER;
static int flv_probe_done = 0;
static FLVCapability flv_probe_cache[FLV_PROBE_SLOT_COUNT];

static void flv_probe_all_locked(void) {
    flv_codec_ensure_supplemental_decoders();
    size_t slot = 0;
    for (size_t i = 0; i < flv_codecs_count; i++) {
        const FLVCodecDescriptor *d = &flv_codecs[i];
        for (uint32_t dir = 0; dir < 2; dir++) {
            uint32_t direction = dir == 0 ? FLV_ENCODE : FLV_DECODE;
            FLVCapability *cap = &flv_probe_cache[slot++];
            memset(cap, 0, sizeof(*cap));
            cap->codec = d->codec;
            cap->direction = direction;
            cap->probe_status = FLV_UNSUPPORTED;
            int path_ok = (direction == FLV_ENCODE) ? d->encode_path : d->decode_path;
            if (!path_ok) continue;
            cap->flags |= FLV_CAP_IMPLEMENTED;
            int hw = 0;
            int rc;
            if (direction == FLV_ENCODE) {
                rc = flv_probe_encode(d->codec, d, 0, &hw);
                if (rc == FLV_OK) {
                    cap->pixel_format_mask |= FLV_MASK_NV12;
                    if (d->native_pixel_mask & FLV_MASK_P010) {
                        int hw10 = 0;
                        if (flv_probe_encode(d->codec, d, 1, &hw10) == FLV_OK && hw10)
                            cap->pixel_format_mask |= FLV_MASK_P010;
                    }
                }
            } else {
                const FLVProbeSample *sample = flv_find_probe_sample(d->codec);
                if (!sample) { rc = FLV_UNSUPPORTED; } /* no verified sample shipped */
                else { rc = flv_probe_decode(d->codec, d, sample, &hw); }
                if (rc == FLV_OK) cap->pixel_format_mask |= FLV_MASK_NV12;
            }
            int software_proven = 0;
            if (rc != FLV_OK) {
                /* Hardware unavailable or unproven on this machine: probe the
                 * native software path with the same real data. A software
                 * proof is only reported when software genuinely did the work
                 * (readback false); hardware-assisted results stay
                 * unsupported here because the hardware probe owns them. */
                int sw = 0;
                int sw_rc;
                if (direction == FLV_ENCODE) {
                    sw_rc = flv_probe_encode_software(d->codec, d, &sw);
                } else {
                    const FLVProbeSample *sample = flv_find_probe_sample(d->codec);
                    if (!sample) { sw_rc = FLV_UNSUPPORTED; }
                    else { sw_rc = flv_probe_decode_software(d->codec, d, sample, &sw); }
                }
                if (sw_rc == FLV_OK && !sw) {
                    software_proven = 1;
                    cap->flags |= FLV_CAP_NATIVE_SOFTWARE_PROBED;
                    cap->probe_status = FLV_OK;
                    if (cap->pixel_format_mask == 0) cap->pixel_format_mask |= FLV_MASK_NV12;
                    /* Measured software truth only: the dims at which the
                     * software probe actually ran. No hardware-probe numbers
                     * and no invented limits. */
                    if (direction == FLV_DECODE) {
                        const FLVProbeSample *sample = flv_find_probe_sample(d->codec);
                        if (sample && sample->width && sample->height) {
                            cap->max_width = sample->width;
                            cap->max_height = sample->height;
                        }
                    } else {
                        /* flv_probe_encode_software verified a real 640x360
                         * software encode. */
                        cap->max_width = 640;
                        cap->max_height = 360;
                    }
                } else if (d->codec == FLV_MJPEG) {
                    /* MJPEG has no public VideoToolbox software path on this
                     * machine. The explicit ImageIO JPEG fallback is a real
                     * native software encode/decode of individual frames; it
                     * is probed here with actual pixels, never assumed. */
                    uint32_t iw = 0, ih = 0;
                    if (flv_imageio_probe(&iw, &ih) == FLV_OK && iw && ih) {
                        software_proven = 1;
                        cap->flags |= FLV_CAP_NATIVE_SOFTWARE_PROBED;
                        cap->probe_status = FLV_OK;
                        cap->pixel_format_mask |= FLV_MASK_NV12;
                        cap->max_width = iw;
                        cap->max_height = ih;
                    }
                }
            }
            if (rc == FLV_OK) {
                uint32_t dim = 0;
                int dim_rc;
                if (direction == FLV_ENCODE) {
                    dim_rc = flv_probe_max_dimension_encode(d, &dim);
                } else if (d->encode_path) {
                    /* H264/HEVC decode: same device family as the verified
                     * encoder; the encoder probe is meaningful here. */
                    dim_rc = flv_probe_max_dimension_encode(d, &dim);
                } else {
                    dim_rc = flv_probe_max_dimension_decode(d->codec, d, &dim);
                }
                if (dim_rc != FLV_OK || dim == 0) {
                    /* Fall back to the verified probe dimensions: the data
                     * plane probe succeeded at these dims, so advertising
                     * them is measured truth, never invention. */
                    if (direction == FLV_DECODE) {
                        const FLVProbeSample *sample = flv_find_probe_sample(d->codec);
                        if (sample && sample->width && sample->height) {
                            dim = sample->width > sample->height ? sample->width : sample->height;
                            dim_rc = FLV_OK;
                        }
                    } else {
                        /* flv_probe_encode verified hardware at 640x360. */
                        dim = 640;
                        dim_rc = FLV_OK;
                    }
                }
                if (dim_rc == FLV_OK && dim) {
                    cap->max_width = dim;
                    cap->max_height = dim;
                }
                cap->flags |= FLV_CAP_HW_REPORTED | FLV_CAP_SESSION_PROBED;
                cap->probe_status = FLV_OK;
            } else if (!software_proven) {
                cap->probe_status = rc;
            }
            /* Invariant: flag 8 never coexists with hardware flags 1/4. */
            if (cap->flags & FLV_CAP_NATIVE_SOFTWARE_PROBED)
                cap->flags &= ~(FLV_CAP_HW_REPORTED | FLV_CAP_SESSION_PROBED);
        }
    }
    flv_probe_done = 1;
}

int flv_codec_fill_capabilities(FLVCapability *entries, size_t capacity, size_t *required_count) {
    @autoreleasepool {
        if (!required_count) return FLV_INVALID;
        pthread_mutex_lock(&flv_probe_mutex);
        if (!flv_probe_done) flv_probe_all_locked();
        *required_count = FLV_PROBE_SLOT_COUNT;
        int rc = FLV_OK;
        if (entries && capacity > 0) {
            size_t n = capacity < FLV_PROBE_SLOT_COUNT ? capacity : FLV_PROBE_SLOT_COUNT;
            memcpy(entries, flv_probe_cache, n * sizeof(FLVCapability));
            if (capacity < FLV_PROBE_SLOT_COUNT) rc = FLV_LIMIT;
        }
        pthread_mutex_unlock(&flv_probe_mutex);
        return rc;
    }
}
