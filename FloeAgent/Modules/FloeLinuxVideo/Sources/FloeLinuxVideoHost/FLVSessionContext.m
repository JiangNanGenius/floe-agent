/* SPDX-License-Identifier: MPL-2.0 */
#import "FLVSessionContext.h"
#import "FLVHostContext.h"
#import "FLVFormatDescription.h"
#import "FLVCodecRegistry.h"
#import "FLVImageIOFallback.h"

/* Per-work record passed to VideoToolbox as the frame/source refcon. */
typedef struct {
    uint64_t generation;
    uint64_t owned_bytes;   /* host-memory accounted for this work item */
    uint64_t tag;
    int64_t pts_ns, dts_ns, duration_ns;
    uint8_t *buffer;        /* owned coded data (decode path) */
    size_t buffer_bytes;
} FLVWorkContext;

static int64_t flv_cmtime_to_ns(CMTime t) {
    if (CMTIME_IS_INVALID(t) || t.timescale == 0) return 0;
    return (int64_t)llroundl(((long double)t.value * 1000000000.0L) / (long double)t.timescale);
}

static CMTime flv_ns_to_cmtime(int64_t ns) {
    if (ns <= 0) return kCMTimeZero;
    return CMTimeMake(ns, 1000000000);
}

@interface FLVSessionContext ()
- (void)handleEncodedSample:(CMSampleBufferRef)sb status:(OSStatus)status infoFlags:(VTEncodeInfoFlags)infoFlags work:(FLVWorkContext *)wc;
- (void)handleDecodedImage:(CVImageBufferRef)image status:(OSStatus)status infoFlags:(VTDecodeInfoFlags)infoFlags work:(FLVWorkContext *)wc pts:(CMTime)pts dur:(CMTime)dur;
- (void)queueErrorOnce:(int32_t)flvStatus osStatus:(OSStatus)osStatus tag:(uint64_t)tag;
- (void)pushOutput:(FLVOutputBuffer *)buf notify:(uint32_t *)events;
- (int)encoderHardwareReported;
- (void)cacheDecoderHardwareReported:(VTDecompressionSessionRef)dec
            requireHardwareGuarantee:(int)require_hardware_guaranteed;
- (int)cachedHardwareReported; /* pure cache; never calls VT (codec threads) */
- (int)submitFrameImageIO:(const FLVFrame *)frame;
- (int)submitPacketImageIO:(const FLVPacket *)packet;
@end

static void FLVEncodeCallback(void *refcon, void *srcFrameRefCon, OSStatus status,
                              VTEncodeInfoFlags infoFlags, CMSampleBufferRef sampleBuffer) {
    /* VideoToolbox delivers completions on codec threads with no outer
     * autorelease pool; bound every Foundation temporary here. */
    @autoreleasepool {
        FLVSessionContext *s = (__bridge FLVSessionContext *)refcon;
        [s handleEncodedSample:sampleBuffer status:status infoFlags:infoFlags
                          work:(FLVWorkContext *)srcFrameRefCon];
    }
}

static void FLVDecodeCallback(void *refcon, void *srcFrameRefCon, OSStatus status,
                              VTDecodeInfoFlags infoFlags, CVImageBufferRef imageBuffer,
                              CMTime presentationTimeStamp, CMTime presentationDuration) {
    @autoreleasepool {
        FLVSessionContext *s = (__bridge FLVSessionContext *)refcon;
        [s handleDecodedImage:imageBuffer status:status infoFlags:infoFlags
                         work:(FLVWorkContext *)srcFrameRefCon
                          pts:presentationTimeStamp dur:presentationDuration];
    }
}

@implementation FLVSessionContext

#pragma mark - Lifecycle

- (instancetype)initWithHost:(FLVHostContext *)host config:(const FLVSessionConfig *)config status:(int *)status {
    self = [super init];
    if (!self) { if (status) *status = FLV_INTERNAL; return nil; }
    /* The mutex must exist before any early return: -dealloc runs -close,
     * which takes the lock. Everything else is cleaned up by dealloc. */
    pthread_mutex_init(&_lock, NULL);
    _generation = 1;
    _hw_reported = -1;
    if (!host || !config || config->abi_version != FLV_ABI_VERSION) {
        if (status) *status = FLV_INVALID;
        return nil;
    }
    const FLVCodecDescriptor *desc = flv_codec_descriptor(config->codec);
    if (!desc) { if (status) *status = FLV_UNSUPPORTED; return nil; }
    if (config->direction != FLV_ENCODE && config->direction != FLV_DECODE) {
        if (status) *status = FLV_INVALID;
        return nil;
    }
    if (config->direction == FLV_ENCODE && !desc->encode_path) {
        if (status) *status = FLV_UNSUPPORTED; return nil;
    }
    if (config->direction == FLV_DECODE && !desc->decode_path) {
        if (status) *status = FLV_UNSUPPORTED; return nil;
    }
    /* Pixel format: must be one our data plane copies natively. */
    uint32_t pf_bit = flv_pixel_format_bit(config->pixel_format);
    if (!pf_bit || !(desc->native_pixel_mask & pf_bit)) {
        if (status) *status = FLV_UNSUPPORTED; return nil;
    }
    if (config->bitstream_format != FLV_ANNEX_B &&
        config->bitstream_format != FLV_LENGTH_PREFIXED &&
        config->bitstream_format != FLV_RAW_CODED_FRAME) {
        if (status) *status = FLV_INVALID; return nil;
    }
    if (config->frame_rate_den == 0) { if (status) *status = FLV_INVALID; return nil; }

    _host = host;
    _codec = config->codec;
    _direction = config->direction;
    _pixel_format = config->pixel_format;
    _width = config->width;
    _height = config->height;
    _bitstream_format = config->bitstream_format;
    _bitrate = config->bitrate;
    _config = *config;
    _config.codec_config = NULL;
    _config.codec_config_bytes = 0;

    int rc = FLV_OK;
    int dims_deferred = 0;
    if (config->direction == FLV_DECODE && config->codec != 0 &&
        (config->codec == FLV_H264 || config->codec == FLV_HEVC) &&
        config->bitstream_format == FLV_ANNEX_B &&
        config->width == 0 && config->height == 0) {
        /* Annex-B decode sessions may start dimensionless; coded dimensions
         * are derived from the first in-band SPS (see submitPacket). */
        dims_deferred = 1;
    } else {
        rc = flv_validate_dimensions(_width, _height);
        if (rc == FLV_OK) {
            uint64_t pb[FLV_MAX_PLANES]; uint32_t ms[FLV_MAX_PLANES], pr[FLV_MAX_PLANES]; uint32_t pc;
            rc = flv_pixel_layout(_pixel_format, _width, _height, &pc, pb, ms, pr);
        }
    }
    if (rc == FLV_OK && config->codec_config && config->codec_config_bytes > 0) {
        if (config->codec_config_bytes > 4096) { rc = FLV_LIMIT; }
        else {
            _codec_config = malloc(config->codec_config_bytes);
            memcpy(_codec_config, config->codec_config, config->codec_config_bytes);
            _codec_config_bytes = config->codec_config_bytes;
            if (_codec == FLV_H264) {
                FLVParamSets ps;
                rc = flv_avcc_parse(_codec_config, _codec_config_bytes, &ps);
            } else if (_codec == FLV_HEVC) {
                FLVParamSets ps;
                rc = flv_hvcc_parse(_codec_config, _codec_config_bytes, &ps);
            }
        }
    }
    /* Decode with length-prefixed H264/HEVC but no avcC/hvcC is invalid. */
    if (rc == FLV_OK && _direction == FLV_DECODE &&
        (_codec == FLV_H264 || _codec == FLV_HEVC) &&
        _bitstream_format == FLV_LENGTH_PREFIXED && !_codec_config) {
        rc = FLV_INVALID;
    }
    if (rc == FLV_OK && _direction == FLV_ENCODE &&
        (_codec == FLV_H264 || _codec == FLV_HEVC) &&
        _bitstream_format == FLV_RAW_CODED_FRAME) {
        rc = FLV_INVALID; /* coded-frame mode only for self-contained codecs */
    }
    if (rc == FLV_OK && _direction == FLV_DECODE &&
        _codec != FLV_H264 && _codec != FLV_HEVC &&
        _bitstream_format == FLV_ANNEX_B) {
        rc = FLV_INVALID;
    }
    if (rc != FLV_OK) {
        if (status) *status = rc;
        return nil; /* dealloc disposes lock + codec_config */
    }
    (void)dims_deferred;

    /* Explicit native-software MJPEG path: only when the caller set the
     * policy bit, never under REQUIRE_HARDWARE. It is a real ImageIO
     * encode/decode of individual JPEG frames, classified software. Every
     * other codec keeps the VideoToolbox path exactly as before. */
    if (_codec == FLV_MJPEG && (_config.flags & FLV_ALLOW_NATIVE_SOFTWARE) &&
        !(_config.flags & FLV_REQUIRE_HARDWARE) &&
        _pixel_format == FLV_NV12 && _bitstream_format == FLV_RAW_CODED_FRAME &&
        flv_imageio_probe(NULL, NULL) == FLV_OK) {
        _imageio_native = 1;
    }
    /* If ImageIO is unavailable (or the request is not its supported shape),
     * fall through to the ordinary VideoToolbox path. A proven VT software
     * MJPEG slot therefore remains usable; when neither path works, session
     * creation fails explicitly below. */

    if (_direction == FLV_ENCODE) rc = _imageio_native ? FLV_OK : [self setupEncoder];
    else rc = _imageio_native ? FLV_OK : [self setupDecoder];

    if (rc != FLV_OK) {
        /* Dealloc performs close() + lock/config cleanup; do not touch the
         * lock or codec_config here (they are still owned by self). */
        [self teardownCodecResources];
        if (status) *status = rc;
        return nil;
    }
    if (status) *status = FLV_OK;
    return self;
}

- (int)setupEncoder {
    OSType cm_fmt = 0;
    switch (_pixel_format) {
        case FLV_NV12: cm_fmt = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange; break;
        case FLV_P010: cm_fmt = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange; break;
        default: return FLV_UNSUPPORTED;
    }
    uint32_t pc; uint64_t pb[FLV_MAX_PLANES]; uint32_t ms[FLV_MAX_PLANES], pr[FLV_MAX_PLANES];
    int rc = flv_pixel_layout(_pixel_format, _width, _height, &pc, pb, ms, pr);
    if (rc != FLV_OK) return rc;
    const FLVCodecDescriptor *desc = flv_codec_descriptor(_codec);
    NSDictionary *srcAttrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(cm_fmt),
        (id)kCVPixelBufferWidthKey: @(_width),
        (id)kCVPixelBufferHeightKey: @(_height),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    /* Hardware requirement is a session-creation specification
     * (kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder);
     * there is no public require-hardware compression property. */
    NSDictionary *spec = nil;
    if (_config.flags & FLV_REQUIRE_HARDWARE) {
        spec = @{
            (id)kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: @YES,
        };
    }
    OSStatus err = VTCompressionSessionCreate(NULL, (int32_t)_width, (int32_t)_height,
                                              desc->cm_codec_type,
                                              (__bridge CFDictionaryRef)spec,
                                              (__bridge CFDictionaryRef)srcAttrs,
                                              NULL, FLVEncodeCallback,
                                              (__bridge void *)self, &_enc);
    if (err != noErr || !_enc) return FLV_UNSUPPORTED;
    VTSessionSetProperty((VTSessionRef)_enc, kVTCompressionPropertyKey_RealTime,
                         (_config.flags & (FLV_REALTIME | FLV_LOW_LATENCY)) ? kCFBooleanTrue : kCFBooleanFalse);
    if (_bitrate > 0) {
        VTSessionSetProperty((VTSessionRef)_enc, kVTCompressionPropertyKey_AverageBitRate,
                             (__bridge CFTypeRef)@( (int32_t)(_bitrate > INT32_MAX ? INT32_MAX : _bitrate) ));
    }
    if (_config.frame_rate_num && _config.frame_rate_den) {
        double fps = (double)_config.frame_rate_num / (double)_config.frame_rate_den;
        VTSessionSetProperty((VTSessionRef)_enc, kVTCompressionPropertyKey_ExpectedFrameRate,
                             (__bridge CFTypeRef)@(fps));
        VTSessionSetProperty((VTSessionRef)_enc, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
                             (__bridge CFTypeRef)@(2.0));
    }
    /* Deterministic dts == pts for the V4L2 M2M contract. */
    VTSessionSetProperty((VTSessionRef)_enc, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
    /* Prepare before requesting the input pool or accepting frame work,
     * matching the sequence used by FFmpeg's VT encoder. Query hardware
     * here, outside _lock and before callbacks can run, so callbacks only
     * consult the cached session result. */
    err = VTCompressionSessionPrepareToEncodeFrames(_enc);
    if (err != noErr) return FLV_UNSUPPORTED;
    int hardware = [self encoderHardwareReported];
    if ((_config.flags & FLV_REQUIRE_HARDWARE) && hardware != 1) return FLV_UNSUPPORTED;
    return FLV_OK;
}

- (int)setupDecoder {
    flv_codec_ensure_supplemental_decoders();
    int rc = FLV_OK;
    /* Pre-build the format description when a config record was supplied. */
    if (_codec_config) {
        rc = flv_create_format_description(_codec, _codec_config, _codec_config_bytes,
                                           _width, _height, &_fmt);
        if (rc == FLV_OK && _width == 0 && _height == 0) {
            CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions((CMVideoFormatDescriptionRef)_fmt);
            _width = dims.width;
            _height = dims.height;
        }
    } else if (_width != 0 && _height != 0 &&
               !(_codec == FLV_H264 || _codec == FLV_HEVC) &&
               _bitstream_format != FLV_LENGTH_PREFIXED) {
        rc = flv_create_format_description(_codec, NULL, 0, _width, _height, &_fmt);
    } else if (_width != 0 && _height != 0 && _bitstream_format == FLV_RAW_CODED_FRAME) {
        rc = flv_create_format_description(_codec, NULL, 0, _width, _height, &_fmt);
    }
    if (rc != FLV_OK) return rc;
    /* Annex-B H264/HEVC without a record defers both the format description
     * and the decompression session to the first access unit carrying
     * parameter sets (submitPacket). */
    if (!_fmt) return FLV_OK;
    NSMutableDictionary *spec = [@{
        (id)kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: @YES,
    } mutableCopy];
    if (_config.flags & FLV_REQUIRE_HARDWARE) {
        spec[(id)kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder] = @YES;
    }
    NSDictionary *attrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @[
            @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
            @(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange),
        ],
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    VTDecompressionOutputCallbackRecord cbRecord = { FLVDecodeCallback, (__bridge void *)self };
    OSStatus err = VTDecompressionSessionCreate(NULL, _fmt, (__bridge CFDictionaryRef)spec,
                                                (__bridge CFDictionaryRef)attrs,
                                                &cbRecord, &_dec);
    if (err != noErr || !_dec) return FLV_UNSUPPORTED;
    /* Prime the hardware readback now, outside any lock and before any
     * callback can run, so codec-thread callbacks only consult the cache. */
    [self cacheDecoderHardwareReported:_dec
              requireHardwareGuarantee:(_config.flags & FLV_REQUIRE_HARDWARE) ? 1 : 0];
    return FLV_OK;
}

- (void)teardownCodecResources {
    if (_enc) { VTCompressionSessionInvalidate(_enc); CFRelease(_enc); _enc = NULL; }
    if (_dec) { VTDecompressionSessionInvalidate(_dec); CFRelease(_dec); _dec = NULL; }
    if (_fmt) { CFRelease(_fmt); _fmt = NULL; }
    if (_transfer) { VTPixelTransferSessionInvalidate(_transfer); CFRelease(_transfer); _transfer = NULL; }
}

- (void)dealloc {
    /* Safety net for never-closed sessions (e.g. registerSession failure).
     * close() is idempotent. */
    [self close];
    free(_codec_config);
    pthread_mutex_destroy(&_lock);
}

#pragma mark - Submit

- (int)checkUsable {
    if (_closed || _cancelled) return FLV_CANCELLED;
    if (_error_reported) return FLV_INTERNAL;
    return FLV_OK;
}

- (int)submitFrame:(const FLVFrame *)frame {
    if (!frame) return FLV_INVALID;
    if (_direction != FLV_ENCODE) return FLV_INVALID;
    if (!frame->data || frame->bytes == 0) return FLV_INVALID;
    if (frame->width != _width || frame->height != _height) return FLV_INVALID;
    if (frame->pixel_format != _pixel_format) return FLV_UNSUPPORTED;
    uint32_t pc; uint64_t pbytes[FLV_MAX_PLANES]; uint32_t mins[FLV_MAX_PLANES], prows[FLV_MAX_PLANES];
    int rc = flv_pixel_layout(_pixel_format, frame->width, frame->height, &pc, pbytes, mins, prows);
    if (rc != FLV_OK) return rc;
    if (frame->plane_count != pc) return FLV_INVALID;
    /* Validate each plane fits within frame->bytes. */
    uint64_t required = 0;
    for (uint32_t i = 0; i < pc; i++) {
        uint64_t row_bytes = pbytes[i] / prows[i];
        if (frame->plane_strides[i] < mins[i]) return FLV_INVALID;
        uint64_t span = (uint64_t)frame->plane_strides[i] * (prows[i] - 1) + row_bytes;
        uint64_t end = frame->plane_offsets[i] + span;
        if (end < frame->plane_offsets[i]) return FLV_INVALID; /* overflow */
        if (end > frame->bytes) return FLV_INVALID;
        if (end > required) required = end;
    }
    if (required > [self maxFrameBytes]) return FLV_LIMIT;
    if (_imageio_native) return [self submitFrameImageIO:frame];

    /* No VideoToolbox session call may run while _lock is held: VT can
     * invoke our completion callback on its own thread, and the callback
     * takes _lock — holding _lock across a VT entry point can deadlock
     * (observed 2026-11-11: submitPacket -> DecodeFrame waited in the
     * decoder while FLVDecodeCallback waited for _lock). Accounting and
     * encoder retention happen under the lock; every VT call runs after
     * unlocking, against the retained reference. */
    FLVWorkContext *wc = calloc(1, sizeof(FLVWorkContext));
    if (!wc) return FLV_INTERNAL;

    pthread_mutex_lock(&_lock);
    rc = [self checkUsable];
    if (rc == FLV_OK && _inflight >= [_host maxInflightPerSession]) rc = FLV_AGAIN;
    if (rc == FLV_OK) rc = [_host claimBytes:required];
    if (rc != FLV_OK) {
        pthread_mutex_unlock(&_lock);
        free(wc);
        return rc;
    }
    wc->generation = _generation;
    wc->owned_bytes = required;
    wc->tag = frame->tag;
    wc->pts_ns = frame->pts_ns;
    wc->dts_ns = frame->pts_ns;
    wc->duration_ns = frame->duration_ns;
    _inflight++;
    _inflight_bytes += required;
    _submitted++;
    [_host bumpSubmitted];
    VTCompressionSessionRef enc = _enc;
    if (enc) CFRetain(enc);
    pthread_mutex_unlock(&_lock);

    if (!enc) {
        /* Concurrent close tore the encoder down between checkUsable and
         * the retain: roll the accounting back and fence the work item. */
        pthread_mutex_lock(&_lock);
        _generation++;          /* fence any late callback */
        _inflight--;
        _inflight_bytes -= required;
        [_host releaseBytes:required];
        pthread_mutex_unlock(&_lock);
        free(wc);
        return FLV_CANCELLED;
    }
    CVPixelBufferPoolRef pool = VTCompressionSessionGetPixelBufferPool(enc);
    CVPixelBufferRef pb = NULL;
    CVReturn cvr = pool ? CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb)
                        : kCVReturnError;
    if (cvr != kCVReturnSuccess) {
        pthread_mutex_lock(&_lock);
        _inflight--;
        _inflight_bytes -= required;
        [_host releaseBytes:required];
        pthread_mutex_unlock(&_lock);
        CFRelease(enc);
        free(wc);
        return FLV_INTERNAL;
    }
    if (CVPixelBufferLockBaseAddress(pb, 0) != kCVReturnSuccess) {
        CVPixelBufferRelease(pb);
        pthread_mutex_lock(&_lock);
        _inflight--;
        _inflight_bytes -= required;
        [_host releaseBytes:required];
        pthread_mutex_unlock(&_lock);
        CFRelease(enc);
        free(wc);
        return FLV_INTERNAL;
    }
    for (uint32_t i = 0; i < pc; i++) {
        size_t dst_stride = CVPixelBufferGetBytesPerRowOfPlane(pb, i);
        const uint8_t *src = frame->data + frame->plane_offsets[i];
        uint64_t row_bytes = pbytes[i] / prows[i];
        uint8_t *dst = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pb, i);
        if (!dst) {
            CVPixelBufferUnlockBaseAddress(pb, 0);
            CVPixelBufferRelease(pb);
            pthread_mutex_lock(&_lock);
            _inflight--;
            _inflight_bytes -= required;
            [_host releaseBytes:required];
            pthread_mutex_unlock(&_lock);
            CFRelease(enc);
            free(wc);
            return FLV_INTERNAL;
        }
        for (uint32_t r = 0; r < prows[i]; r++) {
            memcpy(dst + r * dst_stride, src + r * frame->plane_strides[i], (size_t)row_bytes);
        }
    }
    CVPixelBufferUnlockBaseAddress(pb, 0);

    CFDictionaryRef frameOptions = NULL;
    NSDictionary *opts = nil;
    if (frame->flags & FLV_KEYFRAME) {
        opts = @{ (id)kVTEncodeFrameOptionKey_ForceKeyFrame: @YES };
        frameOptions = (__bridge CFDictionaryRef)opts;
    }
    VTEncodeInfoFlags infoFlags = 0;
    OSStatus err = VTCompressionSessionEncodeFrame(enc, pb,
                                                   flv_ns_to_cmtime(frame->pts_ns),
                                                   flv_ns_to_cmtime(frame->duration_ns),
                                                   frameOptions, wc, &infoFlags);
    CVPixelBufferRelease(pb); /* VT retains what it needs for the encode */
    CFRelease(enc);
    if (err != noErr) {
        /* No completion callback fires for a failed EncodeFrame. */
        pthread_mutex_lock(&_lock);
        _inflight--;
        _inflight_bytes -= required;
        [_host releaseBytes:required];
        pthread_mutex_unlock(&_lock);
        free(wc);
        return FLV_INTERNAL;
    }
    if (frame->flags & FLV_END_OF_STREAM) [self flushWithDrain:1];
    return FLV_OK;
}

/* Repack length-prefixed NAL stream from one length-field width to 4 bytes. */
static int flv_repack_length_size(const uint8_t *src, size_t src_bytes,
                                  uint32_t src_len_size,
                                  uint8_t *dst, size_t dst_capacity, size_t *out_bytes) {
    size_t w = 0;
    const uint8_t *r = src;
    const uint8_t *end = src + src_bytes;
    while (r + src_len_size <= end) {
        uint32_t len = 0;
        for (uint32_t i = 0; i < src_len_size; i++) len = (len << 8) | r[i];
        r += src_len_size;
        if ((size_t)(end - r) < len) return FLV_CORRUPT;
        if (w + 4 + len > dst_capacity) return FLV_LIMIT;
        dst[w++] = (uint8_t)(len >> 24); dst[w++] = (uint8_t)(len >> 16);
        dst[w++] = (uint8_t)(len >> 8); dst[w++] = (uint8_t)len;
        memcpy(dst + w, r, len);
        w += len;
        r += len;
    }
    if (r != end) return FLV_CORRUPT;
    *out_bytes = w;
    return FLV_OK;
}

- (int)submitPacket:(const FLVPacket *)packet {
    if (!packet) return FLV_INVALID;
    if (_direction != FLV_DECODE) return FLV_INVALID;
    if ((!packet->data || packet->bytes == 0) && !(packet->flags & FLV_END_OF_STREAM)) return FLV_INVALID;
    if (packet->bytes > [_host maxPacketBytes]) return FLV_LIMIT;

    if (packet->bytes == 0) {
        if (packet->flags & FLV_END_OF_STREAM) return [self flushWithDrain:1];
        return FLV_INVALID;
    }
    if (_imageio_native) return [self submitPacketImageIO:packet];

    int rc;
    uint8_t *owned = NULL;
    size_t owned_bytes = 0;
    int is_annexb_h26x = (_codec == FLV_H264 || _codec == FLV_HEVC) &&
                         _bitstream_format == FLV_ANNEX_B;
    if (is_annexb_h26x) {
        FLVNalu nals[64];
        size_t ncount = flv_annexb_split(packet->data, packet->bytes, nals, FLV_ARRAY_COUNT(nals));
        int has_vcl = 0;
        for (size_t i = 0; i < ncount; i++) {
            uint8_t t = (_codec == FLV_H264) ? flv_h264_nal_type(&nals[i]) : flv_hevc_nal_type(&nals[i]);
            if (flv_nal_is_vcl(_codec, t)) { has_vcl = 1; break; }
        }
        /* Update / create the format description from in-band parameter sets.
         * Sets accumulate across packets: a packet carrying only an SPS is a
         * legal metadata-only input, and the session materializes once every
         * required set has been seen.
         *
         * Locking: NO VideoToolbox call may run while _lock is held. The
         * merge/decision is made under the lock; format-description and
         * decompression-session creation run unlocked (VT can wait on its
         * own queues, and our callbacks take _lock — see submitFrame). */
        VTDecompressionSessionRef replacedDec = NULL;
        CMFormatDescriptionRef replacedFmt = NULL;
        int rc_rebuild = FLV_OK;
        FLVParamSets ps;
        int have_ps = 0;
        uint32_t dw = 0, dh = 0;
        pthread_mutex_lock(&_lock);
        int usable_rc = [self checkUsable];
        if (usable_rc != FLV_OK) {
            pthread_mutex_unlock(&_lock);
            return usable_rc;
        }
        if (_has_pending_ps) { ps = _pending_ps; have_ps = 1; }
        FLVParamSets new_ps;
        if (flv_annexb_extract_param_sets(packet->data, packet->bytes, _codec, &new_ps) == FLV_OK) {
            if (!have_ps) { memset(&ps, 0, sizeof(ps)); ps.length_size = 4; }
            /* Merge: newest set wins per array (VPS/SPS/PPS). */
            if (new_ps.sps_count) {
                memcpy(ps.sps[0], new_ps.sps[0], new_ps.sps_len[0]);
                ps.sps_len[0] = new_ps.sps_len[0];
                ps.sps_count = 1;
            }
            if (new_ps.pps_count) {
                memcpy(ps.pps[0], new_ps.pps[0], new_ps.pps_len[0]);
                ps.pps_len[0] = new_ps.pps_len[0];
                ps.pps_count = 1;
            }
            if (new_ps.vps_count) {
                memcpy(ps.vps[0], new_ps.vps[0], new_ps.vps_len[0]);
                ps.vps_len[0] = new_ps.vps_len[0];
                ps.vps_count = 1;
            }
            ps.length_size = new_ps.length_size ? new_ps.length_size : 4;
            _pending_ps = ps;
            _has_pending_ps = 1;
            have_ps = 1;
        }
        int need_new_fmt = 0;
        if (have_ps && (_width == 0 || _height == 0)) {
            int drc = (_codec == FLV_H264) ? flv_h264_sps_dimensions(ps.sps[0], ps.sps_len[0], &dw, &dh)
                                           : flv_hevc_sps_dimensions(ps.sps[0], ps.sps_len[0], &dw, &dh);
            if (drc == FLV_OK && dw && dh) need_new_fmt = 1;
        }
        if (have_ps && !_fmt) need_new_fmt = 1;
        pthread_mutex_unlock(&_lock);

        if (have_ps && need_new_fmt && rc_rebuild == FLV_OK) {
            CMFormatDescriptionRef candFmt = NULL;
            int frc = flv_create_format_description_from_param_sets(_codec, &ps, &candFmt);
            if (frc != FLV_OK) {
                /* Missing PPS (SPS-only packet so far): not an error yet. */
                if (ps.pps_count == 0 || ps.sps_count == 0) rc_rebuild = FLV_OK;
            } else {
                NSMutableDictionary *spec = [@{
                    (id)kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: @YES,
                } mutableCopy];
                if (_config.flags & FLV_REQUIRE_HARDWARE) {
                    spec[(id)kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder] = @YES;
                }
                NSDictionary *attrs = @{
                    (id)kCVPixelBufferPixelFormatTypeKey: @[
                        @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
                        @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
                        @(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange),
                    ],
                    (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
                };
                VTDecompressionSessionRef candDec = NULL;
                VTDecompressionOutputCallbackRecord cbRecord = { FLVDecodeCallback, (__bridge void *)self };
                OSStatus err = VTDecompressionSessionCreate(NULL, candFmt,
                                                            (__bridge CFDictionaryRef)spec,
                                                            (__bridge CFDictionaryRef)attrs,
                                                            &cbRecord, &candDec);
                if (err != noErr || !candDec) {
                    CFRelease(candFmt);
                    rc_rebuild = FLV_UNSUPPORTED;
                } else {
                    /* Prime the hardware readback outside _lock and before
                     * the session is installed (callbacks take _lock). */
                    [self cacheDecoderHardwareReported:candDec
                              requireHardwareGuarantee:(_config.flags & FLV_REQUIRE_HARDWARE) ? 1 : 0];
                    int installed = 0;
                    pthread_mutex_lock(&_lock);
                    if (_closed || _cancelled) {
                        rc_rebuild = FLV_CANCELLED;
                    } else {
                        /* Recompute under the lock: a racing submit may have
                         * installed a session (and dims) already. */
                        int dc2 = 0;
                        if ((_width == 0 || _height == 0) && dw && dh) dc2 = 1;
                        if (!_fmt || dc2) {
                            replacedDec = _dec;
                            replacedFmt = _fmt;
                            _dec = candDec;
                            _fmt = candFmt;
                            installed = 1;
                            if (dc2) { _width = dw; _height = dh; }
                        }
                    }
                    pthread_mutex_unlock(&_lock);
                    if (!installed) {
                        VTDecompressionSessionInvalidate(candDec);
                        CFRelease(candDec);
                        CFRelease(candFmt);
                    }
                }
            }
        }
        /* Emit FLV_OUTPUT_FORMAT (avcC/hvcC) exactly once, before frames. */
        if (rc_rebuild == FLV_OK && have_ps) {
            uint8_t rec[2048]; size_t rec_len = 0;
            int brc = (_codec == FLV_H264) ? flv_avcc_build(&ps, rec, sizeof(rec), &rec_len)
                                           : flv_hvcc_build(&ps, rec, sizeof(rec), &rec_len);
            if (brc == FLV_OK) {
                uint32_t events = 0;
                int notify = 0;
                pthread_mutex_lock(&_lock);
                if (!_format_sent && _fmt) {
                    FLVOutputBuffer *ob = calloc(1, sizeof(FLVOutputBuffer));
                    ob->kind = FLV_OUTPUT_FORMAT;
                    ob->data = malloc(rec_len);
                    memcpy(ob->data, rec, rec_len);
                    ob->bytes = rec_len;
                    ob->tag = _config.session_tag;
                    [self pushOutput:ob notify:&events];
                    _format_sent = 1;
                    notify = events != 0;
                }
                pthread_mutex_unlock(&_lock);
                if (notify) [_host emitNotify:_config.session_tag events:events];
            }
        }
        if (!has_vcl) {
            /* Parameter-set-only access unit: no decode work. */
            if (replacedDec) { VTDecompressionSessionInvalidate(replacedDec); CFRelease(replacedDec); }
            if (replacedFmt) CFRelease(replacedFmt);
            return rc_rebuild;
        }
        if (replacedDec) { VTDecompressionSessionInvalidate(replacedDec); CFRelease(replacedDec); }
        if (replacedFmt) CFRelease(replacedFmt);
        if (rc_rebuild != FLV_OK) return rc_rebuild;
        size_t cap = flv_annexb_to_lenpref_size(packet->data, packet->bytes);
        if (cap == 0) return FLV_CORRUPT;
        owned = malloc(cap);
        rc = flv_annexb_to_lenpref(packet->data, packet->bytes, owned, cap, &owned_bytes);
        if (rc != FLV_OK) { free(owned); return rc; }
    } else if ((_codec == FLV_H264 || _codec == FLV_HEVC) &&
               _bitstream_format == FLV_LENGTH_PREFIXED) {
        /* Validate the length-prefixed stream and normalize to 4-byte
         * length fields to match the avcC/hvcC we built. */
        uint32_t src_len_size = 4;
        if (_codec_config) {
            FLVParamSets ps;
            if ((_codec == FLV_H264 ? flv_avcc_parse(_codec_config, _codec_config_bytes, &ps)
                                    : flv_hvcc_parse(_codec_config, _codec_config_bytes, &ps)) == FLV_OK) {
                src_len_size = ps.length_size;
            }
        }
        if (src_len_size == 4) {
            owned = malloc(packet->bytes);
            memcpy(owned, packet->data, packet->bytes);
            owned_bytes = packet->bytes;
            rc = FLV_OK;
        } else {
            owned = malloc(packet->bytes * 2 + 16);
            rc = flv_repack_length_size(packet->data, packet->bytes, src_len_size,
                                        owned, packet->bytes * 2 + 16, &owned_bytes);
            if (rc != FLV_OK) { free(owned); return rc; }
        }
    } else {
        owned = malloc(packet->bytes);
        if (!owned) return FLV_INTERNAL;
        memcpy(owned, packet->data, packet->bytes);
        owned_bytes = packet->bytes;
    }

    pthread_mutex_lock(&_lock);
    rc = [self checkUsable];
    if (rc == FLV_OK && !_fmt) rc = FLV_INVALID; /* no parameter sets yet */
    if (rc == FLV_OK && _inflight >= [_host maxInflightPerSession]) rc = FLV_AGAIN;
    if (rc == FLV_OK) rc = [_host claimBytes:owned_bytes];
    if (rc != FLV_OK) {
        pthread_mutex_unlock(&_lock);
        free(owned);
        return rc;
    }
    CMFormatDescriptionRef fmt = _fmt ? (CMFormatDescriptionRef)CFRetain(_fmt) : NULL;
    VTDecompressionSessionRef dec = _dec ? (VTDecompressionSessionRef)CFRetain(_dec) : NULL;
    uint64_t generation = _generation;
    _inflight++;
    _inflight_bytes += owned_bytes;
    _submitted++;
    [_host bumpSubmitted];
    pthread_mutex_unlock(&_lock);

    if (!fmt || !dec) {
        /* Torn down concurrently (close raced submit). */
        if (fmt) CFRelease(fmt);
        if (dec) CFRelease(dec);
        pthread_mutex_lock(&_lock);
        _inflight--;
        _inflight_bytes -= owned_bytes;
        [_host releaseBytes:owned_bytes];
        pthread_mutex_unlock(&_lock);
        free(owned);
        return FLV_CANCELLED;
    }
    CMBlockBufferRef bb = NULL;
    CMSampleBufferRef sb = NULL;
    OSStatus serr = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, owned,
                                                       (CFIndex)owned_bytes, kCFAllocatorNull,
                                                       NULL, 0, (CFIndex)owned_bytes, 0, &bb);
    if (serr == noErr) {
        CMSampleTimingInfo timing = {
            .duration = flv_ns_to_cmtime(packet->duration_ns),
            .presentationTimeStamp = flv_ns_to_cmtime(packet->pts_ns),
            .decodeTimeStamp = flv_ns_to_cmtime(packet->dts_ns),
        };
        size_t sizes[1] = { owned_bytes };
        serr = CMSampleBufferCreate(kCFAllocatorDefault, bb, TRUE, NULL, NULL,
                                    fmt, 1, 1, &timing, 1, sizes, &sb);
    }
    CFRelease(fmt);
    if (serr != noErr || !sb) {
        if (bb) CFRelease(bb);
        pthread_mutex_lock(&_lock);
        _inflight--;
        _inflight_bytes -= owned_bytes;
        [_host releaseBytes:owned_bytes];
        pthread_mutex_unlock(&_lock);
        free(owned);
        return FLV_INTERNAL;
    }
    FLVWorkContext *wc = calloc(1, sizeof(FLVWorkContext));
    if (!wc) {
        CFRelease(sb);
        CFRelease(dec);
        pthread_mutex_lock(&_lock);
        _inflight--;
        _inflight_bytes -= owned_bytes;
        [_host releaseBytes:owned_bytes];
        pthread_mutex_unlock(&_lock);
        free(owned);
        return FLV_INTERNAL;
    }
    wc->generation = generation;
    wc->owned_bytes = owned_bytes;
    wc->tag = packet->tag;
    wc->pts_ns = packet->pts_ns;
    wc->dts_ns = packet->dts_ns;
    wc->duration_ns = packet->duration_ns;
    wc->buffer = owned;
    wc->buffer_bytes = owned_bytes;
    /* The session mutex must NOT be held across this call: VT can invoke
     * FLVDecodeCallback on its own thread and the callback takes _lock
     * (deadlock observed 2026-11-11). NOTE per VTDecompressionSession.h: the
     * async flag means DecodeFrame MAY return before the callback fires —
     * it is NOT a guarantee of nonblocking behavior, and callback output
     * order is not necessarily display order. `dec` is retained above, so a
     * racing close can only Invalidate it, which DecodeFrame reports as an
     * error. */
    OSStatus derr = VTDecompressionSessionDecodeFrame(dec, sb,
                                                      kVTDecodeFrame_EnableAsynchronousDecompression,
                                                      wc, NULL);
    CFRelease(sb); /* decode retains what it needs */
    CFRelease(dec);
    if (derr != noErr) {
        /* No completion callback fires for a failed DecodeFrame. */
        pthread_mutex_lock(&_lock);
        _inflight--;
        _inflight_bytes -= owned_bytes;
        [_host releaseBytes:owned_bytes];
        if (derr == kVTInvalidSessionErr) _error_reported = 1;
        pthread_mutex_unlock(&_lock);
        free(wc);
        free(owned);
        return (derr == kVTInvalidSessionErr) ? FLV_INTERNAL : FLV_CORRUPT;
    }
    if (packet->flags & FLV_END_OF_STREAM) [self flushWithDrain:1];
    return FLV_OK;
}

- (uint64_t)maxFrameBytes {
    return [_host maxFrameBytes];
}


#pragma mark - ImageIO MJPEG fallback (synchronous, generation-fenced)

/* Both methods do bounded work outside _lock, then re-check the generation
 * before publishing output. A close/cancel that lands during the ImageIO
 * call drops this result exactly like a late VideoToolbox callback. */

- (int)submitFrameImageIO:(const FLVFrame *)frame {
    if (!frame || !frame->data) return FLV_INVALID;
    if (frame->width != _width || frame->height != _height) return FLV_INVALID;
    if (frame->pixel_format != FLV_NV12) return FLV_UNSUPPORTED;
    uint32_t pc; uint64_t pbytes[FLV_MAX_PLANES]; uint32_t mins[FLV_MAX_PLANES], prows[FLV_MAX_PLANES];
    int rc = flv_pixel_layout(FLV_NV12, _width, _height, &pc, pbytes, mins, prows);
    if (rc != FLV_OK || frame->plane_count != 2) return FLV_INVALID;

    pthread_mutex_lock(&_lock);
    rc = [self checkUsable];
    uint64_t generation = _generation;
    if (rc == FLV_OK) {
        _submitted++;
        [_host bumpSubmitted];
    }
    pthread_mutex_unlock(&_lock);
    if (rc != FLV_OK) return rc;

    const uint8_t *y = frame->data + frame->plane_offsets[0];
    const uint8_t *uv = frame->data + frame->plane_offsets[1];
    uint8_t *jpeg = NULL;
    size_t jpeg_bytes = 0;
    int status = flv_imageio_encode_nv12(y, frame->plane_strides[0],
                                         uv, frame->plane_strides[1],
                                         _width, _height, &jpeg, &jpeg_bytes);
    if (status != FLV_OK) return status == FLV_LIMIT ? FLV_LIMIT : FLV_CORRUPT;
    if (!jpeg || jpeg_bytes > [_host maxPacketBytes]) {
        free(jpeg);
        return FLV_LIMIT;
    }

    FLVOutputBuffer *out = calloc(1, sizeof(*out));
    if (!out) { free(jpeg); return FLV_INTERNAL; }
    out->kind = FLV_OUTPUT_PACKET;
    out->status = FLV_OK;
    out->hardware_used = 0; /* ImageIO is native software by construction. */
    out->tag = frame->tag;
    out->pts_ns = frame->pts_ns;
    out->dts_ns = frame->pts_ns;
    out->duration_ns = frame->duration_ns;
    out->flags = FLV_KEYFRAME; /* every JPEG frame is intra-coded */
    out->data = jpeg;
    out->bytes = jpeg_bytes;

    pthread_mutex_lock(&_lock);
    rc = [self checkUsable];
    if (rc == FLV_OK && generation != _generation) rc = FLV_CANCELLED;
    if (rc != FLV_OK) {
        if (rc == FLV_CANCELLED) { _cancelled_count++; [_host bumpCancelled]; }
        pthread_mutex_unlock(&_lock);
        free(out->data); free(out);
        return rc;
    }
    uint32_t events = 0;
    [self pushOutput:out notify:&events];
    _completed++;
    [_host bumpCompleted];
    uint64_t tag = _config.session_tag;
    pthread_mutex_unlock(&_lock);
    uint32_t notify_events = events | FLV_EVENT_INPUT_READY;
    if (notify_events) [_host emitNotify:tag events:notify_events];
    if (frame->flags & FLV_END_OF_STREAM) [self flushWithDrain:1];
    return FLV_OK;
}

- (int)submitPacketImageIO:(const FLVPacket *)packet {
    if (!packet || !packet->data || !packet->bytes) return FLV_INVALID;
    pthread_mutex_lock(&_lock);
    int rc = [self checkUsable];
    uint64_t generation = _generation;
    if (rc == FLV_OK) {
        _submitted++;
        [_host bumpSubmitted];
    }
    pthread_mutex_unlock(&_lock);
    if (rc != FLV_OK) return rc;

    uint8_t *nv12 = NULL;
    size_t nv12_bytes = 0;
    uint32_t width = 0, height = 0;
    int status = flv_imageio_decode_jpeg(packet->data, packet->bytes,
                                         _width, _height,
                                         &nv12, &nv12_bytes, &width, &height);
    if (status != FLV_OK) return status == FLV_LIMIT ? FLV_LIMIT : FLV_CORRUPT;
    if (!nv12 || nv12_bytes > [_host maxFrameBytes]) {
        free(nv12);
        return FLV_LIMIT;
    }

    FLVOutputBuffer *out = calloc(1, sizeof(*out));
    if (!out) { free(nv12); return FLV_INTERNAL; }
    out->kind = FLV_OUTPUT_FRAME;
    out->status = FLV_OK;
    out->hardware_used = 0;
    out->tag = packet->tag;
    out->pts_ns = packet->pts_ns;
    out->dts_ns = packet->dts_ns;
    out->duration_ns = packet->duration_ns;
    out->flags = FLV_KEYFRAME;
    out->width = width;
    out->height = height;
    out->pixel_format = FLV_NV12;
    out->plane_count = 2;
    out->data = nv12;
    out->bytes = nv12_bytes;
    out->plane_offsets[0] = 0;
    out->plane_offsets[1] = (uint64_t)width * height;
    out->plane_bytes[0] = (uint64_t)width * height;
    out->plane_bytes[1] = (uint64_t)width * height / 2;
    out->plane_strides[0] = width;
    out->plane_strides[1] = width;

    pthread_mutex_lock(&_lock);
    rc = [self checkUsable];
    if (rc == FLV_OK && generation != _generation) rc = FLV_CANCELLED;
    if (rc != FLV_OK) {
        if (rc == FLV_CANCELLED) { _cancelled_count++; [_host bumpCancelled]; }
        pthread_mutex_unlock(&_lock);
        free(out->data); free(out);
        return rc;
    }
    uint32_t events = 0;
    [self pushOutput:out notify:&events];
    _completed++;
    [_host bumpCompleted];
    uint64_t tag = _config.session_tag;
    pthread_mutex_unlock(&_lock);
    uint32_t notify_events = events | FLV_EVENT_INPUT_READY;
    if (notify_events) [_host emitNotify:tag events:notify_events];
    if (packet->flags & FLV_END_OF_STREAM) [self flushWithDrain:1];
    return FLV_OK;
}

#pragma mark - Callbacks (codec thread; never re-enter public API)

- (void)pushOutput:(FLVOutputBuffer *)buf notify:(uint32_t *)events {
    /* caller holds _lock */
    if ([_host claimBytes:buf->bytes] != FLV_OK) {
        /* Host memory budget exhausted: report once, drop the payload. */
        if (buf->data) { free(buf->data); buf->data = NULL; buf->bytes = 0; }
        buf->kind = FLV_OUTPUT_ERROR;
        buf->status = FLV_LIMIT;
        if (!_error_reported) {
            _error_reported = 1;
        } else {
            free(buf);
            return;
        }
    }
    flv_queue_push(&_queue, buf);
    *events |= FLV_EVENT_OUTPUT_READY;
}

- (void)queueErrorOnce:(int32_t)flvStatus osStatus:(OSStatus)osStatus tag:(uint64_t)tag {
    (void)osStatus;
    /* caller holds _lock */
    if (_error_reported) return;
    _error_reported = 1;
    FLVOutputBuffer *ob = calloc(1, sizeof(FLVOutputBuffer));
    ob->kind = FLV_OUTPUT_ERROR;
    ob->status = flvStatus;
    ob->tag = tag;
    uint32_t events = 0;
    [self pushOutput:ob notify:&events];
}

- (void)noteWorkFinished:(FLVWorkContext *)wc {
    _inflight--;
    _inflight_bytes -= wc->owned_bytes;
    [_host releaseBytes:wc->owned_bytes];
    _completed++;
    [_host bumpCompleted];
}

- (int)encoderHardwareReported {
    if (_hw_reported >= 0) return _hw_reported;
    CFTypeRef hw = NULL;
    if (VTSessionCopyProperty((VTSessionRef)_enc, kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                              kCFAllocatorDefault, &hw) == noErr && hw &&
        CFGetTypeID(hw) == CFBooleanGetTypeID()) {
        _hw_reported = CFBooleanGetValue((CFBooleanRef)hw) ? 1 : 0;
    }
    if (hw) CFRelease(hw);
    return _hw_reported;
}

- (void)maybeSendEncoderFormat:(CMSampleBufferRef)sb {
    /* caller holds _lock */
    if (_format_sent) return;
    _format_sent = 1;
    CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sb);
    if (!fmt) return;
    CFDictionaryRef atoms = CMFormatDescriptionGetExtension(fmt, kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms);
    CFDataRef record = NULL;
    CFStringRef key = NULL;
    switch (_codec) {
        case FLV_H264: key = CFSTR("avcC"); break;
        case FLV_HEVC: key = CFSTR("hvcC"); break;
        case FLV_VP9: key = CFSTR("vpcC"); break;
        case FLV_AV1: key = CFSTR("av1C"); break;
        case FLV_MPEG4: key = CFSTR("esds"); break;
        default: break;
    }
    if (atoms && key) record = CFDictionaryGetValue(atoms, key);
    /* Note: kCMFormatDescriptionExtension_MagicCookie no longer exists in
     * the public SDK; SampleDescriptionExtensionAtoms is the only record
     * source here. Codecs without a record simply emit no FLV_OUTPUT_FORMAT
     * payload. */
    if (_codec == FLV_H264 || _codec == FLV_HEVC) {
        /* Cache parameter sets for Annex-B injection. */
        if (record) {
            FLVParamSets ps;
            int prc = (_codec == FLV_H264)
                ? flv_avcc_parse(CFDataGetBytePtr(record), (size_t)CFDataGetLength(record), &ps)
                : flv_hvcc_parse(CFDataGetBytePtr(record), (size_t)CFDataGetLength(record), &ps);
            if (prc == FLV_OK) _param_sets = ps;
        }
    }
    if (!record) return;
    FLVOutputBuffer *ob = calloc(1, sizeof(FLVOutputBuffer));
    ob->kind = FLV_OUTPUT_FORMAT;
    size_t len = (size_t)CFDataGetLength(record);
    ob->data = malloc(len);
    memcpy(ob->data, CFDataGetBytePtr(record), len);
    ob->bytes = len;
    ob->tag = _config.session_tag;
    uint32_t events = 0;
    [self pushOutput:ob notify:&events];
}

- (void)handleEncodedSample:(CMSampleBufferRef)sb status:(OSStatus)status
                    infoFlags:(VTEncodeInfoFlags)infoFlags work:(FLVWorkContext *)wc {
    uint32_t events = 0;
    int free_wc = 1;
    pthread_mutex_lock(&_lock);
    int fenced = _closed || _cancelled || (wc && wc->generation != _generation);
    if (wc) [self noteWorkFinished:wc];
    if (fenced) {
        /* Counted exactly once here: the work item was cancelled while
         * in flight (cancel/discard/close bump the host counter only for
         * items that never reach a fenced callback). */
        _cancelled_count++;
    } else if (status != noErr) {
        [self queueErrorOnce:FLV_INTERNAL osStatus:status tag:wc ? wc->tag : 0];
    } else if ((infoFlags & kVTEncodeInfo_FrameDropped) || !sb) {
        /* dropped frame: lawful, counted via completed */
    } else {
        /* Strict hardware truthfulness (cache only: never a VT call here). */
        if ([self cachedHardwareReported] < 0 ||
            ((_config.flags & FLV_REQUIRE_HARDWARE) && [self cachedHardwareReported] != 1)) {
            [self queueErrorOnce:FLV_INTERNAL osStatus:noErr tag:wc ? wc->tag : 0];
        } else {
            [self maybeSendEncoderFormat:sb];
            CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sb);
            if (bb) {
                size_t len = CMBlockBufferGetDataLength(bb);
                /* keyframe detection */
                BOOL keyframe = YES;
                CFArrayRef atts = CMSampleBufferGetSampleAttachmentsArray(sb, NO);
                if (atts && CFArrayGetCount(atts) > 0) {
                    CFDictionaryRef att = CFArrayGetValueAtIndex(atts, 0);
                    CFBooleanRef notSync = CFDictionaryGetValue(att, kCMSampleAttachmentKey_NotSync);
                    CFBooleanRef depends = CFDictionaryGetValue(att, kCMSampleAttachmentKey_DependsOnOthers);
                    if (notSync && CFBooleanGetValue(notSync)) keyframe = NO;
                    else if (depends && CFBooleanGetValue(depends)) keyframe = NO;
                }
                uint8_t *payload = NULL;
                size_t payload_bytes = 0;
                if (_bitstream_format == FLV_ANNEX_B && (_codec == FLV_H264 || _codec == FLV_HEVC)) {
                    size_t cap = flv_lenpref_to_annexb_size(NULL, 0, _codec, &_param_sets, keyframe, 1) + len;
                    payload = malloc(cap);
                    /* Copy block buffer into a scratch first. */
                    uint8_t *scratch = malloc(len);
                    if (scratch) {
                        if (CMBlockBufferCopyDataBytes(bb, 0, len, scratch) == noErr) {
                            size_t outn = 0;
                            if (flv_lenpref_to_annexb(scratch, len, _codec, &_param_sets,
                                                      keyframe ? 1 : 0, 1,
                                                      payload, cap, &outn) == FLV_OK) {
                                payload_bytes = outn;
                            }
                        }
                        free(scratch);
                    }
                    if (!payload_bytes) { free(payload); payload = NULL; }
                } else {
                    payload = malloc(len ? len : 1);
                    if (payload && CMBlockBufferCopyDataBytes(bb, 0, len, payload) != noErr) {
                        free(payload); payload = NULL;
                    } else {
                        payload_bytes = len;
                    }
                }
                if (payload) {
                    FLVOutputBuffer *ob = calloc(1, sizeof(FLVOutputBuffer));
                    ob->kind = FLV_OUTPUT_PACKET;
                    ob->status = FLV_OK;
                    ob->hardware_used = (uint32_t)[self cachedHardwareReported];
                    ob->tag = wc ? wc->tag : 0;
                    ob->pts_ns = flv_cmtime_to_ns(CMSampleBufferGetPresentationTimeStamp(sb));
                    ob->dts_ns = ob->pts_ns;
                    ob->duration_ns = flv_cmtime_to_ns(CMSampleBufferGetDuration(sb));
                    ob->data = payload;
                    ob->bytes = payload_bytes;
                    ob->flags = keyframe ? FLV_KEYFRAME : 0;
                    [self pushOutput:ob notify:&events];
                } else {
                    [self queueErrorOnce:FLV_INTERNAL osStatus:noErr tag:wc ? wc->tag : 0];
                }
            }
        }
    }
    if (_drain_pending && _inflight == 0) {
        FLVOutputBuffer *eos = calloc(1, sizeof(FLVOutputBuffer));
        eos->kind = FLV_OUTPUT_EOS;
        eos->status = FLV_OK;
        eos->tag = _config.session_tag;
        flv_queue_push(&_queue, eos);
        _drain_pending = 0;
        events |= FLV_EVENT_OUTPUT_READY;
    }
    int input_ready = (_inflight < [_host maxInflightPerSession]);
    uint64_t tag = _config.session_tag;
    pthread_mutex_unlock(&_lock);
    uint32_t notify_events = events;
    if (input_ready) notify_events |= FLV_EVENT_INPUT_READY;
    if (notify_events) [_host emitNotify:tag events:notify_events];
    if (free_wc && wc) free(wc);
}

/* Prime the decoder hardware readback once, OUTSIDE _lock and outside any
 * codec callback: VTSessionCopyProperty can wait on VT internals while our
 * decode callback takes _lock, so this must never run under the session
 * mutex (encode side already primes after PrepareToEncodeFrames).
 * require_hardware_guaranteed: the session was created with the
 * RequireHardware specification, which contractually guarantees hardware;
 * when the readback itself is unavailable we trust that contract (1), never
 * guess software. Idempotent: racing deferred-rebuild submits write the
 * same value. */
- (void)cacheDecoderHardwareReported:(VTDecompressionSessionRef)dec
            requireHardwareGuarantee:(int)require_hardware_guaranteed {
    if (_hw_reported >= 0) return;
    CFTypeRef hw = NULL;
    if (dec && VTSessionCopyProperty((VTSessionRef)dec, kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                                     kCFAllocatorDefault, &hw) == noErr && hw &&
        CFGetTypeID(hw) == CFBooleanGetTypeID()) {
        _hw_reported = CFBooleanGetValue((CFBooleanRef)hw) ? 1 : 0;
    } else {
        _hw_reported = require_hardware_guaranteed ? 1 : -1;
    }
    if (hw) CFRelease(hw);
}

/* Pure cache access for codec threads: NEVER calls into VideoToolbox.
 * _hw_reported is primed at encoder/decoder setup before any callback can
 * run. Unknown stays -1 and callbacks reject it; it must never be counted
 * as verified software or hardware. */
- (int)cachedHardwareReported {
    return _hw_reported;
}

/* Copy a decoded pixel buffer into an owned, tightly packed buffer. */
- (int)copyImageBuffer:(CVImageBufferRef)image outFormat:(uint32_t *)outPF
                 buffer:(uint8_t **)outBuf bytes:(size_t *)outBytes
                  width:(uint32_t)w height:(uint32_t)h {
    if (CVPixelBufferLockBaseAddress((CVPixelBufferRef)image, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess)
        return FLV_INTERNAL;
    int rc = FLV_INTERNAL;
    OSType fmt = CVPixelBufferGetPixelFormatType((CVPixelBufferRef)image);
    uint32_t targetPF = 0;
    if (fmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
        fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
        targetPF = FLV_NV12;
    } else if (fmt == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange) {
        targetPF = FLV_P010;
    } else {
        /* Fall back to a public pixel-transfer conversion into NV12. */
        rc = [self transferImageToNV12:image outBuffer:outBuf outBytes:outBytes width:w height:h];
        CVPixelBufferUnlockBaseAddress((CVPixelBufferRef)image, 0);
        if (rc == FLV_OK) *outPF = FLV_NV12;
        return rc;
    }
    uint64_t pbytes[FLV_MAX_PLANES]; uint32_t mins[FLV_MAX_PLANES], prows[FLV_MAX_PLANES]; uint32_t pc;
    rc = flv_pixel_layout(targetPF, w, h, &pc, pbytes, mins, prows);
    if (rc == FLV_OK) {
        size_t total = 0;
        for (uint32_t i = 0; i < pc; i++) total += (size_t)pbytes[i];
        uint8_t *buf = malloc(total ? total : 1);
        if (!buf) rc = FLV_INTERNAL;
        else {
            size_t off = 0;
            for (uint32_t i = 0; i < pc; i++) {
                size_t stride = CVPixelBufferGetBytesPerRowOfPlane((CVPixelBufferRef)image, i);
                const uint8_t *src = CVPixelBufferGetBaseAddressOfPlane((CVPixelBufferRef)image, i);
                size_t row_bytes = (size_t)(pbytes[i] / prows[i]);
                for (uint32_t r = 0; r < prows[i]; r++) {
                    memcpy(buf + off + r * row_bytes, src + r * stride, row_bytes);
                }
                off += (size_t)pbytes[i];
            }
            *outBuf = buf;
            *outBytes = total;
            *outPF = targetPF;
            rc = FLV_OK;
        }
    }
    CVPixelBufferUnlockBaseAddress((CVPixelBufferRef)image, 0);
    return rc;
}

- (int)transferImageToNV12:(CVImageBufferRef)image outBuffer:(uint8_t **)outBuf
                  outBytes:(size_t *)outBytes width:(uint32_t)w height:(uint32_t)h {
    if (!_transfer) {
        if (VTPixelTransferSessionCreate(NULL, &_transfer) != noErr || !_transfer) return FLV_UNSUPPORTED;
    }
    NSDictionary *attrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        (id)kCVPixelBufferWidthKey: @(w),
        (id)kCVPixelBufferHeightKey: @(h),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    CVPixelBufferRef dst = NULL;
    if (CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            (__bridge CFDictionaryRef)attrs, &dst) != kCVReturnSuccess || !dst) {
        return FLV_INTERNAL;
    }
    OSStatus err = VTPixelTransferSessionTransferImage(_transfer, image, dst);
    if (err != noErr) { CVPixelBufferRelease(dst); return FLV_UNSUPPORTED; }
    uint8_t *buf = NULL; size_t bytes = 0; uint32_t pf = 0;
    int rc = FLV_INTERNAL;
    /* recurse through the NV12 copy path */
    if (CVPixelBufferLockBaseAddress(dst, kCVPixelBufferLock_ReadOnly) == kCVReturnSuccess) {
        uint64_t pbytes[FLV_MAX_PLANES]; uint32_t mins[FLV_MAX_PLANES], prows[FLV_MAX_PLANES]; uint32_t pc;
        rc = flv_pixel_layout(FLV_NV12, w, h, &pc, pbytes, mins, prows);
        if (rc == FLV_OK) {
            size_t total = 0;
            for (uint32_t i = 0; i < pc; i++) total += (size_t)pbytes[i];
            buf = malloc(total);
            if (!buf) rc = FLV_INTERNAL;
            else {
                size_t off = 0;
                for (uint32_t i = 0; i < pc; i++) {
                    size_t stride = CVPixelBufferGetBytesPerRowOfPlane(dst, i);
                    const uint8_t *src = CVPixelBufferGetBaseAddressOfPlane(dst, i);
                    size_t row_bytes = (size_t)(pbytes[i] / prows[i]);
                    for (uint32_t r = 0; r < prows[i]; r++)
                        memcpy(buf + off + r * row_bytes, src + r * stride, row_bytes);
                    off += (size_t)pbytes[i];
                }
                bytes = total;
                pf = FLV_NV12;
            }
        }
        CVPixelBufferUnlockBaseAddress(dst, 0);
    }
    CVPixelBufferRelease(dst);
    (void)pf;
    *outBuf = buf;
    *outBytes = bytes;
    return rc;
}

- (void)handleDecodedImage:(CVImageBufferRef)image status:(OSStatus)status
                   infoFlags:(VTDecodeInfoFlags)infoFlags work:(FLVWorkContext *)wc
                         pts:(CMTime)pts dur:(CMTime)dur {
    (void)infoFlags;
    uint32_t events = 0;
    pthread_mutex_lock(&_lock);
    int fenced = _closed || _cancelled || (wc && wc->generation != _generation);
    if (wc) [self noteWorkFinished:wc];
    if (fenced) {
        _cancelled_count++; /* counted exactly once, see encode path */
    } else if (status != noErr) {
        [self queueErrorOnce:FLV_CORRUPT osStatus:status tag:wc ? wc->tag : 0];
    } else if (image) {
        /* Strict hardware truthfulness (cache only: never a VT call here). */
        if ([self cachedHardwareReported] < 0 ||
            ((_config.flags & FLV_REQUIRE_HARDWARE) && [self cachedHardwareReported] != 1)) {
            [self queueErrorOnce:FLV_INTERNAL osStatus:noErr tag:wc ? wc->tag : 0];
        } else {
            uint32_t pf = 0;
            uint8_t *buf = NULL;
            size_t bytes = 0;
            uint32_t w = (uint32_t)CVPixelBufferGetWidth((CVPixelBufferRef)image);
            uint32_t h = (uint32_t)CVPixelBufferGetHeight((CVPixelBufferRef)image);
            int crc = [self copyImageBuffer:image outFormat:&pf buffer:&buf bytes:&bytes width:w height:h];
            if (crc == FLV_OK) {
                FLVOutputBuffer *ob = calloc(1, sizeof(FLVOutputBuffer));
                ob->kind = FLV_OUTPUT_FRAME;
                ob->status = FLV_OK;
                ob->hardware_used = (uint32_t)[self cachedHardwareReported];
                ob->tag = wc ? wc->tag : 0;
                ob->pts_ns = flv_cmtime_to_ns(pts);
                ob->dts_ns = ob->pts_ns;
                ob->duration_ns = flv_cmtime_to_ns(dur);
                ob->data = buf;
                ob->bytes = bytes;
                ob->width = w;
                ob->height = h;
                ob->pixel_format = pf;
                ob->plane_count = 2;
                uint64_t yb = (uint64_t)w * h * (pf == FLV_P010 ? 2 : 1);
                ob->plane_offsets[0] = 0;
                ob->plane_bytes[0] = yb;
                ob->plane_strides[0] = w * (pf == FLV_P010 ? 2 : 1);
                ob->plane_offsets[1] = yb;
                ob->plane_bytes[1] = bytes - yb;
                ob->plane_strides[1] = w * (pf == FLV_P010 ? 2 : 1);
                ob->flags = FLV_KEYFRAME; /* decoded frames are always complete */
                [self pushOutput:ob notify:&events];
            } else {
                [self queueErrorOnce:crc osStatus:noErr tag:wc ? wc->tag : 0];
            }
        }
    }
    /* frame-dropped (image == NULL, status == noErr) is lawful */
    if (_drain_pending && _inflight == 0) {
        FLVOutputBuffer *eos = calloc(1, sizeof(FLVOutputBuffer));
        eos->kind = FLV_OUTPUT_EOS;
        eos->status = FLV_OK;
        eos->tag = _config.session_tag;
        flv_queue_push(&_queue, eos);
        _drain_pending = 0;
        events |= FLV_EVENT_OUTPUT_READY;
    }
    int input_ready = (_inflight < [_host maxInflightPerSession]);
    uint64_t tag = _config.session_tag;
    pthread_mutex_unlock(&_lock);
    uint32_t notify_events = events;
    if (input_ready) notify_events |= FLV_EVENT_INPUT_READY;
    if (notify_events) [_host emitNotify:tag events:notify_events];
    if (wc) free(wc);
}

#pragma mark - Dequeue / release

- (int)dequeueOutput:(FLVOutput *)output {
    if (!output) return FLV_INVALID;
    memset(output, 0, sizeof(*output));
    pthread_mutex_lock(&_lock);
    FLVOutputBuffer *b = flv_queue_pop(&_queue);
    pthread_mutex_unlock(&_lock);
    if (!b) return FLV_AGAIN;
    output->kind = b->kind;
    output->flags = b->flags;
    output->status = b->status;
    output->hardware_used = b->hardware_used;
    output->tag = b->tag;
    output->pts_ns = b->pts_ns;
    output->dts_ns = b->dts_ns;
    output->duration_ns = b->duration_ns;
    output->data = b->data;
    output->bytes = b->bytes;
    output->width = b->width;
    output->height = b->height;
    output->pixel_format = b->pixel_format;
    output->plane_count = b->plane_count;
    memcpy(output->plane_offsets, b->plane_offsets, sizeof(b->plane_offsets));
    memcpy(output->plane_bytes, b->plane_bytes, sizeof(b->plane_bytes));
    memcpy(output->plane_strides, b->plane_strides, sizeof(b->plane_strides));
    output->release_token = b;
    return FLV_OK;
}

- (void)releaseOutputToken:(void *)token {
    if (!token) return;
    FLVOutputBuffer *b = (FLVOutputBuffer *)token;
    if (b->data) free(b->data);
    [_host releaseBytes:b->bytes];
    free(b);
}

#pragma mark - Flush / cancel / close

- (int)flushWithDrain:(int)drain {
    pthread_mutex_lock(&_lock);
    int rc = (_closed || _cancelled) ? FLV_CANCELLED : FLV_OK;
    if (rc == FLV_OK) {
        if (drain) {
            _drain_pending = 1;
            if (_inflight == 0) {
                FLVOutputBuffer *eos = calloc(1, sizeof(FLVOutputBuffer));
                eos->kind = FLV_OUTPUT_EOS;
                eos->status = FLV_OK;
                eos->tag = _config.session_tag;
                flv_queue_push(&_queue, eos);
                _drain_pending = 0;
            }
        } else {
            /* Discard: fence in-flight callbacks (they count once when their
             * fenced callback lands) and drop queued output now. */
            _generation++;
            uint64_t freed_bytes = 0; uint32_t freed_count = 0;
            flv_queue_discard_all(&_queue, &freed_bytes, &freed_count);
            if (freed_bytes) [_host releaseBytes:freed_bytes];
            for (uint32_t i = 0; i < freed_count; i++) [_host bumpCancelled];
            _cancelled_count += freed_count;
            /* Inflight bytes are released when their fenced callbacks land. */
        }
    }
    int need_complete = (rc == FLV_OK && drain);
    VTCompressionSessionRef enc = _enc;
    VTDecompressionSessionRef dec = _dec;
    if (need_complete && enc) CFRetain(enc);
    if (need_complete && dec) CFRetain(dec);
    pthread_mutex_unlock(&_lock);
    if (need_complete) {
        if (enc) {
            VTCompressionSessionCompleteFrames(enc, kCMTimeIndefinite);
            CFRelease(enc);
        }
        if (dec) {
            VTDecompressionSessionFinishDelayedFrames(dec);
            VTDecompressionSessionWaitForAsynchronousFrames(dec);
            CFRelease(dec);
        }
        pthread_mutex_lock(&_lock);
        uint32_t events = 0;
        if (_drain_pending && _inflight == 0) {
            FLVOutputBuffer *eos = calloc(1, sizeof(FLVOutputBuffer));
            eos->kind = FLV_OUTPUT_EOS;
            eos->status = FLV_OK;
            eos->tag = _config.session_tag;
            flv_queue_push(&_queue, eos);
            _drain_pending = 0;
            events |= FLV_EVENT_OUTPUT_READY;
        }
        uint64_t tag = _config.session_tag;
        pthread_mutex_unlock(&_lock);
        if (events) [_host emitNotify:tag events:events];
    }
    return rc;
}

- (void)cancel {
    pthread_mutex_lock(&_lock);
    if (!_cancelled) {
        _cancelled = 1;
        /* Fence all pending work: each item counts once when its fenced
         * callback lands (or at close if callbacks never run). */
        _generation++;
    }
    pthread_mutex_unlock(&_lock);
}

- (void)close {
    pthread_mutex_lock(&_lock);
    if (_closed) {
        pthread_mutex_unlock(&_lock);
        return;
    }
    _closed = 1;
    _generation++;
    pthread_mutex_unlock(&_lock);

    /* Invalidate joins all pending VT callbacks before returning. */
    [self teardownCodecResources];

    pthread_mutex_lock(&_lock);
    uint64_t freed_bytes = 0; uint32_t freed_count = 0;
    flv_queue_discard_all(&_queue, &freed_bytes, &freed_count);
    uint64_t inflight_bytes = _inflight_bytes;
    uint32_t fenced = _inflight;
    _inflight = 0;
    _inflight_bytes = 0;
    if (freed_bytes) [_host releaseBytes:freed_bytes];
    if (inflight_bytes) [_host releaseBytes:inflight_bytes];
    /* Work items that never reached a fenced callback count once here. */
    for (uint32_t i = 0; i < fenced + freed_count; i++) [_host bumpCancelled];
    _cancelled_count += fenced + freed_count;
    pthread_mutex_unlock(&_lock);

    [_host unregisterSession:self];
}

#pragma mark - Stats accessors

- (uint32_t)inflightCount {
    pthread_mutex_lock(&_lock);
    uint32_t n = _inflight;
    pthread_mutex_unlock(&_lock);
    return n;
}

- (uint32_t)queuedOutputCount {
    pthread_mutex_lock(&_lock);
    uint32_t n = _queue.count;
    pthread_mutex_unlock(&_lock);
    return n;
}

- (uint64_t)sessionOwnedBytes {
    pthread_mutex_lock(&_lock);
    uint64_t n = _inflight_bytes + _queue.bytes;
    pthread_mutex_unlock(&_lock);
    return n;
}

@end
